import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/log_sanitize.dart';

/// 單一造型（skin）：formation 立繪圖＋名稱／副名／背景故事（皆 per-lang 文字，
/// formation 圖 URL 為 lang-agnostic）。對應 encore `Skins[i]`。
class ItemSkin {
  /// 建立 [ItemSkin]。
  const ItemSkin({
    required this.formationCard,
    required this.name,
    required this.subDecName,
    required this.bgDescription,
  });

  /// formation 立繪圖 URL（`Skins[i].FormationRoleCard`）。
  final String formationCard;

  /// 造型名稱（`Skins[i].Name`，如「新綠致意」）。
  final String name;

  /// 造型副名（`Skins[i].SubDecName`，如「維里奈-初始服飾」）。
  final String subDecName;

  /// 造型背景故事（`Skins[i].BgDescription`）。
  final String bgDescription;

  /// 由 storage JSON 還原。
  factory ItemSkin.fromJson(Map<String, dynamic> j) => ItemSkin(
    formationCard: j['formation_card'] as String? ?? '',
    name: j['name'] as String? ?? '',
    subDecName: j['sub_dec_name'] as String? ?? '',
    bgDescription: j['bg_description'] as String? ?? '',
  );

  /// 寫入 storage JSON。
  Map<String, dynamic> toJson() => {
    'formation_card': formationCard,
    'name': name,
    'sub_dec_name': subDecName,
    'bg_description': bgDescription,
  };
}

/// 單一 lang 的 dialog 詳情（持久化於 index）。
class ItemDetailL10n {
  /// 建立 [ItemDetailL10n]。
  const ItemDetailL10n({
    required this.intro,
    required this.elementName,
    required this.weaponTypeName,
    required this.skins,
  });

  /// 簡介（角色 Introduction／武器 BgDescription，可能含 HTML）。
  final String intro;

  /// 元素名（角色；武器／道具空）。
  final String elementName;

  /// 武器類型名（角色／武器；道具空）。
  final String weaponTypeName;

  /// 造型清單（角色；武器／道具空）。
  final List<ItemSkin> skins;

  /// 由 storage JSON 還原。
  factory ItemDetailL10n.fromJson(Map<String, dynamic> j) => ItemDetailL10n(
    intro: j['intro'] as String? ?? '',
    elementName: j['element_name'] as String? ?? '',
    weaponTypeName: j['weapon_type_name'] as String? ?? '',
    skins:
        (j['skins'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ItemSkin.fromJson)
            .toList() ??
        const [],
  );

  /// 寫入 storage JSON。
  Map<String, dynamic> toJson() => {
    'intro': intro,
    'element_name': elementName,
    'weapon_type_name': weaponTypeName,
    'skins': skins.map((s) => s.toJson()).toList(),
  };
}

/// 單一 resourceId 的圖片索引條目（正取 / 負取 / 永久負取）。
///
/// - 正取：[iconUrl] 非空、[noImage] = false → [hasIcon] 為 true。
/// - 負取（非永久）：[noImage] = true、[permanentNoImage] = false，每次更新重試。
/// - 永久負取：[permanentNoImage] = true（確認非角色），不再重試。
class ItemImageEntry {
  /// 建立 [ItemImageEntry]。
  const ItemImageEntry({
    required this.iconUrl,
    required this.noImage,
    required this.permanentNoImage,
    this.detailByLang = const {},
    this.hasLuckdraw,
  });

  /// 角色 icon 小圖 CDN URL；負取時為 null。
  final String? iconUrl;

  /// 負取標記：本物經 API 確認無圖（非角色／圖未上架）。
  final bool noImage;

  /// 永久負取標記：確認非角色、不再重試（D11 最佳化）。
  ///
  /// OPEN ITEM（R17）：判定條件待 §九 API 樣本確認前一律寫 false（每次重試），
  /// 永久負取分支尚未啟用；schema 先就位，待樣本到位再補判定。
  final bool permanentNoImage;

  /// 該角色是否有喚取（Luckdraw）Spine 立繪：null＝尚未評估（詳情未抓）、true／false＝已評估。武器／道具評估後恆 false。
  final bool? hasLuckdraw;

  /// 各語言 dialog 詳情；key 為擷取 languageCode。某 lang 不在 map = 尚未抓。
  final Map<String, ItemDetailL10n> detailByLang;

  /// 是否有可顯示的成功 icon（D7：是否有圖的權威判定基礎）。
  bool get hasIcon => !noImage && iconUrl != null && iconUrl!.isNotEmpty;
}

/// 跨帳號共用的物品圖片 lookup index（單表）。
class ItemImageIndex {
  /// 建立 [ItemImageIndex]。
  const ItemImageIndex({required this.items});

