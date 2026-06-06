import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/share_image_options.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/five_star_overview.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/gacha_item_icon.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/share/preloaded_item_images.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/share/share_card.dart';

Future<ui.Image> _solidImage() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 4, 4),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  return recorder.endRecording().toImage(4, 4);
}

void main() {
  testWidgets('banner 分享圖含 FiveStarOverview（含 5★ 時）', (tester) async {
    late Directory tempDir;
    await tester.runAsync(() async {
      tempDir = await Directory.systemTemp.createTemp('share_five_star_test_');
    });
    addTearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });
    final container = ProviderContainer(
      overrides: [
        itemImageIndexStorageProvider.overrideWithValue(
          ItemImageIndexStorage(tempDir),
        ),
        itemImageCacheDirProvider.overrideWithValue(tempDir),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(
      () => container.read(itemImageIndexProvider.notifier).waitForLoad(),
    );

    final icon = await tester.runAsync(_solidImage);
    addTearDown(() => icon!.dispose());

    final records = [
      GachaRecord(
        resourceId: 1001,
        qualityLevel: 5,
        resourceType: '角色',
        cardPoolType: '1',
        name: '夜蘭',
        count: 1,
        time: DateTime(2025, 4, 1),
      ),
    ];

    late AppLocalizations l;
    final card = Builder(
      builder: (ctx) {
        l = AppLocalizations.of(ctx)!;
        return ShareCard.banner(
          l: l,
          appVersion: '1.0.0',
          appIcon: icon!,
          options: const ShareImageOptions(
            brightness: Brightness.dark,
            showFullUid: true,
          ),
          uid: '100000001',
          updatedAt: DateTime(2025, 4, 1),
          title: 'Test',
          records: records,
          targetRank: 5,
          index: const ItemImageIndex.empty(),
        );
      },
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: PreloadedItemImages(images: const {}, child: card),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(FiveStarOverview), findsOneWidget);
    expect(find.text(l.rarityOverviewTitle(l.rarityStar(5))), findsOneWidget);
  });

  testWidgets('overview 分享圖：跨池 5★ 聚合於單段五星一覽（FiveStarOverview ×1）', (
    tester,
  ) async {
    late Directory tempDir;
    await tester.runAsync(() async {
      tempDir = await Directory.systemTemp.createTemp('share_five_star_ov_');
    });
    addTearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });
    final container = ProviderContainer(
      overrides: [
        itemImageIndexStorageProvider.overrideWithValue(
          ItemImageIndexStorage(tempDir),
        ),
        itemImageCacheDirProvider.overrideWithValue(tempDir),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(
      () => container.read(itemImageIndexProvider.notifier).waitForLoad(),
    );

    final icon = await tester.runAsync(_solidImage);
    addTearDown(() => icon!.dispose());

    // 兩個卡池各有一筆 5★（角色活動 '1'、新旅角色 '8'），聚合後同屬單一綜合段。
    final banners = {
      '1': [
        GachaRecord(
          resourceId: 1001,
          qualityLevel: 5,
          resourceType: '角色',
          cardPoolType: '1',
          name: '夜蘭',
          count: 1,
          time: DateTime(2025, 4, 1),
        ),
      ],
      '8': [
        GachaRecord(
          resourceId: 1008,
          qualityLevel: 5,
          resourceType: '角色',
          cardPoolType: '8',
          name: '新旅五星',
          count: 1,
          time: DateTime(2025, 4, 2),
        ),
      ],
    };

    late AppLocalizations l;
    final card = Builder(
      builder: (ctx) {
        l = AppLocalizations.of(ctx)!;
        return ShareCard.overview(
          l: l,
          appVersion: '1.0.0',
          appIcon: icon!,
          options: const ShareImageOptions(
            brightness: Brightness.dark,
            showFullUid: true,
          ),
          uid: '100000001',
          updatedAt: DateTime(2025, 4, 2),
          banners: banners,
          index: const ItemImageIndex.empty(),
        );
      },
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: PreloadedItemImages(images: const {}, child: card),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 綜合模式聚合單段 → 全部 5★ 收進唯一的五星一覽。
    expect(find.byType(FiveStarOverview), findsOneWidget);
    expect(find.text(l.rarityOverviewTitle(l.rarityStar(5))), findsOneWidget);

    // 跨池兩筆 5★（夜蘭、新旅五星）聚合為兩個 icon chip 於同一段五星一覽內。
    expect(
      find.descendant(
        of: find.byType(FiveStarOverview),
        matching: find.byType(GachaItemIcon),
      ),
      findsNWidgets(2),
    );
  });
}
