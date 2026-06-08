import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_save.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_cache_usage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/luckdraw_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/utils/encore_entry_text.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/app_link.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/app_dialog.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/zoomable_image_overlay.dart';

/// module-level logger，供 dialog 與其 tap target 共用。
final _log = Logger('gacha.itemimage.detail');

/// 判斷 [record] 是否有可點開的詳情（icon 已成功下載 → 可開圖片切換器）。
///
/// 無 icon（負取／未抓）回 false，呼叫端據此不包 [GachaItemTapTarget]（passthrough）。
bool hasItemDetailContent(WidgetRef ref, GachaRecord record) {
  final index = ref.watch(itemImageIndexProvider);
  final entry = index.lookupImage(record.resourceId);
  if (entry == null) return false;
  final iconUrl = entry.iconUrl;
  if (iconUrl == null || iconUrl.isEmpty) return false;
  final cacheDir = ref.watch(itemImageCacheDirProvider);
  return itemIconCacheFile(
    baseDir: cacheDir,
    resourceId: record.resourceId,
    url: iconUrl,
  ).existsSync();
}

/// 物品詳情 dialog：title 為 icon + 名稱；content 為 chip 切換器（喚取 / 造型 / Icon）。
///
/// chip 順序固定「喚取（角色且 hasLuckdraw 才有，永遠排第一）→ 造型（依序，每個 skin 一個）→
/// Icon（永遠最後）」。只有一個 chip（如武器只有 icon）時自動隱藏 chip 列、直接放大顯示
/// 該圖。造型 chip 的圖下方顯示該造型的 Name／SubDecName／BgDescription。
class GachaItemDetailDialog extends ConsumerStatefulWidget {
  /// 建立 [GachaItemDetailDialog]。
  const GachaItemDetailDialog({super.key, required this.record});

  /// 要顯示的喚取 record。
  final GachaRecord record;

  @override
  ConsumerState<GachaItemDetailDialog> createState() =>
      _GachaItemDetailDialogState();
}

/// [GachaItemDetailDialog] 的 state：維護 chip 選中索引與各圖 lazy 下載狀態。
class _GachaItemDetailDialogState extends ConsumerState<GachaItemDetailDialog> {
  /// 當前選中 chip 的 index；超出範圍由 `clampedIndex` 收斂。
  int _selectedIndex = 0;

  /// 每張圖的下載／載入狀態，key 為該圖本地 cache 檔絕對路徑。
  final Map<String, _ImageLoadState> _loadStates = {};

  /// 已排程 precache 的本地圖檔路徑；避免每次 setState 重排。
  final Set<String> _precachedPaths = {};

  /// 是否已有 precache 排程於下一 frame。
  bool _precacheScheduled = false;

  /// http client（dispose 時 close 中斷 in-flight 請求）。
  late final http.Client _client;