  /// 建立空 index。
  const ItemImageIndex.empty() : items = const {};

  /// `resourceId` → [ItemImageEntry]（含正取 / 負取 / 永久負取）。
  final Map<int, ItemImageEntry> items;

  /// 以 [resourceId] 查 entry；查無回 null。
  ItemImageEntry? lookupImage(int resourceId) => items[resourceId];
}

/// 負責 `item_image_index.json` 的讀寫（atomic write，跨帳號共用）。
class ItemImageIndexStorage {
  /// 建立 [ItemImageIndexStorage]，需指定圖檔快取根目錄 [baseDir]。
  ItemImageIndexStorage(this.baseDir);

  /// Logger 實例。
  static final _log = Logger('item_image.storage');

  /// 資料根目錄。
  final Directory baseDir;

  /// index 檔路徑。
  File get _file => File('${baseDir.path}/item_image_index.json');

  /// 讀取 index；檔案不存在或解析失敗回空 index。
  Future<ItemImageIndex> load() async {
    final f = _file;
    if (!await f.exists()) return const ItemImageIndex.empty();
    try {
      final text = await f.readAsString();
      final json = jsonDecode(text) as Map<String, dynamic>;
      final itemsJson = (json['items'] as Map<String, dynamic>?) ?? const {};
      final items = <int, ItemImageEntry>{};
      itemsJson.forEach((k, v) {
        final id = int.tryParse(k);
        if (id == null || v is! Map<String, dynamic>) return;
        items[id] = ItemImageEntry(
          iconUrl: v['icon_url'] as String?,
          noImage: (v['no_image'] as bool?) ?? false,
          permanentNoImage: (v['permanent_no_image'] as bool?) ?? false,
          detailByLang: _detailByLangFromJson(v['detail_by_lang']),
          hasLuckdraw: v['has_luckdraw'] as bool?,
        );
      });
      return ItemImageIndex(items: items);
    } catch (e, st) {
      _log.warning('load failed, return empty index', e, st);
      return const ItemImageIndex.empty();
    }
  }

  /// 將 [index] 寫回磁碟（atomic rename）。
  Future<void> save(ItemImageIndex index) async {
    final json = {
      'version': 2,
      'items': index.items.map(
        (k, v) => MapEntry('$k', {
          'icon_url': v.iconUrl,
          'no_image': v.noImage,
          'permanent_no_image': v.permanentNoImage,
          'has_luckdraw': v.hasLuckdraw,
          'detail_by_lang': v.detailByLang.map(
            (l, d) => MapEntry(l, d.toJson()),
          ),
        }),
      ),
    };
    await baseDir.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(json));
    await tmp.rename(_file.path);
    _log.fine('saved items=${index.items.length}');
  }

  /// 將 index 重設為空，用於「強制重抓所有物品圖片」操作。
  Future<void> clearAll() async {
    await save(const ItemImageIndex.empty());
    _log.info('clearAll: index reset to empty');
  }

  /// 刪除 [baseDir] 內所有圖檔並重建空目錄。
  /// 目錄不存在時直接建立；失敗（權限被鎖等）直接拋給呼叫方處理。
  Future<void> wipeCacheDirectory() async {
    if (await baseDir.exists()) {
      await baseDir.delete(recursive: true);
    }
    await baseDir.create(recursive: true);
    _log.info(
      'wipeCacheDirectory: cache cleared at ${sanitizeFsPath(baseDir.path)}',
    );
  }

  /// 刪除 [baseDir] 內所有造型大圖檔（檔名含 `_illustration` 或 `_luckdraw`），
  /// 保留 icon 小圖；回傳刪除的檔案數。index 不動 —— 下次打開角色詳情會 lazy
  /// 重新下載造型圖，luckdraw 立繪則由 WebView2 擷取補回。
  Future<int> deleteIllustrationCacheFiles() async {
    if (!await baseDir.exists()) return 0;
    var deleted = 0;
    await for (final entity in baseDir.list()) {
      if (entity is! File) continue;
      if (entity.path.contains('_illustration') ||
          entity.path.contains('_luckdraw')) {
        await entity.delete();
        deleted++;
      }
    }
    _log.info(
      'deleteIllustrationCacheFiles: removed $deleted files'
      ' from ${sanitizeFsPath(baseDir.path)}',
    );
    return deleted;
  }
}

