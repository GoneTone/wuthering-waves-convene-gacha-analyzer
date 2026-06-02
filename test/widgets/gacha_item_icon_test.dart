import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/gacha_item_icon.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/share/preloaded_item_images.dart';

GachaRecord _rec({
  required int resourceId,
  required String name,
  int qualityLevel = 5,
  String resourceType = '角色',
}) => GachaRecord(
  resourceId: resourceId,
  qualityLevel: qualityLevel,
  resourceType: resourceType,
  cardPoolType: '1',
  name: name,
  count: 1,
  time: DateTime(2026, 5, 23),
);

Widget _wrap(Widget child, ProviderContainer container) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(body: child),
      ),
    );

void main() {
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gacha_item_icon_test_');
    container = ProviderContainer(
      overrides: [
        itemImageIndexStorageProvider.overrideWithValue(
          ItemImageIndexStorage(tempDir),
        ),
        itemImageCacheDirProvider.overrideWithValue(tempDir),
      ],
    );
    addTearDown(container.dispose);
    await container.read(itemImageIndexProvider.notifier).waitForLoad();
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

  testWidgets('空 index → placeholder（武器/道具亦同）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        GachaItemIcon(
          record: _rec(resourceId: 111, name: 'SomeWeapon', resourceType: '武器'),
          size: 20,
        ),
        container,
      ),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.byType(GachaItemIcon), findsOneWidget);
    final size = tester.getSize(find.byType(GachaItemIcon));
    expect(size.width, 20);
    expect(size.height, 20);
  });

  testWidgets('有 entry 但 cache 檔不存在 → placeholder', (tester) async {
    await tester.runAsync(() async {
      await container
          .read(itemImageIndexProvider.notifier)
          .mergeIcon(
            resourceId: 111,
            iconUrl: 'https://x/icon.png',
            noImage: false,
            permanentNoImage: false,
          );
    });
    await tester.pumpWidget(
      _wrap(
        GachaItemIcon(record: _rec(resourceId: 111, name: 'Hu Tao'), size: 20),
        container,
      ),
    );
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('完整 chain（index + cache 檔在）→ 顯示 Image', (tester) async {
    const iconUrl = 'https://x/icon.png';
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
      await cacheFile.writeAsBytes(_minimalPng());
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _wrap(
          GachaItemIcon(
            record: _rec(resourceId: 111, name: 'Hu Tao'),
            size: 20,
          ),
          container,
        ),
      );
      await tester.pump();
    });
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('PreloadedItemImages 命中 → 顯示 RawImage', (tester) async {
    await tester.runAsync(() async {
      await container
          .read(itemImageIndexProvider.notifier)
          .mergeIcon(
            resourceId: 111,
            iconUrl: 'https://x/icon.png',
            noImage: false,
            permanentNoImage: false,
          );

      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 1, 1),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      final img = await recorder.endRecording().toImage(1, 1);
      addTearDown(img.dispose);

      await tester.pumpWidget(
        _wrap(
          PreloadedItemImages(
            images: {111: img},
            child: GachaItemIcon(
              record: _rec(resourceId: 111, name: 'Hu Tao'),
              size: 20,
            ),
          ),
          container,
        ),
      );
      await tester.pump();

      expect(find.byType(RawImage), findsOneWidget);
      expect(
        find.byType(Image),
        findsNothing,
        reason: 'preloaded 命中應該用 RawImage 而非 Image.file',
      );
    });
  });

  testWidgets('placeholder 應顯示 Icons.question_mark 且 size = host * 0.55', (
    tester,
  ) async {
    for (final rank in [3, 4, 5]) {
      await tester.pumpWidget(
        _wrap(
          GachaItemIcon(
            record: _rec(
              resourceId: rank,
              name: 'Missing $rank',
              qualityLevel: rank,
            ),
            size: 32,
          ),
          container,
        ),
      );
      final iconFinder = find.byIcon(Icons.question_mark);
      expect(
        iconFinder,
        findsOneWidget,
        reason: 'rank=$rank placeholder 應含 question_mark',
      );
      final icon = tester.widget<Icon>(iconFinder);
      expect(icon.size, 32 * 0.55, reason: 'rank=$rank icon size');
    }
  });

  testWidgets('circular=true → placeholder 用圓形 BoxShape.circle', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        GachaItemIcon(
          record: _rec(resourceId: 1001, name: '夜蘭', qualityLevel: 5),
          size: 48,
          circular: true,
        ),
        container,
      ),
    );
    await tester.pump();

    final deco =
        tester
                .widget<Container>(
                  find.descendant(
                    of: find.byType(GachaItemIcon),
                    matching: find.byType(Container),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(deco.shape, BoxShape.circle);
  });

  testWidgets('circular=false（預設）→ placeholder 用方形 BoxShape.rectangle', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        GachaItemIcon(
          record: _rec(resourceId: 1001, name: '夜蘭', qualityLevel: 5),
          size: 48,
        ),
        container,
      ),
    );
    await tester.pump();

    final deco =
        tester
                .widget<Container>(
                  find.descendant(
                    of: find.byType(GachaItemIcon),
                    matching: find.byType(Container),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(deco.shape, BoxShape.rectangle);
  });
}

/// 最小可解碼 1x1 透明 PNG。
List<int> _minimalPng() => const [
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9c,
  0x62,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0d,
  0x0a,
  0x2d,
  0xb4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
];