  @override
  void initState() {
    super.initState();
    _client = http.Client();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  /// 對立繪 [url] 做 lazy 下載；成功寫 cache 並 setState 為 ready，失敗為 failed。
  Future<void> _fetchAndCache({required String url, required File file}) async {
    final fetcher = ref.read(itemImageFetcherProvider);
    try {
      final bytes = await fetcher.downloadImage(url, _client);
      if (bytes == null) {
        if (!mounted) return;
        setState(() => _loadStates[file.path] = const _ImageFailed());
        _log.warning(
          'illustration download null rid=${widget.record.resourceId} '
          'url=${sanitizeUrl(url)}',
        );
        return;
      }
      await writeImageFileAtomic(file, bytes);
      if (!mounted) return;
      setState(() => _loadStates[file.path] = _ImageReady(file));
      ref.invalidate(itemImageCacheUsageProvider);
      _log.info(
        'illustration ok rid=${widget.record.resourceId} '
        'bytes=${bytes.length} path=${sanitizeFsPath(file.path)}',
      );
    } catch (e, st) {
      if (!mounted) return;
      setState(() => _loadStates[file.path] = const _ImageFailed());
      _log.warning(
        'illustration failed rid=${widget.record.resourceId} '
        'url=${sanitizeUrl(url)}',
        e,
        st,
      );
    }
  }

  /// 重抓某 chip 的圖：先 evict 既有 ImageCache、切回 loading，再依類別重抓。
  ///
  /// 路徑不變的重抓必須 evict，否則 ready 圖重建後仍讀到舊快取（見檔頭策略）。
  /// 同時供失敗狀態的「重試」按鈕與圖片選單的「重抓圖片」共用。
  void _refetchEntry(_ImageChipEntry e) {
    PaintingBinding.instance.imageCache.evict(FileImage(e.file));
    _precachedPaths.remove(e.file.path);
    setState(() => _loadStates[e.file.path] = const _ImageLoading());
    switch (e.kind) {
      case _ChipKind.luckdraw:
        // 重抓必須略過服務的快取短路，否則只會回舊檔（disk 不變→畫面不變）。
        unawaited(
          _captureLuckdraw(
            file: e.file,
            lang: widget.record.languageCode,
            force: true,
          ),
        );
      case _ChipKind.skin:
        unawaited(_fetchAndCache(url: e.url, file: e.file));
      case _ChipKind.icon:
        unawaited(_refetchIcon(url: e.url, file: e.file));
    }
  }

  /// 重抓 icon：重新下載 [url] 覆蓋 [file]，成功後 evict + bump cache revision，
  /// 讓 dialog 標題縮圖與記錄列表 [GachaItemIcon] 同步顯示新 icon。
  ///
  /// 失敗時保留磁碟既有 icon（writeImageFileAtomic 只在成功時 rename 覆蓋），
  /// 但 chip 狀態轉 failed（沿用既有失敗 UI 的重試按鈕）。
  Future<void> _refetchIcon({required String url, required File file}) async {
    final fetcher = ref.read(itemImageFetcherProvider);
    try {
      final bytes = await fetcher.downloadImage(url, _client);
      if (bytes == null) {
        if (!mounted) return;
        setState(() => _loadStates[file.path] = const _ImageFailed());
        _log.warning(
          'icon refetch null rid=${widget.record.resourceId} '
          'url=${sanitizeUrl(url)}',
        );
        return;
      }
      await writeImageFileAtomic(file, bytes);
      if (!mounted) return;
      PaintingBinding.instance.imageCache.evict(FileImage(file));
      setState(() => _loadStates[file.path] = _ImageReady(file));
      ref.read(itemImageCacheRevisionProvider.notifier).bump();
      ref.invalidate(itemImageCacheUsageProvider);
      _log.info(
        'icon refetch ok rid=${widget.record.resourceId} '
        'bytes=${bytes.length} path=${sanitizeFsPath(file.path)}',
      );
    } catch (e, st) {
      if (!mounted) return;
      setState(() => _loadStates[file.path] = const _ImageFailed());
      _log.warning(
        'icon refetch failed rid=${widget.record.resourceId} '
        'url=${sanitizeUrl(url)}',
        e,
        st,
      );
    }
  }

  /// 擷取喚取立繪：呼叫 [LuckdrawCaptureService]，成功 setState ready、失敗 failed。
  ///
  /// [force] 為 true（手動「重抓」）時略過服務的「快取檔已存在即回舊檔」短路、強制
  /// 重新擷取；初始 lazy 載入維持預設 false（命中快取直接用）。
  Future<void> _captureLuckdraw({
    required File file,
    required String lang,
    bool force = false,
  }) async {
    final service = ref.read(luckdrawCaptureServiceProvider);
    try {
      final result = await service.capture(
        resourceId: widget.record.resourceId,
        kind: itemTypeKeyOf(widget.record, ref.read(itemImageIndexProvider)),
        lang: lang,
        force: force,
      );
      if (!mounted) return;
      if (result == null) {
        setState(() => _loadStates[file.path] = const _ImageFailed());
        _log.warning('luckdraw capture null rid=${widget.record.resourceId}');
        return;
      }
      setState(() => _loadStates[file.path] = _ImageReady(result));
      ref.invalidate(itemImageCacheUsageProvider);
      _log.info(
        'luckdraw ready rid=${widget.record.resourceId} '
        'path=${sanitizeFsPath(result.path)}',
      );
    } catch (e, st) {
      if (!mounted) return;
      setState(() => _loadStates[file.path] = const _ImageFailed());
      _log.warning('luckdraw failed rid=${widget.record.resourceId}', e, st);
    }
  }

  /// 只 precache ready 的圖檔。
  void _precacheImages(BuildContext context, List<_ImageChipEntry> entries) {
    for (final e in entries) {
      final st = _loadStates[e.file.path];
      if (st is! _ImageReady) continue;
      if (_precachedPaths.add(e.file.path)) {
        precacheImage(FileImage(e.file), context);
      }
    }
  }

  /// 圖片區右上角的溢出選單：複製圖片 / 儲存圖片 / --- / 重抓圖片。
  /// 沿用 lightbox X 鈕的半透明黑底圓鈕視覺；僅在圖片 ready 時疊在圖上顯示。
  Widget _buildImageMenu(BuildContext context, _ImageChipEntry current) {
    final l = AppLocalizations.of(context)!;
    return Material(
      color: Colors.black.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      child: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, color: Colors.white),
        tooltip: '',
        onSelected: (value) {
          switch (value) {
            case 'copy':
              unawaited(_copyImage(current));
            case 'save':
              unawaited(_saveImage(current));
            case 'refetch':
              _refetchEntry(current);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'copy',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.copy, size: 20),
              title: Text(l.actionCopyImage),
            ),
          ),
          PopupMenuItem(
            value: 'save',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.save_alt, size: 20),
              title: Text(l.actionSaveImage),
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'refetch',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.refresh, size: 20),
              title: Text(l.actionRefetchImage),
            ),
          ),
        ],
      ),
    );
  }

  /// 把 record 名稱與 chip 標籤組成存檔建議檔名，並去掉檔名非法字元。
  String _suggestedFileName(_ImageChipEntry e) {
    final raw = '${widget.record.name}_${e.label}';
    // Windows 檔名非法字元（< > : " / \ | ? *）一律換 _，避免存檔對話框拒絕。
    final safe = raw.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return '$safe.png';
  }

  /// 複製目前圖片到剪貼簿：解碼成 PNG → 寫剪貼簿，結果以 SnackBar 回報。
  Future<void> _copyImage(_ImageChipEntry e) async {
    final l = AppLocalizations.of(context)!;
    final png = await encodeImageFileToPng(e.file);
    if (!mounted) return;
    if (png == null) {
      _showSnack(l.itemImageCopyFailed);
      return;
    }
    final ok = await copyImagePngToClipboard(png);
    if (!mounted) return;
    _showSnack(ok ? l.itemImageCopied : l.itemImageCopyFailed);
  }

  /// 儲存目前圖片：解碼成 PNG → 系統存檔對話框，結果以 SnackBar 回報。
  /// 使用者取消不提示；寫檔失敗提示失敗。
  Future<void> _saveImage(_ImageChipEntry e) async {
    final l = AppLocalizations.of(context)!;
    final png = await encodeImageFileToPng(e.file);
    if (!mounted) return;
    if (png == null) {
      _showSnack(l.itemImageSaveFailed);
      return;
    }
    try {
      final savedPath = await saveImagePng(
        png,
        suggestedName: _suggestedFileName(e),
      );
      if (!mounted || savedPath == null) return;
      _showSnack(l.itemImageSavedTo(savedPath));
    } catch (_) {
      if (!mounted) return;
      _showSnack(l.itemImageSaveFailed);
    }
  }

  /// 以 SnackBar 顯示 [message]（dialog 之上找最近的 ScaffoldMessenger）。
  void _showSnack(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 依當前 chip 狀態顯示內容（ready→可縮放圖／loading→spinner／failed→重試）。
  Widget _buildCurrentImageArea(BuildContext context, _ImageChipEntry current) {
    final theme = Theme.of(context);
    final tokens = theme.gacha;
    final l = AppLocalizations.of(context)!;
    final state = _loadStates[current.file.path] ?? const _ImageLoading();
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: switch (state) {
        _ImageReady(:final file) => Stack(
          children: [
            Positioned.fill(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _log.info('open zoom path=${sanitizeFsPath(file.path)}');
                    showZoomableImageOverlay(context, imageFile: file);
                  },
                  child: Image.file(
                    file,
                    key: ValueKey(file.path),
                    fit: BoxFit.contain,
                    alignment: Alignment.center,
                    gaplessPlayback: true,
                    errorBuilder: (_, e, st) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
            Positioned(
              top: AppSpacing.s,
              right: AppSpacing.s,
              child: _buildImageMenu(context, current),
            ),
          ],
        ),
        _ImageLoading() => Center(
          child: SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: tokens.textSecondary,
            ),
          ),
        ),
        _ImageFailed() => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.broken_image_outlined,
                size: 48,
                color: tokens.textMuted,
              ),
              const SizedBox(height: AppSpacing.s),
              Text(
                l.galleryLazyLoadFailed,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.s),
              TextButton.icon(
                onPressed: () => _refetchEntry(current),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l.actionRetry),
              ),
            ],
          ),
        ),
      },
    );
  }

  /// 詳情 dialog 用的 HTML 樣式（簡介與造型說明共用）：body 字級 bodyMedium、弱色、
  /// margin/padding 歸零；`<p>` margin 歸零。
  Map<String, Style> _detailHtmlStyle(ThemeData theme) => {
    'body': Style(
      fontSize: FontSize(theme.textTheme.bodyMedium?.fontSize ?? 14),
      color: theme.gacha.textSecondary,
      margin: Margins.zero,
      padding: HtmlPaddings.zero,
    ),
    'p': Style(margin: Margins.zero),
  };

  /// 詳情 dialog 用的 HTML 區塊（簡介與造型說明共用）：先以 [stripEntryLinkTags] 還原
  /// encore 詞條標籤 `<te>` 為純文字（否則 flutter_html 會連同內文丟棄而缺字），再套
  /// [_detailHtmlStyle]，並以 [DefaultTextStyle] 把環境字級重置為 bodyMedium。
  ///
  /// flutter_html 會以 `DefaultTextStyle.of(context)` 當作 root 行高來源。簡介位於
  /// AlertDialog 的 title 區，環境 [DefaultTextStyle] 是大行高的 titleTextStyle，
  /// 會讓單行說明文字在第一行上方多塞約 8px leading、換行時卻貼齊，造成「換行／不換
  /// 行」與標題的間距不一致。改用 bodyMedium 當 root 後，單行與多行皆貼齊（間距一致）。
  Widget _detailHtml(ThemeData theme, String data) => DefaultTextStyle(
    style: theme.textTheme.bodyMedium ?? const TextStyle(),
    child: Html(data: stripEntryLinkTags(data), style: _detailHtmlStyle(theme)),
  );

  /// 造型圖下方 caption：Name（標題）＋SubDecName（次標、弱色）＋BgDescription
  /// （內文、含 HTML、過長捲動）。三者皆空則不繪。
  Widget _buildSkinCaption(BuildContext context, ItemSkin skin) {
    final theme = Theme.of(context);
    final tokens = theme.gacha;
    final hasName = skin.name.trim().isNotEmpty;
    final hasSub = skin.subDecName.trim().isNotEmpty;
    final hasBg = skin.bgDescription.trim().isNotEmpty;
    if (!hasName && !hasSub && !hasBg) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasName)
            Text(
              skin.name,
              style: theme.textTheme.titleSmall?.copyWith(
                color: tokens.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
          if (hasSub) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              skin.subDecName,
              style: theme.textTheme.bodySmall?.copyWith(
                color: tokens.textSecondary,
              ),
            ),
          ],
          if (hasBg) ...[
            const SizedBox(height: AppSpacing.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 96),
              child: SingleChildScrollView(
                child: _detailHtml(theme, skin.bgDescription),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final tokens = theme.gacha;
    final record = widget.record;

    final index = ref.watch(itemImageIndexProvider);
    final cacheDir = ref.watch(itemImageCacheDirProvider);
    final entry = index.lookupImage(record.resourceId);
    final cacheRevision = ref.watch(itemImageCacheRevisionProvider);

    // per-lang 詳情：優先取 record 擷取語言；該 lang 未抓時 fallback 第一筆已抓
    // 語言（總比空白好）。
    final lang = record.languageCode;
    final detail =
        (lang.isEmpty ? null : entry?.detailByLang[lang]) ??
        (entry?.detailByLang.isNotEmpty == true
            ? entry!.detailByLang.values.first
            : null);
    final intro = detail?.intro ?? '';
    final elementName = detail?.elementName ?? '';
    final weaponTypeName = detail?.weaponTypeName ?? '';
    final skins = detail?.skins ?? const <ItemSkin>[];

    // icon cache 檔（已於更新階段下載 → 永遠 ready）。
    File? iconFile;
    final iconUrl = entry?.iconUrl;
    if (iconUrl != null && iconUrl.isNotEmpty) {
      final f = itemIconCacheFile(
        baseDir: cacheDir,
        resourceId: record.resourceId,
        url: iconUrl,
      );
      if (f.existsSync()) iconFile = f;
    }

    // chip 順序：造型（依序，每個 skin 一個）→ 喚取（角色 hasLuckdraw 才有）→ Icon（永遠最後）。
    final chipEntries = <_ImageChipEntry>[];
    final isCharacter = itemTypeKeyOf(record, index) == kItemKindCharacter;
    for (final skin in skins) {
      if (skin.formationCard.isEmpty) continue;
      final f = itemIllustrationCacheFile(
        baseDir: cacheDir,
        resourceId: record.resourceId,
        url: skin.formationCard,
      );
      chipEntries.add(
        _ImageChipEntry(
          label: skin.name.isNotEmpty ? skin.name : l.galleryIllustrationLabel,
          url: skin.formationCard,
          file: f,
          kind: _ChipKind.skin,
          skin: skin,
        ),
      );
    }
    if (isCharacter && (entry?.hasLuckdraw ?? false)) {
      chipEntries.add(
        _ImageChipEntry(
          label: l.galleryLuckdrawLabel,
          url: '',
          file: itemLuckdrawCacheFile(
            baseDir: cacheDir,
            resourceId: record.resourceId,
          ),
          kind: _ChipKind.luckdraw,
        ),
      );
    }
    if (iconFile != null) {
      chipEntries.add(
        _ImageChipEntry(
          label: l.galleryIconLabel,
          url: iconUrl ?? '',
          file: iconFile,
          kind: _ChipKind.icon,
        ),
      );
    }

    // 同步 _loadStates：icon 永遠 ready；喚取／造型圖本地有檔→ready，否則 loading + 背景取圖。
    for (final ce in chipEntries) {
      if (_loadStates.containsKey(ce.file.path)) continue;
      switch (ce.kind) {
        case _ChipKind.icon:
          _loadStates[ce.file.path] = _ImageReady(ce.file);
        case _ChipKind.luckdraw:
          if (ce.file.existsSync()) {
            _loadStates[ce.file.path] = _ImageReady(ce.file);
          } else {
            _loadStates[ce.file.path] = const _ImageLoading();
            final theFile = ce.file;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final lang = widget.record.languageCode;
              unawaited(_captureLuckdraw(file: theFile, lang: lang));
            });
          }
        case _ChipKind.skin:
          if (ce.file.existsSync()) {
            _loadStates[ce.file.path] = _ImageReady(ce.file);
          } else {
            _loadStates[ce.file.path] = const _ImageLoading();
            final theUrl = ce.url;
            final theFile = ce.file;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              unawaited(_fetchAndCache(url: theUrl, file: theFile));
            });
          }
      }
    }

    final clampedIndex = chipEntries.isEmpty
        ? -1
        : _selectedIndex.clamp(0, chipEntries.length - 1);
    final current = clampedIndex >= 0 ? chipEntries[clampedIndex] : null;

    if (chipEntries.isNotEmpty && !_precacheScheduled) {
      _precacheScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _precacheScheduled = false;
        if (!mounted) return;
        _precacheImages(context, chipEntries);
      });
    }

    final nameColor = switch (record.qualityLevel) {
      5 => tokens.fiveStar,
      4 => tokens.fourStar,
      _ => tokens.textPrimary,
    };

    return AppDialog(
      size: AppDialogSize.md,
      maxHeight: 880,
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (iconFile != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Image.file(
                iconFile,
                key: ValueKey('${iconFile.path}#$cacheRevision'),
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (_, e, st) => const SizedBox.shrink(),
              ),
            ),
            const SizedBox(width: AppSpacing.m),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.name,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: nameColor,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (intro.trim().isNotEmpty)
                  Padding(
                    // 名稱與簡介間留一點間距，避免兩者貼齊（2dp，無對應 token 故用字面值）。
                    padding: const EdgeInsets.only(top: 2),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 120),
                      child: SingleChildScrollView(
                        child: _detailHtml(theme, intro),
                      ),
                    ),
                  ),
                if (_tagsFor(
                  l,
                  record,
                  elementName,
                  weaponTypeName,
                ).isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.s),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in _tagsFor(
                        l,
                        record,
                        elementName,
                        weaponTypeName,
                      ))
                        Chip(
                          label: Text(t),
                          backgroundColor: tokens.textPrimary.withValues(
                            alpha: 0.15,
                          ),
                          side: BorderSide.none,
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.all(
                              Radius.circular(AppRadius.sm),
                            ),
                          ),
                          labelStyle: theme.textTheme.bodySmall?.copyWith(
                            color: tokens.textPrimary,
                            fontWeight: FontWeight.w500,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.s,
                          ),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: current != null ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (chipEntries.length > 1) ...[
            Wrap(
              spacing: AppSpacing.s,
              runSpacing: AppSpacing.s,
              children: [
                for (var i = 0; i < chipEntries.length; i++)
                  ChoiceChip(
                    label: Text(chipEntries[i].label),
                    selected: i == clampedIndex,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _selectedIndex = i),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.m),
          ],
          if (current != null)
            Expanded(child: _buildCurrentImageArea(context, current)),
          if (current?.skin != null) _buildSkinCaption(context, current!.skin!),
        ],
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text(l.actionViewOnEncore),
          onPressed: () {
            _log.info(
              'open encore kind=${itemTypeKeyOf(record, index)} id=${record.resourceId}',
            );
            openExternalUrl(
              Uri.parse(
                encoreItemUrl(
                  kind: itemTypeKeyOf(record, index),
                  resourceId: record.resourceId,
                  lang: record.languageCode,
                ),
              ),
            );
          },
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionClose),
        ),
      ],
    );
  }
}