/// 推導 icon 的 cache 路徑：`<resourceId>_icon.<ext>`。
File itemIconCacheFile({
  required Directory baseDir,
  required int resourceId,
  required String url,
}) {
  return File('${baseDir.path}/${resourceId}_icon.${_extFromUrl(url)}');
}

/// 原子寫入圖檔：先寫 `<target>.tmp` 再 rename 覆蓋目標。
///
/// 避免讀取端（[FileImage]）在寫入過程中讀到 0-byte／半寫檔——空檔載入失敗會被
/// Flutter ImageCache 以路徑為 key 快取住，需換頁 evict 或重啟才恢復。rename 在
/// 同磁碟上為原子操作，讀取端只會看到「檔案不存在」或「完整檔案」兩種狀態。
Future<void> writeImageFileAtomic(File target, List<int> bytes) async {
  // 確保父目錄存在：使用者可能手動刪掉整個 cache 資料夾，此時直接寫會丟例外。
  await target.parent.create(recursive: true);
  final tmp = File('${target.path}.tmp');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(target.path);
}

/// 判斷某 [resourceId] 是否需要（重新）抓圖。
///
/// 回傳 true 的情形：(1) index 無此紀錄；(2) 負取且非永久（每次更新重試）；
/// (3) index 標記正取（[ItemImageEntry.hasIcon]）但對應 icon cache 檔已不存在——
/// 例如使用者手動刪除快取資料夾，使記憶體 index 與磁碟不同步。少了 (3) 的話，
/// 檔案被刪後 worklist 仍視為「已抓」而永不補圖，需重啟讓 index 從磁碟重載才恢復。
bool needsItemImageFetch({
  required ItemImageEntry? existing,
  required Directory cacheDir,
  required int resourceId,
}) {
  if (existing == null) return true;
  if (existing.noImage) return !existing.permanentNoImage;
  if (existing.hasIcon) {
    return !itemIconCacheFile(
      baseDir: cacheDir,
      resourceId: resourceId,
      url: existing.iconUrl!,
    ).existsSync();
  }
  return false;
}

/// 推導造型 formation 大圖的 cache 路徑：
/// `<resourceId>_illustration_<urlToken>.<ext>`。
///
/// 保留 `_illustration` token 讓快取用量／清除沿用既有比對；urlToken 取自 URL 末段
/// 檔名，讓同角色多造型各有獨立檔、不互相覆蓋。
File itemIllustrationCacheFile({
  required Directory baseDir,
  required int resourceId,
  required String url,
}) {
  return File(
    '${baseDir.path}/${resourceId}_illustration_'
    '${_urlToken(url)}.${_extFromUrl(url)}',
  );
}

/// 推導喚取（Luckdraw）立繪的 cache 路徑：`<resourceId>_luckdraw.png`。
///
/// 喚取立繪由 WebView2 擷取 encore 渲染的 canvas 而來，無語言差異，每 id 一檔。
File itemLuckdrawCacheFile({
  required Directory baseDir,
  required int resourceId,
}) {
  return File('${baseDir.path}/${resourceId}_luckdraw.png');
}

/// 由 [url] 末段檔名取安全 token（去 query／副檔名、非 `[A-Za-z0-9_]` 換成 `_`）。
String _urlToken(String url) {
  final qIdx = url.indexOf('?');
  final clean = qIdx >= 0 ? url.substring(0, qIdx) : url;
  var base = clean.substring(clean.lastIndexOf('/') + 1);
  final dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  final token = base.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  return token.isEmpty ? 'x' : token;
}

/// 從 storage JSON 還原 `detail_by_lang`；缺/型別不符回空 map。
Map<String, ItemDetailL10n> _detailByLangFromJson(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, ItemDetailL10n>{};
  raw.forEach((k, v) {
    if (k is String && v is Map<String, dynamic>) {
      out[k] = ItemDetailL10n.fromJson(v);
    }
  });
  return out;
}

/// 從 [url] 推導副檔名（無則回 `png`）。
String _extFromUrl(String url) {
  if (url.isEmpty) return 'png';
  final qIdx = url.indexOf('?');
  final clean = qIdx >= 0 ? url.substring(0, qIdx) : url;
  final dotIdx = clean.lastIndexOf('.');
  final slashIdx = clean.lastIndexOf('/');
  if (dotIdx <= slashIdx || dotIdx == clean.length - 1) return 'png';
  final ext = clean.substring(dotIdx + 1).toLowerCase();
  const allowed = {'png', 'jpg', 'jpeg', 'webp', 'gif'};
  return allowed.contains(ext) ? ext : 'png';
}
