import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/file_access.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_save.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_type_kind.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/luckdraw_capture_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/luckdraw_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/gacha_item_detail_dialog.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/zoomable_image_overlay.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/scroll/scroll_affordance.dart';

GachaRecord _rec({
  required int resourceId,
  required String name,
  int qualityLevel = 5,
  String resourceType = '角色',
  String languageCode = '',
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: qualityLevel,
  resourceType: resourceType,
  cardPoolType: '1',
  name: name,
  count: 1,
  time: DateTime(2026, 5, 24),
  languageCode: languageCode,
);

/// 雙欄版面左欄（資訊欄）的 key。
const detailsColumnKey = ValueKey('detail-info-column');

/// 找 label 文字為 [text] 的詳情 tag [Chip]（與 [ChoiceChip] 切換器 chip 區隔）。
Finder _chipWithText(String text) =>
    find.ancestor(of: find.text(text), matching: find.byType(Chip));

/// 永不解析的 fetcher：[downloadImage] 回傳 never-complete future，讓重抓後
/// 的 loading 狀態維持不變（測試才能穩定觀察到 spinner，而非瞬間轉 failed）。
class _HangingFetcher extends ItemImageFetcher {
  @override
  Future<Uint8List?> downloadImage(String url, http.Client client) =>
      Completer<Uint8List?>().future;
}

/// 記錄 [capture] 收到的 [force] 旗標的假擷取服務；回傳預先給的檔（不開 webview）。
/// 用來驗證重抓會以 `force: true` 強制重新擷取（而非短路回舊檔）。
class _RecordingCaptureService extends LuckdrawCaptureService {
  _RecordingCaptureService(Directory dir, this._fileToReturn)
    : super(cacheDir: dir);

  final File _fileToReturn;

  /// 最近一次 [capture] 收到的 [force] 值。
  bool? lastForce;

  @override
  Future<File?> capture({
    required int resourceId,
    required String kind,
    required String lang,
    bool force = false,
  }) async {
    lastForce = force;
    return _fileToReturn;
  }
}

/// 在 [dir] 內建立一個指定路徑的假圖檔（內容隨意，僅供 existsSync 命中）。
Future<File> _touchFile(Directory dir, String relative) async {
  final f = File('${dir.path}/$relative');
  await f.create(recursive: true);
  await f.writeAsBytes([0x89, 0x50, 0x4E, 0x47]); // PNG magic, 4 bytes
  return f;
}

void main() {
  late Directory tempDir;
  late ProviderContainer container;

  /// 以 [tempDir] 為快取根重建 [container]。重建會 dispose 舊 container，
  /// 故新 container 以 [addTearDown] 收尾。
  ///
  /// 僅建立 container、不 await index 載入：在 `testWidgets` 的 fake-async 區內
  /// 直接 await 真實磁碟 I/O 會卡住，故載入交由呼叫端在 [WidgetTester.runAsync]
  /// 內呼叫 `waitForLoad()`（見 [loadIndex]）。
  void rebuildContainer({
    ItemImageFetcher? fetcher,
    LuckdrawCaptureService? luckdraw,
    bool android = false,
  }) {
    container = ProviderContainer(
      overrides: [
        isAndroidProvider.overrideWithValue(android),
        itemImageIndexStorageProvider.overrideWithValue(
          ItemImageIndexStorage(tempDir),
        ),
        itemImageCacheDirProvider.overrideWithValue(tempDir),
        if (fetcher != null)
          itemImageFetcherProvider.overrideWithValue(fetcher),
        if (luckdraw != null)
          luckdrawCaptureServiceProvider.overrideWithValue(luckdraw),
      ],
    );
    addTearDown(container.dispose);
  }

  /// 等 [container] 的 index 從磁碟載入完成；務必在 [WidgetTester.runAsync] 內呼叫。
  Future<void> loadIndex() =>
      container.read(itemImageIndexProvider.notifier).waitForLoad();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gacha_item_detail_test_');
    rebuildContainer();
    await loadIndex();
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  /// 把 hasItemDetailContent 包成 widget context 內可呼叫的 helper。
  Future<bool> checkContent(WidgetTester tester, GachaRecord r) async {
    bool? out;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) {
            out = hasItemDetailContent(ref, r);
            return const SizedBox();
          },
        ),
      ),
    );
    return out!;
  }

  group('hasItemDetailContent', () {
    testWidgets('空 index → false（武器/道具均同）', (tester) async {
      expect(
        await checkContent(
          tester,
          _rec(resourceId: 99, name: 'WeaponX', resourceType: '武器'),
        ),
        isFalse,
      );
    });

    testWidgets('lookup miss → false', (tester) async {
      expect(
        await checkContent(tester, _rec(resourceId: 999, name: 'Unknown')),
        isFalse,
      );
    });

    testWidgets('entry iconUrl 空 → false', (tester) async {
      await tester.runAsync(() async {
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeIcon(
              resourceId: 111,
              iconUrl: '',
              noImage: true,
              permanentNoImage: false,
            );
      });
      expect(
        await checkContent(tester, _rec(resourceId: 111, name: 'X')),
        isFalse,
      );
    });

    testWidgets('icon URL 存在但 cache file 未到 → false', (tester) async {
      await tester.runAsync(() async {
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeIcon(
              resourceId: 111,
              iconUrl: 'https://cdn.example.com/x_icon.png',
              noImage: false,
              permanentNoImage: false,
            );
      });
      expect(
        await checkContent(tester, _rec(resourceId: 111, name: 'X')),
        isFalse,
      );
    });

    testWidgets('icon file 存在 → true', (tester) async {
      const iconUrl = 'https://cdn.example.com/x_icon.png';
      await tester.runAsync(() async {
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeIcon(
              resourceId: 111,
              iconUrl: iconUrl,
              noImage: false,
              permanentNoImage: false,
            );
        final cacheFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 111,
          url: iconUrl,
        );
        await _touchFile(tempDir, cacheFile.uri.pathSegments.last);
      });
      expect(
        await checkContent(tester, _rec(resourceId: 111, name: 'X')),
        isTrue,
      );
    });
  });

  Future<void> pumpDialog(WidgetTester tester, GachaRecord record) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          // 鎖繁中：立繪／圖示／encore 連結等斷言均比對 app_zh.arb 文案。
          locale: const Locale('zh'),
          theme: buildDarkTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SizedBox()),
        ),
      ),
    );
    final navigatorState = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      showDialog<void>(
        context: navigatorState.context,
        builder: (_) => GachaItemDetailDialog(record: record),
      ),
    );
    // 立繪載入中的 CircularProgressIndicator 會永久播動畫、令 pumpAndSettle
    // timeout，故改以固定 frame 推進。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('GachaItemDetailDialog 渲染', () {
    testWidgets('icon 存在 → title row 有 icon Image + name', (tester) async {
      const iconUrl = 'https://cdn.example.com/x_icon.png';
      await tester.runAsync(() async {
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeIcon(
              resourceId: 111,
              iconUrl: iconUrl,
              noImage: false,
              permanentNoImage: false,
            );
        final cacheFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 111,
          url: iconUrl,
        );
        await _touchFile(tempDir, cacheFile.uri.pathSegments.last);
      });

      await pumpDialog(tester, _rec(resourceId: 111, name: 'X'));

      expect(find.byType(GachaItemDetailDialog), findsOneWidget);
      expect(find.text('X'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GachaItemDetailDialog),
          matching: find.byType(Image),
        ),
        findsAtLeastNWidgets(1),
      );
    });

    testWidgets('icon 不存在 → dialog 只顯示 name，title 無 Image', (tester) async {
      await pumpDialog(tester, _rec(resourceId: 999, name: 'NoImage'));

      expect(find.byType(GachaItemDetailDialog), findsOneWidget);
      expect(find.text('NoImage'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GachaItemDetailDialog),
          matching: find.byType(Image),
        ),
        findsNothing,
      );
    });

    testWidgets('小視窗 (640x480) 不會 vertical overflow', (tester) async {
      tester.view.physicalSize = const Size(640, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await pumpDialog(tester, _rec(resourceId: 999, name: 'X'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('長簡介在寬視窗下換行、不把 dialog 撐寬（保持 ≤ md 寬）', (tester) async {
      // 寬度未達雙欄門檻（1000），維持單欄：簡介在 title 區。
      tester.view.physicalSize = const Size(990, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      rebuildContainer();
      const iconUrl = 'https://cdn.example.com/long_icon.png';
      final longIntro = '這是一段刻意很長的角色簡介，用來驗證在寬視窗下會換行而非撐寬 dialog。' * 20;
      await tester.runAsync(() async {
        await loadIndex();
        final notifier = container.read(itemImageIndexProvider.notifier);
        await notifier.mergeIcon(
          resourceId: 222,
          iconUrl: iconUrl,
          noImage: false,
          permanentNoImage: false,
        );
        await notifier.mergeItemDetail(
          resourceId: 222,
          lang: 'zh-Hant',
          detail: ItemDetailL10n(
            intro: longIntro,
            elementName: '',
            weaponTypeName: '',
            skins: [],
          ),
        );
        final cacheFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 222,
          url: iconUrl,
        );
        await _touchFile(tempDir, cacheFile.uri.pathSegments.last);
      });

      await pumpDialog(
        tester,
        _rec(resourceId: 222, name: 'LongIntro', languageCode: 'zh-Hant'),
      );

      // 長簡介確實渲染（width 測試才有意義）。
      expect(find.byType(Html), findsOneWidget);
      // AppDialog 把 title 鎖在 md(640) 寬 → 簡介 Html 被限制在 title 內（約
      // 640 扣掉 icon／間距／padding ≈ 560px）換行，不會以 intrinsic 單行寬度
      // 擴張到接近視窗寬(990)。修壞時 Html 會 >900px。
      expect(tester.getSize(find.byType(Html)).width, lessThan(700));
    });

    testWidgets('actions 區有 encore 外部連結按鈕（含 open_in_new icon）', (tester) async {
      await pumpDialog(tester, _rec(resourceId: 999, name: 'X'));
      expect(find.byIcon(Icons.open_in_new), findsOneWidget);
      expect(find.text('在 encore.moe 查看'), findsOneWidget);
    });

    testWidgets('武器（僅 icon、無立繪）→ 無 chip 列、無 spinner、放大顯示 icon', (tester) async {
      const iconUrl = 'https://cdn.example.com/w_icon.webp';
      late File iconFile;
      await tester.runAsync(() async {
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeIcon(
              resourceId: 77,
              iconUrl: iconUrl,
              noImage: false,
              permanentNoImage: false,
            );
        iconFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 77,
          url: iconUrl,
        );
        await _touchFile(tempDir, iconFile.uri.pathSegments.last);
      });

      await pumpDialog(
        tester,
        _rec(resourceId: 77, name: 'WeaponX', resourceType: '武器'),
      );

      // 單一 chip → chip 列隱藏。
      expect(find.byType(ChoiceChip), findsNothing);
      // Icon chip 永遠 ready → 無永久 spinner。
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // content 大圖即 icon（以 ValueKey(file.path) 辨識）。
      expect(find.byKey(ValueKey(iconFile.path)), findsOneWidget);
    });

    testWidgets('角色（立繪+icon）→ 2 chips、icon 在最後（切到最後一個顯示 icon）', (tester) async {
      const iconUrl = 'https://cdn.example.com/c_icon.png';
      const illustUrl = 'https://cdn.example.com/c_illust.png';
      late File iconFile;
      late File illustFile;
      await tester.runAsync(() async {
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeIcon(
              resourceId: 111,
              iconUrl: iconUrl,
              noImage: false,
              permanentNoImage: false,
            );
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeItemDetail(
              resourceId: 111,
              lang: 'zh-Hant',
              detail: const ItemDetailL10n(
                intro: '',
                elementName: '',
                weaponTypeName: '',
                skins: [
                  ItemSkin(
                    formationCard: illustUrl,
                    name: '新綠致意',
                    subDecName: '初始服飾',
                    bgDescription: '造型故事',
                  ),
                ],
              ),
            );
        iconFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 111,
          url: iconUrl,
        );
        await _touchFile(tempDir, iconFile.uri.pathSegments.last);
        illustFile = itemIllustrationCacheFile(
          baseDir: tempDir,
          resourceId: 111,
          url: illustUrl,
        );
        await _touchFile(tempDir, illustFile.uri.pathSegments.last);
      });
      rebuildContainer();
      await tester.runAsync(loadIndex);

      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );

      // 2 chips。
      expect(find.byType(ChoiceChip), findsNWidgets(2));
      // 預設（index 0）顯示立繪。
      expect(find.byKey(ValueKey(illustFile.path)), findsOneWidget);

      // 切到最後一個 chip → 顯示 icon（證明 icon 排最後）。
      await tester.tap(find.byType(ChoiceChip).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(ValueKey(iconFile.path)), findsOneWidget);
    });
  });

  group('GachaItemDetailDialog 詳情（intro + tags + encore link）', () {
    /// 在 index 寫入 [resourceId] 的 icon（並建立 icon cache 檔）＋ [lang] 的詳情。
    Future<void> seedWithDetail(
      WidgetTester tester, {
      required int resourceId,
      required String lang,
      required ItemDetailL10n detail,
      String iconUrl = 'https://cdn.example.com/x_icon.png',
    }) async {
      await tester.runAsync(() async {
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeIcon(
              resourceId: resourceId,
              iconUrl: iconUrl,
              noImage: false,
              permanentNoImage: false,
            );
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeItemDetail(
              resourceId: resourceId,
              lang: lang,
              detail: detail,
            );
        final cacheFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: resourceId,
          url: iconUrl,
        );
        await _touchFile(tempDir, cacheFile.uri.pathSegments.last);
      });
    }

    testWidgets(
      '角色（record lang 有詳情）→ Html + 5★/元素/武器類型 chips + 造型/圖示 chip + caption + encore link',
      (tester) async {
        const iconUrl = 'https://cdn.example.com/c_icon.png';
        const illustUrl = 'https://cdn.example.com/c_illust.png';
        await tester.runAsync(() async {
          await container
              .read(itemImageIndexProvider.notifier)
              .mergeIcon(
                resourceId: 1503,
                iconUrl: iconUrl,
                noImage: false,
                permanentNoImage: false,
              );
          await container
              .read(itemImageIndexProvider.notifier)
              .mergeItemDetail(
                resourceId: 1503,
                lang: 'zh-Hant',
                detail: const ItemDetailL10n(
                  intro: '<p>角色簡介內文</p>',
                  elementName: '衍射',
                  weaponTypeName: '音感儀',
                  skins: [
                    ItemSkin(
                      formationCard: illustUrl,
                      name: '新綠致意',
                      subDecName: '初始服飾',
                      bgDescription: '造型故事',
                    ),
                  ],
                ),
              );
          final iconCacheFile = itemIconCacheFile(
            baseDir: tempDir,
            resourceId: 1503,
            url: iconUrl,
          );
          await _touchFile(tempDir, iconCacheFile.uri.pathSegments.last);
          final illustCacheFile = itemIllustrationCacheFile(
            baseDir: tempDir,
            resourceId: 1503,
            url: illustUrl,
          );
          await _touchFile(tempDir, illustCacheFile.uri.pathSegments.last);
        });
        rebuildContainer();
        // rebuildContainer 換了新 container；index 已 persist 至同 tempDir，
        // 新 container 的 notifier load 後即可讀到。runAsync 確保 fake-async 區內
        // 仍能完成真實磁碟載入。
        await tester.runAsync(loadIndex);

        await pumpDialog(
          tester,
          _rec(
            resourceId: 1503,
            name: 'Char',
            resourceType: '角色',
            languageCode: 'zh-Hant',
          ),
        );

        // 簡介＋造型 BgDescription 各一個 Html。
        expect(find.byType(Html), findsNWidgets(2));
        expect(_chipWithText('5★'), findsOneWidget);
        expect(_chipWithText('衍射'), findsOneWidget);
        expect(_chipWithText('音感儀'), findsOneWidget);
        // 造型 chip 標籤為造型名稱；圖下方 caption 顯示 Name/SubDecName/BgDescription。
        expect(find.text('新綠致意'), findsWidgets); // chip 標籤＋caption Name
        expect(find.text('初始服飾'), findsOneWidget); // SubDecName（純文字）
        // BgDescription 經 flutter_html 渲染（RichText）。
        expect(find.text('造型故事', findRichText: true), findsWidgets);
        expect(find.text('圖示'), findsOneWidget);
        expect(find.text('在 encore.moe 查看'), findsOneWidget);
      },
    );

    testWidgets(
      '武器（elementName 空、weaponTypeName=長刃、無立繪）→ 無 ChoiceChip、有長刃 chip、無元素 chip',
      (tester) async {
        const iconUrl = 'https://cdn.example.com/w_icon.webp';
        late File iconFile;
        await tester.runAsync(() async {
          await container
              .read(itemImageIndexProvider.notifier)
              .mergeIcon(
                resourceId: 21010011,
                iconUrl: iconUrl,
                noImage: false,
                permanentNoImage: false,
              );
          await container
              .read(itemImageIndexProvider.notifier)
              .mergeItemDetail(
                resourceId: 21010011,
                lang: 'zh-Hant',
                detail: const ItemDetailL10n(
                  intro: '<p>武器簡介</p>',
                  elementName: '',
                  weaponTypeName: '長刃',
                  skins: [],
                ),
              );
          iconFile = itemIconCacheFile(
            baseDir: tempDir,
            resourceId: 21010011,
            url: iconUrl,
          );
          await _touchFile(tempDir, iconFile.uri.pathSegments.last);
        });
        rebuildContainer();
        await tester.runAsync(loadIndex);

        await pumpDialog(
          tester,
          _rec(
            resourceId: 21010011,
            name: 'WeaponX',
            resourceType: '武器',
            languageCode: 'zh-Hant',
          ),
        );

        // 只有 icon 一張圖 → chip 列隱藏。
        expect(find.byType(ChoiceChip), findsNothing);
        expect(_chipWithText('長刃'), findsOneWidget);
        // elementName 空 → 不應出現任何「衍射」之類元素 chip；至少確認 5★ 與長刃存在、
        // 詳情 tag 僅 2 個（★ + 武器類型）。
        expect(_chipWithText('5★'), findsOneWidget);
      },
    );

    testWidgets('record lang 無詳情、他 lang 有 → fallback 到 values.first 仍渲染 Html', (
      tester,
    ) async {
      const iconUrl = 'https://cdn.example.com/c_icon.png';
      await tester.runAsync(() async {
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeIcon(
              resourceId: 1503,
              iconUrl: iconUrl,
              noImage: false,
              permanentNoImage: false,
            );
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeItemDetail(
              resourceId: 1503,
              lang: 'en',
              detail: const ItemDetailL10n(
                intro: '<p>English intro</p>',
                elementName: 'Spectro',
                weaponTypeName: 'Sword',
                skins: [],
              ),
            );
        final iconCacheFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 1503,
          url: iconUrl,
        );
        await _touchFile(tempDir, iconCacheFile.uri.pathSegments.last);
      });
      // record.languageCode = zh-Hant 但只 populate en → 走 detailByLang.values.first。
      rebuildContainer();
      await tester.runAsync(loadIndex);

      await pumpDialog(
        tester,
        _rec(
          resourceId: 1503,
          name: 'Char',
          resourceType: '角色',
          languageCode: 'zh-Hant',
        ),
      );

      expect(find.byType(Html), findsOneWidget);
      expect(_chipWithText('Spectro'), findsOneWidget);
    });

    testWidgets(
      '完全無詳情（detailByLang 空）→ icon + name + encore link + close、無 Html/元素 chip、不崩、5★ 仍在',
      (tester) async {
        const iconUrl = 'https://cdn.example.com/c_icon.png';
        await tester.runAsync(() async {
          await container
              .read(itemImageIndexProvider.notifier)
              .mergeIcon(
                resourceId: 1503,
                iconUrl: iconUrl,
                noImage: false,
                permanentNoImage: false,
              );
          final iconCacheFile = itemIconCacheFile(
            baseDir: tempDir,
            resourceId: 1503,
            url: iconUrl,
          );
          await _touchFile(tempDir, iconCacheFile.uri.pathSegments.last);
        });

        await pumpDialog(
          tester,
          _rec(resourceId: 1503, name: 'Char', resourceType: '角色'),
        );

        expect(tester.takeException(), isNull);
        expect(find.text('Char'), findsOneWidget);
        expect(find.text('在 encore.moe 查看'), findsOneWidget);
        expect(find.byType(Html), findsNothing);
        // 詳情 tag 只剩 ★（無元素／武器類型詳情）。
        expect(_chipWithText('5★'), findsOneWidget);
      },
    );

    testWidgets('encore 外部連結 label 存在（findsOneWidget）', (tester) async {
      await seedWithDetail(
        tester,
        resourceId: 1503,
        lang: 'zh-Hant',
        detail: const ItemDetailL10n(
          intro: '<p>x</p>',
          elementName: '衍射',
          weaponTypeName: '音感儀',
          skins: [],
        ),
      );
      rebuildContainer();
      await tester.runAsync(loadIndex);

      await pumpDialog(
        tester,
        _rec(
          resourceId: 1503,
          name: 'Char',
          resourceType: '角色',
          languageCode: 'zh-Hant',
        ),
      );

      expect(find.text('在 encore.moe 查看'), findsOneWidget);
    });

    testWidgets('簡介含 <te> 詞條標籤 → 詞條內文不缺字（剝標籤後完整顯示）', (tester) async {
      await seedWithDetail(
        tester,
        resourceId: 1104,
        lang: 'zh-Hant',
        detail: const ItemDetailL10n(
          intro:
              '<te href=850091>今州</te>成員，'
              '以自己的方式詮釋著「<te href=850131>獅子舞</te>」的含義。',
          elementName: '',
          weaponTypeName: '',
          skins: [],
        ),
      );
      rebuildContainer();
      await tester.runAsync(loadIndex);

      await pumpDialog(
        tester,
        _rec(
          resourceId: 1104,
          name: 'Char',
          resourceType: '角色',
          languageCode: 'zh-Hant',
        ),
      );

      expect(find.byType(Html), findsOneWidget);
      // 修壞（未剝標籤）時 <te> 內文（今州／獅子舞）會被 flutter_html 連同標籤丟棄缺字。
      expect(find.textContaining('今州', findRichText: true), findsOneWidget);
      expect(find.textContaining('獅子舞', findRichText: true), findsOneWidget);
    });

    /// 量測 dialog 簡介說明文字「第一個 glyph 頂端」與「名稱底部」的視覺間距。
    ///
    /// flutter_html 會以環境 [DefaultTextStyle] 當作 root 行高來源；簡介位在
    /// AlertDialog 的 title 區、環境字級是大行高的 titleTextStyle，未修正時單行簡介
    /// 會比多行簡介多沉約 8px。此 helper 供回歸測試比對單行／多行間距是否一致。
    Future<double> introGapAboveGlyph(WidgetTester tester, String intro) async {
      // 換掉 root widget type，徹底卸載前一次 pumpDialog 的 Navigator／overlay
      // （imperative showDialog 的 dialog route 會跨 pumpWidget 留存）。
      await tester.pumpWidget(const SizedBox());
      rebuildContainer();
      await tester.runAsync(() async {
        await loadIndex();
        final n = container.read(itemImageIndexProvider.notifier);
        await n.mergeIcon(
          resourceId: 1503,
          iconUrl: 'https://x/i.png',
          noImage: false,
          permanentNoImage: false,
        );
        await n.mergeItemDetail(
          resourceId: 1503,
          lang: 'zh-Hant',
          detail: ItemDetailL10n(
            intro: intro,
            elementName: '衍射',
            weaponTypeName: '音感儀',
            skins: const [],
          ),
        );
        final f = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 1503,
          url: 'https://x/i.png',
        );
        await _touchFile(tempDir, f.uri.pathSegments.last);
      });
      await pumpDialog(
        tester,
        _rec(
          resourceId: 1503,
          name: 'NameX',
          resourceType: '角色',
          languageCode: 'zh-Hant',
        ),
      );
      final nameBottom = tester.getRect(find.text('NameX')).bottom;
      final rich = find
          .descendant(of: find.byType(Html), matching: find.byType(RichText))
          .first;
      final rect = tester.getRect(rich);
      final para = tester.renderObject<RenderParagraph>(rich);
      final glyph = para
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1),
            boxHeightStyle: ui.BoxHeightStyle.tight,
          )
          .first;
      return rect.top + glyph.top - nameBottom;
    }

    testWidgets('簡介換行與不換行時、與名稱的間距一致（flutter_html 單行 leading 修正）', (
      tester,
    ) async {
      final singleLine = await introGapAboveGlyph(tester, '短簡介');
      final multiLine = await introGapAboveGlyph(tester, '長' * 200);
      expect(
        (singleLine - multiLine).abs(),
        lessThan(1.0),
        reason: '單行簡介間距=$singleLine、多行簡介間距=$multiLine，兩者應一致',
      );
    });
  });

  group('GachaItemTapTarget', () {
    testWidgets('icon file 存在 → 可點、點下去 dialog 出現', (tester) async {
      const iconUrl = 'https://cdn.example.com/x_icon.png';
      await tester.runAsync(() async {
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeIcon(
              resourceId: 111,
              iconUrl: iconUrl,
              noImage: false,
              permanentNoImage: false,
            );
        final cacheFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 111,
          url: iconUrl,
        );
        await _touchFile(tempDir, cacheFile.uri.pathSegments.last);
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildDarkTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: GachaItemTapTarget(
                record: _rec(resourceId: 111, name: 'X'),
                child: const Text('tap-me'),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(GachaItemDetailDialog), findsNothing);
      await tester.tap(find.text('tap-me'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(GachaItemDetailDialog), findsOneWidget);
    });

    testWidgets('武器（無 icon）→ 點下去不出 dialog，passthrough 無 click cursor', (
      tester,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: GachaItemTapTarget(
                record: _rec(
                  resourceId: 77,
                  name: 'WeaponX',
                  resourceType: '武器',
                ),
                child: const Text('tap-me'),
              ),
            ),
          ),
        ),
      );

      final mouseRegions = tester.widgetList<MouseRegion>(
        find.descendant(
          of: find.byType(GachaItemTapTarget),
          matching: find.byType(MouseRegion),
        ),
      );
      expect(
        mouseRegions.any((m) => m.cursor == SystemMouseCursors.click),
        isFalse,
      );

      await tester.tap(find.text('tap-me'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(GachaItemDetailDialog), findsNothing);
    });

    testWidgets('lookup miss → passthrough，點下去不出 dialog', (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: GachaItemTapTarget(
                record: _rec(resourceId: 999, name: 'Unknown'),
                child: const Text('tap-me'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('tap-me'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(GachaItemDetailDialog), findsNothing);
    });
  });

  group('GachaItemDetailDialog illustration 可縮放', () {
    testWidgets(
      '有 illustration cache 檔 → 顯示可點 GestureDetector（含 click cursor）',
      (tester) async {
        const iconUrl = 'https://cdn.example.com/x_icon.png';
        const illustUrl = 'https://cdn.example.com/x_illust.png';
        await tester.runAsync(() async {
          await container
              .read(itemImageIndexProvider.notifier)
              .mergeIcon(
                resourceId: 111,
                iconUrl: iconUrl,
                noImage: false,
                permanentNoImage: false,
              );
          await container
              .read(itemImageIndexProvider.notifier)
              .mergeItemDetail(
                resourceId: 111,
                lang: 'zh-Hant',
                detail: const ItemDetailL10n(
                  intro: '',
                  elementName: '',
                  weaponTypeName: '',
                  skins: [
                    ItemSkin(
                      formationCard: illustUrl,
                      name: '新綠致意',
                      subDecName: '初始服飾',
                      bgDescription: '造型故事',
                    ),
                  ],
                ),
              );
          // 建立 icon cache 檔
          final iconCacheFile = itemIconCacheFile(
            baseDir: tempDir,
            resourceId: 111,
            url: iconUrl,
          );
          await _touchFile(tempDir, iconCacheFile.uri.pathSegments.last);
          // 建立 illustration cache 檔
          final illustCacheFile = itemIllustrationCacheFile(
            baseDir: tempDir,
            resourceId: 111,
            url: illustUrl,
          );
          await _touchFile(tempDir, illustCacheFile.uri.pathSegments.last);
        });
        rebuildContainer();
        await tester.runAsync(loadIndex);

        await pumpDialog(
          tester,
          _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
        );

        final mouseRegions = tester.widgetList<MouseRegion>(
          find.descendant(
            of: find.byType(GachaItemDetailDialog),
            matching: find.byType(MouseRegion),
          ),
        );
        expect(
          mouseRegions.any((m) => m.cursor == SystemMouseCursors.click),
          isTrue,
        );
      },
    );

    testWidgets('點 illustration → 開啟 ZoomableImageOverlay', (tester) async {
      const iconUrl = 'https://cdn.example.com/x_icon.png';
      const illustUrl = 'https://cdn.example.com/x_illust.png';
      late File illustFile;
      await tester.runAsync(() async {
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeIcon(
              resourceId: 111,
              iconUrl: iconUrl,
              noImage: false,
              permanentNoImage: false,
            );
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeItemDetail(
              resourceId: 111,
              lang: 'zh-Hant',
              detail: const ItemDetailL10n(
                intro: '',
                elementName: '',
                weaponTypeName: '',
                skins: [
                  ItemSkin(
                    formationCard: illustUrl,
                    name: '新綠致意',
                    subDecName: '初始服飾',
                    bgDescription: '造型故事',
                  ),
                ],
              ),
            );
        final iconCacheFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 111,
          url: iconUrl,
        );
        await _touchFile(tempDir, iconCacheFile.uri.pathSegments.last);
        illustFile = itemIllustrationCacheFile(
          baseDir: tempDir,
          resourceId: 111,
          url: illustUrl,
        );
        await _touchFile(tempDir, illustFile.uri.pathSegments.last);
      });
      rebuildContainer();
      await tester.runAsync(loadIndex);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildDarkTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showGachaItemDetailDialog(
                  ctx,
                  _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // illustration area に GestureDetector がある
      final mainImage = find.descendant(
        of: find.byType(GachaItemDetailDialog),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Image &&
              w.image is FileImage &&
              (w.image as FileImage).file.path == illustFile.path,
        ),
      );
      expect(mainImage, findsOneWidget);

      await tester.tap(mainImage);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(ZoomableImageOverlay), findsOneWidget);
      final overlay = tester.widget<ZoomableImageOverlay>(
        find.byType(ZoomableImageOverlay),
      );
      expect(overlay.suggestedFileName, isNotNull);
      expect(overlay.suggestedFileName, startsWith('Char'));
      expect(overlay.suggestedFileName, endsWith('.png'));
    });
  });

  group('GachaItemDetailDialog 圖片選單與重抓', () {
    /// seed 一個「角色 icon + 單一造型立繪」並建立兩個 cache 檔，回傳造型檔。
    /// [fetcher] 非空時覆寫 [itemImageFetcherProvider]（例如塞 [_HangingFetcher]）。
    Future<File> seedCharacterWithSkin(
      WidgetTester tester, {
      ItemImageFetcher? fetcher,
      bool android = false,
      String intro = '',
      String bgDescription = '',
    }) async {
      const iconUrl = 'https://cdn.example.com/m_icon.png';
      const illustUrl = 'https://cdn.example.com/m_illust.png';
      late File illustFile;
      await tester.runAsync(() async {
        final n = container.read(itemImageIndexProvider.notifier);
        await n.mergeIcon(
          resourceId: 111,
          iconUrl: iconUrl,
          noImage: false,
          permanentNoImage: false,
        );
        await n.mergeItemDetail(
          resourceId: 111,
          lang: 'zh-Hant',
          detail: ItemDetailL10n(
            intro: intro,
            elementName: '',
            weaponTypeName: '',
            skins: [
              ItemSkin(
                formationCard: illustUrl,
                name: '造型A',
                subDecName: '',
                bgDescription: bgDescription,
              ),
            ],
          ),
        );
        final iconCacheFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 111,
          url: iconUrl,
        );
        await _touchFile(tempDir, iconCacheFile.uri.pathSegments.last);
        illustFile = itemIllustrationCacheFile(
          baseDir: tempDir,
          resourceId: 111,
          url: illustUrl,
        );
        await _touchFile(tempDir, illustFile.uri.pathSegments.last);
      });
      rebuildContainer(fetcher: fetcher, android: android);
      await tester.runAsync(loadIndex);
      return illustFile;
    }

    testWidgets('ready 圖 → 圖片區有溢出選單按鈕（more_vert）', (tester) async {
      await seedCharacterWithSkin(tester);
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      expect(
        find.descendant(
          of: find.byType(GachaItemDetailDialog),
          matching: find.byIcon(Icons.more_vert),
        ),
        findsOneWidget,
      );
    });

    testWidgets('選單三項：複製圖片 / 儲存圖片 / 重抓圖片', (tester) async {
      await seedCharacterWithSkin(tester);
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(GachaItemDetailDialog),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('複製圖片'), findsOneWidget);
      expect(find.text('儲存圖片'), findsOneWidget);
      expect(find.text('重抓圖片'), findsOneWidget);
    });

    testWidgets('右鍵圖片 → 叫出同一選單（複製 / 儲存 / 重抓）', (tester) async {
      final illustFile = await seedCharacterWithSkin(tester);
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      // 右鍵（secondary button）點圖。
      await tester.tap(
        find.byKey(ValueKey(illustFile.path)),
        buttons: kSecondaryButton,
      );
      await tester.pump();
      // 等 showMenu 開場動畫（約 300ms）完整跑完。
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('複製圖片'), findsOneWidget);
      expect(find.text('儲存圖片'), findsOneWidget);
      expect(find.text('重抓圖片'), findsOneWidget);
    });

    testWidgets('mouse long press on the image does not open the menu', (
      tester,
    ) async {
      final illustFile = await seedCharacterWithSkin(tester);
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      await tester.longPressAt(
        tester.getCenter(find.byKey(ValueKey(illustFile.path))),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('儲存圖片'), findsNothing);
    });

    testWidgets('long press on the image opens the image menu', (tester) async {
      final illustFile = await seedCharacterWithSkin(tester);
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      await tester.longPress(find.byKey(ValueKey(illustFile.path)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('儲存圖片'), findsOneWidget);
    });

    /// 以 [size] 的畫面開啟詳情（平台由 test variant 決定），回傳名稱與圖片的位置。
    Future<(Rect, Rect)> pumpAt(
      WidgetTester tester,
      Size size, {
      String intro = '',
      String bgDescription = '',
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final illustFile = await seedCharacterWithSkin(
        tester,
        intro: intro,
        bgDescription: bgDescription,
      );
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      expect(tester.takeException(), isNull);
      return (
        tester.getRect(find.text('Char')),
        tester.getRect(find.byKey(ValueKey(illustFile.path))),
      );
    }

    testWidgets('phone landscape puts details and image side by side', (
      tester,
    ) async {
      final (name, image) = await pumpAt(tester, const Size(800, 360));
      expect(name.right, lessThan(image.left));
      expect((name.top - image.top).abs(), lessThan(100));
      expect(tester.getSize(find.byKey(detailsColumnKey)).width, 240);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('phone landscape keeps the skin caption in the left column', (
      tester,
    ) async {
      // 造型說明放在右欄會把立繪擠扁（實機上只剩約 120dp 高）。
      final (_, image) = await pumpAt(tester, const Size(800, 360));
      final captions = find
          .text('造型A')
          .evaluate()
          .map((e) => tester.getRect(find.byWidget(e.widget)));
      expect(captions.any((r) => r.right < image.left), isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('phone portrait stacks details above the image', (
      tester,
    ) async {
      final (name, image) = await pumpAt(tester, const Size(360, 800));
      expect(name.bottom, lessThan(image.top));
      expect(find.byKey(detailsColumnKey), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('wide desktop window puts details and image side by side', (
      tester,
    ) async {
      final (name, image) = await pumpAt(tester, const Size(1280, 800));
      expect(name.right, lessThan(image.left));
      expect(tester.getSize(find.byKey(detailsColumnKey)).width, 320);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('desktop window under 1000 wide stays single column', (
      tester,
    ) async {
      final (name, image) = await pumpAt(tester, const Size(900, 700));
      expect(name.bottom, lessThan(image.top));
      expect(find.byKey(detailsColumnKey), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    group('two-column details scroll as one region', () {
      /// 超過原本內層捲動上限的長簡介（使用者以「千咲」回報的情境）。
      final longIntro = '<p>${'千咲的簡介很長。' * 120}</p>';

      /// 簡介的 [Html]（左欄第一個 Html）。
      Finder intro() => find.byType(Html).first;

      /// 左欄底部的漸層提示。
      Finder bottomFade() => find.byWidgetPredicate(
        (w) => w is ScrollEdgeFade && w.side == ScrollSide.bottom,
      );

      testWidgets('dragging on the intro scrolls the whole column', (
        tester,
      ) async {
        await pumpAt(
          tester,
          const Size(1280, 800),
          intro: longIntro,
          bgDescription: '<p>造型說明</p>',
        );
        final scrollables = find.ancestor(
          of: intro(),
          matching: find.byType(Scrollable),
        );
        expect(scrollables, findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(detailsColumnKey),
            matching: find.byType(Scrollable),
          ),
          findsOneWidget,
        );
        final introTop = tester.getRect(intro()).top;
        final encore = tester.getRect(find.text('在 encore.moe 查看'));
        final close = tester.getRect(find.text('關閉'));

        await tester.dragFrom(
          tester.getTopLeft(intro()) + const Offset(40, 20),
          const Offset(0, -200),
        );
        await tester.pump();

        final position = tester.state<ScrollableState>(scrollables).position;
        expect(position.pixels, greaterThan(0));
        expect(tester.getRect(intro()).top, lessThan(introTop));
        expect(tester.getRect(find.text('在 encore.moe 查看')).top, encore.top);
        expect(tester.getRect(find.text('關閉')).top, close.top);
      }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

      testWidgets('bottom fade shows until scrolled to the end', (
        tester,
      ) async {
        await pumpAt(tester, const Size(1280, 800), intro: longIntro);
        await tester.pump();
        expect(bottomFade(), findsOneWidget);
        final position = tester
            .state<ScrollableState>(
              find.ancestor(of: intro(), matching: find.byType(Scrollable)),
            )
            .position;
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
        expect(bottomFade(), findsNothing);
      }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

      testWidgets('divider separates tags from the skin caption only', (
        tester,
      ) async {
        await pumpAt(tester, const Size(1280, 800));
        final divider = find.descendant(
          of: find.byKey(detailsColumnKey),
          matching: find.byType(Divider),
        );
        expect(divider, findsOneWidget);
        expect(
          tester.getRect(divider).bottom,
          lessThan(tester.getRect(find.text('造型A').first).top),
        );
        // 切到 Icon（無造型說明）→ 分隔線一併消失。
        await tester.tap(find.byType(ChoiceChip).last);
        await tester.pump();
        expect(divider, findsNothing);
      }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

      testWidgets('no bottom fade when the column fits', (tester) async {
        await pumpAt(tester, const Size(1280, 800), intro: '<p>短</p>');
        await tester.pump();
        expect(bottomFade(), findsNothing);
      }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

      testWidgets('phone portrait keeps the capped inner intro scroll', (
        tester,
      ) async {
        await pumpAt(tester, const Size(360, 800), intro: longIntro);
        final inner = find.ancestor(
          of: intro(),
          matching: find.byType(SingleChildScrollView),
        );
        expect(inner, findsOneWidget);
        expect(tester.getSize(inner).height, lessThanOrEqualTo(120));
        expect(tester.getSize(intro()).height, greaterThan(120));
        expect(bottomFade(), findsNothing);
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    });

    group('swipe between images', () {
      const iconUrl = 'https://cdn.example.com/m_icon.png';

      /// 開啟「造型A＋Icon」兩張圖的詳情，回傳 (造型檔, icon 檔)。
      Future<(File, File)> openTwoImages(WidgetTester tester) async {
        final skin = await seedCharacterWithSkin(tester);
        final icon = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 111,
          url: iconUrl,
        );
        await pumpDialog(
          tester,
          _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
        );
        return (skin, icon);
      }

      /// 圖片區目前顯示 [file] 的那張。
      Finder shown(File file) => find.byKey(ValueKey(file.path));

      /// 頁點（key 為 `page-dot-N`）。
      Finder dots() => find.byWidgetPredicate((w) {
        final k = w.key;
        return k is ValueKey<String> && k.value.startsWith('page-dot-');
      });

      /// 第 [i] 個頁點的寬度。
      double dotWidth(WidgetTester tester, int i) =>
          tester.getSize(find.byKey(ValueKey('page-dot-$i'))).width;

      testWidgets('swipe left goes to the next image, right goes back', (
        tester,
      ) async {
        final (skin, icon) = await openTwoImages(tester);
        expect(shown(skin), findsOneWidget);
        await tester.drag(shown(skin), const Offset(-120, 0));
        await tester.pump();
        expect(shown(icon), findsOneWidget);
        expect(shown(skin), findsNothing);
        await tester.drag(shown(icon), const Offset(120, 0));
        await tester.pump();
        expect(shown(skin), findsOneWidget);
      });

      testWidgets('no wrap-around at either end', (tester) async {
        final (skin, icon) = await openTwoImages(tester);
        await tester.drag(shown(skin), const Offset(120, 0));
        await tester.pump();
        expect(shown(skin), findsOneWidget);
        await tester.drag(shown(skin), const Offset(-120, 0));
        await tester.pump();
        await tester.drag(shown(icon), const Offset(-120, 0));
        await tester.pump();
        expect(shown(icon), findsOneWidget);
      });

      testWidgets('vertical drag never switches', (tester) async {
        final (skin, _) = await openTwoImages(tester);
        await tester.drag(shown(skin), const Offset(0, -120));
        await tester.pump();
        expect(shown(skin), findsOneWidget);
      });

      testWidgets('short slow drag does not switch', (tester) async {
        final (skin, _) = await openTwoImages(tester);
        await tester.timedDrag(
          shown(skin),
          const Offset(-20, 0),
          const Duration(seconds: 1),
        );
        await tester.pump();
        expect(shown(skin), findsOneWidget);
      });

      testWidgets('short fast flick switches', (tester) async {
        final (skin, icon) = await openTwoImages(tester);
        await tester.timedDrag(
          shown(skin),
          const Offset(-40, 0),
          const Duration(milliseconds: 60),
        );
        await tester.pump();
        expect(shown(icon), findsOneWidget);
      });

      testWidgets('trackpad horizontal pan switches', (tester) async {
        final (skin, icon) = await openTwoImages(tester);
        final center = tester.getCenter(shown(skin));
        final pointer = TestPointer(1, PointerDeviceKind.trackpad);
        await tester.sendEventToBinding(pointer.panZoomStart(center));
        await tester.sendEventToBinding(
          pointer.panZoomUpdate(center, pan: const Offset(-60, 0)),
        );
        await tester.sendEventToBinding(
          pointer.panZoomUpdate(center, pan: const Offset(-120, 0)),
        );
        await tester.sendEventToBinding(pointer.panZoomEnd());
        await tester.pump();
        expect(shown(icon), findsOneWidget);
      });

      testWidgets('tap still opens zoom and the menu button stays', (
        tester,
      ) async {
        final (skin, _) = await openTwoImages(tester);
        expect(find.byIcon(Icons.more_vert), findsOneWidget);
        await tester.tap(shown(skin));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(ZoomableImageOverlay), findsOneWidget);
      });

      testWidgets('page dots: one per image, selected one is wider', (
        tester,
      ) async {
        final (skin, _) = await openTwoImages(tester);
        expect(dots(), findsNWidgets(2));
        expect(dotWidth(tester, 0), 18);
        expect(dotWidth(tester, 1), 6);
        await tester.drag(shown(skin), const Offset(-120, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(dotWidth(tester, 0), 6);
        expect(dotWidth(tester, 1), 18);
      });

      testWidgets('single image: no dots, swipe does not throw', (
        tester,
      ) async {
        await tester.runAsync(() async {
          await container
              .read(itemImageIndexProvider.notifier)
              .mergeIcon(
                resourceId: 222,
                iconUrl: iconUrl,
                noImage: false,
                permanentNoImage: false,
              );
          final f = itemIconCacheFile(
            baseDir: tempDir,
            resourceId: 222,
            url: iconUrl,
          );
          await _touchFile(tempDir, f.uri.pathSegments.last);
        });
        rebuildContainer();
        await tester.runAsync(loadIndex);
        await pumpDialog(
          tester,
          _rec(resourceId: 222, name: 'Weapon', resourceType: '武器'),
        );
        final icon = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 222,
          url: iconUrl,
        );
        expect(dots(), findsNothing);
        await tester.drag(shown(icon), const Offset(-120, 0));
        await tester.drag(shown(icon), const Offset(120, 0));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(shown(icon), findsOneWidget);
      });
    });

    testWidgets('點 dialog 外圍 → barrier 仍能關閉（Scaffold 包裹不擋 barrier）', (
      tester,
    ) async {
      await seedCharacterWithSkin(tester);
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      expect(find.byType(GachaItemDetailDialog), findsOneWidget);
      // 點視窗左上角 (5,5)，落在置中 dialog 之外 → barrierDismissible 關閉。
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(GachaItemDetailDialog), findsNothing);
    });

    testWidgets('點複製圖片 → 在 dialog 之上彈出 toast（不被 dialog 蓋住）', (tester) async {
      addTearDown(resetItemImageSaveSeams);
      addTearDown(resetFileAccessSeams);
      itemImageEncoder = (_) async => Uint8List.fromList([1, 2, 3, 4]);
      pngClipboardWriter = (_) async => true;
      await seedCharacterWithSkin(tester);
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(GachaItemDetailDialog),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('複製圖片'));
      await tester.pump(); // 啟動 overlay toast 淡入
      // toast 為 overlay entry，疊在 dialog／modal barrier 之上、不被蓋住。
      expect(find.byKey(const ValueKey('dialogToast')), findsOneWidget);
      expect(find.text('已複製圖片到剪貼簿'), findsOneWidget);
      // flush 停留計時器與淡出動畫，避免測試結束時殘留 pending timer。
      await tester.pump(const Duration(milliseconds: 2200));
      await tester.pumpAndSettle();
    });

    /// 開啟 ready 圖的溢出選單。
    Future<void> openImageMenu(WidgetTester tester) async {
      await tester.tap(
        find.descendant(
          of: find.byType(GachaItemDetailDialog),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('item image menu offers share only on Android', (tester) async {
      await seedCharacterWithSkin(tester, android: true);
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      await openImageMenu(tester);
      expect(find.text('分享'), findsOneWidget);
    });

    testWidgets('item image menu hides share on desktop', (tester) async {
      await seedCharacterWithSkin(tester);
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      await openImageMenu(tester);
      expect(find.text('分享'), findsNothing);
    });

    testWidgets('sharing an item image sends a png named after the item', (
      tester,
    ) async {
      addTearDown(resetItemImageSaveSeams);
      addTearDown(resetFileAccessSeams);
      itemImageEncoder = (_) async => Uint8List.fromList([1, 2, 3, 4]);
      String? name;
      String? mime;
      fileSharer = (bytes, fileName, mimeType) async {
        name = fileName;
        mime = mimeType;
      };
      await seedCharacterWithSkin(tester, android: true);
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      await openImageMenu(tester);
      await tester.tap(find.text('分享'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(name, 'Char_造型A.png');
      expect(mime, 'image/png');
    });

    testWidgets(
      'saving and sharing replace illegal file name characters with underscores',
      (tester) async {
        addTearDown(resetItemImageSaveSeams);
        addTearDown(resetFileAccessSeams);
        itemImageEncoder = (_) async => Uint8List.fromList([1, 2, 3, 4]);
        final names = <String>[];
        fileSaveDialog = (_, name, _, _, _) async {
          names.add(name);
          return null;
        };
        fileSharer = (_, name, _) async => names.add(name);
        await seedCharacterWithSkin(tester, android: true);
        await pumpDialog(
          tester,
          _rec(resourceId: 111, name: 'Ch:ar/x', languageCode: 'zh-Hant'),
        );
        for (final label in ['儲存圖片', '分享']) {
          await openImageMenu(tester);
          await tester.tap(find.text(label));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
        }
        expect(names, ['Ch_ar_x_造型A.png', 'Ch_ar_x_造型A.png']);
      },
    );

    testWidgets('item image share failure shows shareFailed', (tester) async {
      addTearDown(resetItemImageSaveSeams);
      addTearDown(resetFileAccessSeams);
      itemImageEncoder = (_) async => Uint8List.fromList([1, 2, 3, 4]);
      fileSharer = (_, _, _) async => throw Exception('boom');
      await seedCharacterWithSkin(tester, android: true);
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      await openImageMenu(tester);
      await tester.tap(find.text('分享'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final l = AppLocalizations.of(
        tester.element(find.byType(GachaItemDetailDialog)),
      )!;
      expect(find.text(l.shareFailed), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2200));
      await tester.pumpAndSettle();
    });

    /// 開 dialog、選單點 [label]，並等動作與 toast 動畫跑完。
    Future<void> runMenuAction(WidgetTester tester, String label) async {
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      await openImageMenu(tester);
      await tester.tap(find.text(label));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    /// 結束前 flush toast 的停留計時器。
    Future<void> flushToast(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 2200));
      await tester.pumpAndSettle();
    }

    testWidgets('Windows save toast shows the full path and logs the outcome', (
      tester,
    ) async {
      addTearDown(resetItemImageSaveSeams);
      addTearDown(resetFileAccessSeams);
      itemImageEncoder = (_) async => Uint8List.fromList([1, 2, 3, 4]);
      fileSaveDialog = (_, _, _, _, _) async => r'C:\out\Char_造型A.png';
      final messages = <String>[];
      final sub = Logger.root.onRecord
          .where((r) => r.loggerName == 'gacha.itemimage.save')
          .listen((r) => messages.add(r.message));
      addTearDown(sub.cancel);
      await seedCharacterWithSkin(tester);
      await runMenuAction(tester, '儲存圖片');
      final l = AppLocalizations.of(
        tester.element(find.byType(GachaItemDetailDialog)),
      )!;
      expect(
        find.text(l.itemImageSavedTo(r'C:\out\Char_造型A.png')),
        findsOneWidget,
      );
      expect(messages, ['item image action=save name=Char_造型A.png outcome=ok']);
      await flushToast(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Android save toast shows only the file name', (tester) async {
      addTearDown(resetItemImageSaveSeams);
      addTearDown(resetFileAccessSeams);
      itemImageEncoder = (_) async => Uint8List.fromList([1, 2, 3, 4]);
      fileSaveDialog = (_, _, _, _, _) async =>
          '/document/primary:Download/Char_造型A.png';
      await seedCharacterWithSkin(tester, android: true);
      await runMenuAction(tester, '儲存圖片');
      final l = AppLocalizations.of(
        tester.element(find.byType(GachaItemDetailDialog)),
      )!;
      expect(find.text(l.itemImageSavedTo('Char_造型A.png')), findsOneWidget);
      await flushToast(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('sharing successfully shows no toast', (tester) async {
      addTearDown(resetItemImageSaveSeams);
      addTearDown(resetFileAccessSeams);
      itemImageEncoder = (_) async => Uint8List.fromList([1, 2, 3, 4]);
      fileSharer = (_, _, _) async {};
      await seedCharacterWithSkin(tester, android: true);
      await runMenuAction(tester, '分享');
      expect(find.byKey(const ValueKey('dialogToast')), findsNothing);
    });

    testWidgets('點重抓圖片 → 造型圖切回 loading（spinner 出現）', (tester) async {
      // 用永不解析的 fetcher，重抓後 loading 狀態維持不動，spinner 才穩定可觀察
      // （真實 fetcher 在 fake test 下 HTTP 回 400 → null → 瞬間轉 failed）。
      final illustFile = await seedCharacterWithSkin(
        tester,
        fetcher: _HangingFetcher(),
      );
      await pumpDialog(
        tester,
        _rec(resourceId: 111, name: 'Char', languageCode: 'zh-Hant'),
      );
      expect(find.byKey(ValueKey(illustFile.path)), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byType(GachaItemDetailDialog),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tester.pump();
      // 等 PopupMenu 開場動畫（約 300ms）完整跑完，選單項才完全可命中。
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('重抓圖片'));
      // 等 PopupMenu route 退場動畫結束，dialog 重建為 loading 狀態的 spinner。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(ValueKey(illustFile.path)), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('icon 重抓成功 → cache revision++、標題縮圖換 key', (tester) async {
      const iconUrl = 'https://cdn.example.com/w_icon.png';
      late File iconFile;
      await tester.runAsync(() async {
        await container
            .read(itemImageIndexProvider.notifier)
            .mergeIcon(
              resourceId: 77,
              iconUrl: iconUrl,
              noImage: false,
              permanentNoImage: false,
            );
        iconFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 77,
          url: iconUrl,
        );
        await _touchFile(tempDir, iconFile.uri.pathSegments.last);
      });
      rebuildContainer();
      await tester.runAsync(loadIndex);

      await pumpDialog(
        tester,
        _rec(
          resourceId: 77,
          name: 'WeaponX',
          resourceType: '武器',
          languageCode: 'zh-Hant',
        ),
      );

      // 初始 revision 0：標題縮圖 key 帶 #0。
      expect(find.byKey(ValueKey('${iconFile.path}#0')), findsOneWidget);

      // 直接 bump revision（不實際跑網路），驗證標題縮圖換 key 重建。
      container.read(itemImageCacheRevisionProvider.notifier).bump();
      await tester.pump();

      expect(find.byKey(ValueKey('${iconFile.path}#1')), findsOneWidget);
    });

    testWidgets('重抓 luckdraw → 以 force: true 強制重新擷取（不短路回舊檔）', (tester) async {
      // 角色含喚取立繪、且 luckdraw 快取檔已存在（chip 為 ready、顯示選單）。
      // kind 須設為 character，luckdraw chip 才會出現（itemTypeKeyOf 否則 fallback
      // 回 resourceType 字串、不等於 kItemKindCharacter）。
      const iconUrl = 'https://cdn.example.com/c_icon.png';
      late File luckdrawFile;
      await tester.runAsync(() async {
        final n = container.read(itemImageIndexProvider.notifier);
        await n.mergeIcon(
          resourceId: 1211,
          iconUrl: iconUrl,
          noImage: false,
          permanentNoImage: false,
          kind: kItemKindCharacter,
        );
        await n.mergeItemDetail(
          resourceId: 1211,
          lang: 'zh-Hant',
          detail: const ItemDetailL10n(
            intro: '',
            elementName: '',
            weaponTypeName: '',
            skins: [],
          ),
          hasLuckdraw: true,
        );
        // 同時建立 icon 快取檔 → 形成「喚取 + 圖示」兩個 chip（喚取排第一、預設選中），
        // 使 dialog 高度與選單幾何與其他重抓測試一致、選單項可穩定點擊。
        final iconFile = itemIconCacheFile(
          baseDir: tempDir,
          resourceId: 1211,
          url: iconUrl,
        );
        await _touchFile(tempDir, iconFile.uri.pathSegments.last);
        luckdrawFile = itemLuckdrawCacheFile(
          baseDir: tempDir,
          resourceId: 1211,
        );
        await _touchFile(tempDir, luckdrawFile.uri.pathSegments.last);
      });
      final recording = _RecordingCaptureService(tempDir, luckdrawFile);
      rebuildContainer(luckdraw: recording);
      await tester.runAsync(loadIndex);

      await pumpDialog(
        tester,
        _rec(
          resourceId: 1211,
          name: 'Char',
          resourceType: '角色',
          languageCode: 'zh-Hant',
        ),
      );

      // 確認顯示的是 ready 的 luckdraw 圖（選單可用）。
      expect(find.byKey(ValueKey(luckdrawFile.path)), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(GachaItemDetailDialog),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tester.pump();
      // 等 PopupMenu 開場動畫（約 300ms）完整跑完，選單項才完全可命中。
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('重抓圖片'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 重抓必須帶 force: true（否則服務短路回舊檔、disk 不變、畫面不變）。
      expect(recording.lastForce, isTrue);
    });
  });
}
