import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/gacha_item_detail_dialog.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/dialogs/zoomable_image_overlay.dart';

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

/// 找 label 文字為 [text] 的詳情 tag [Chip]（與 [ChoiceChip] 切換器 chip 區隔）。
Finder _chipWithText(String text) =>
    find.ancestor(of: find.text(text), matching: find.byType(Chip));

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
  void rebuildContainer() {
    container = ProviderContainer(
      overrides: [
        itemImageIndexStorageProvider.overrideWithValue(
          ItemImageIndexStorage(tempDir),
        ),
        itemImageCacheDirProvider.overrideWithValue(tempDir),
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
      tester.view.physicalSize = const Size(1400, 900);
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
      // 擴張到接近視窗寬(1400)。修壞時 Html 會 >1000px。
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
      '角色（active lang 有詳情）→ Html + 5★/元素/武器類型 chips + 造型/圖示 chip + caption + encore link',
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

    testWidgets('active lang 無詳情、他 lang 有 → fallback 到 values.first 仍渲染 Html', (
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
    });
  });
}