/// 組詳情 tag：★（app UI 語系）＋元素＋武器類型（encore 在地化，空者略過）。
List<String> _tagsFor(
  AppLocalizations l,
  GachaRecord record,
  String elementName,
  String weaponTypeName,
) => [
  l.rarityStar(record.qualityLevel),
  if (elementName.isNotEmpty) elementName,
  if (weaponTypeName.isNotEmpty) weaponTypeName,
];

/// chip 類別 — icon 永遠 ready（已快取），造型走 lazy，luckdraw 由 webview 擷取。
enum _ChipKind {
  /// 喚取（Luckdraw）立繪：由 webview 擷取 encore canvas，僅角色且 hasLuckdraw。
  luckdraw,

  /// 造型 formation 大圖（URL 取自 per-lang 詳情 [ItemDetailL10n.skins]，lazy 下載）。
  skin,

  /// entry.iconUrl（已預下載，永遠 ready，永遠排最後）。
  icon,
}

/// 內部：單一 chip 條目。
class _ImageChipEntry {
  /// 建立 [_ImageChipEntry]。
  const _ImageChipEntry({
    required this.label,
    required this.url,
    required this.file,
    required this.kind,
    this.skin,
  });

  /// chip 顯示文字。
  final String label;

  /// 該 chip 對應的遠端 URL。
  final String url;

  /// 該 chip 對應的本地 cache 檔（造型圖可能尚未存在）。
  final File file;

  /// chip 類別。
  final _ChipKind kind;

  /// 造型 chip 才有，供圖下方 caption（Name／SubDecName／BgDescription）。
  final ItemSkin? skin;
}

/// 顯示 [GachaItemDetailDialog]。
Future<void> showGachaItemDetailDialog(
  BuildContext context,
  GachaRecord record,
) {
  _log.info(
    'open rid=${record.resourceId} name=${record.name} '
    'quality=${record.qualityLevel}',
  );
  return showDialog<void>(
    context: context,
    builder: (_) => GachaItemDetailDialog(record: record),
  );
}

/// 把任意 [child] 包成可點區塊；[hasItemDetailContent] 為 false 時 passthrough。
class GachaItemTapTarget extends ConsumerWidget {
  /// 建立 [GachaItemTapTarget]。
  const GachaItemTapTarget({
    super.key,
    required this.record,
    required this.child,
  });

  /// 對應 record。
  final GachaRecord record;

  /// 子 widget。
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!hasItemDetailContent(ref, record)) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showGachaItemDetailDialog(context, record),
        child: child,
      ),
    );
  }
}

/// 圖片的下載／載入狀態。
sealed class _ImageLoadState {
  /// 建立 [_ImageLoadState]。
  const _ImageLoadState();
}

/// 下載中。
class _ImageLoading extends _ImageLoadState {
  /// 建立 [_ImageLoading]。
  const _ImageLoading();
}

/// 本地已有 cache 檔，可直接 `Image.file` 顯示。
class _ImageReady extends _ImageLoadState {
  /// 建立 [_ImageReady]。
  const _ImageReady(this.file);

  /// 對應的本地 cache 檔。
  final File file;
}

/// 下載失敗。
class _ImageFailed extends _ImageLoadState {
  /// 建立 [_ImageFailed]。
  const _ImageFailed();
}
