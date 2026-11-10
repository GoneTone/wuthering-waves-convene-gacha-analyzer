import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/overview_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/ads.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/ads/native_ad.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/chart_card.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/item_type_pie.dart';

import '../helpers/native_ad_fakes.dart';

/// 卡池 1 的 [count] 筆紀錄。
List<GachaRecord> _records(int count) => [
  for (var i = 1; i <= count; i++)
    GachaRecord(
      resourceId: 1000 + i,
      qualityLevel: i % 10 == 0 ? 5 : 3,
      resourceType: '武器',
      cardPoolType: '1',
      name: 'Item $i',
      count: 1,
      time: DateTime(2026, 5, 1).subtract(Duration(hours: i)),
    ),
];

/// 「類型分布」卡。
final _typeCard = find.byType(ItemTypeChartCard);

/// 「各卡池最高稀有度件數」卡。
final _barsCard = find.byWidgetPredicate(
  (w) => w is ChartCard && w.icon == Icons.bar_chart,
);

void main() {
  late FakeNativeAdLoader loader;
  late ProviderContainer container;

  /// 建立 container：[android]／[canRequestAds] 為廣告條件，[banners] 為紀錄。
  void setUpContainer({
    Map<String, List<GachaRecord>>? banners,
    bool android = true,
    bool canRequestAds = true,
    bool fail = false,
    bool bootstrapping = false,
  }) {
    loader = FakeNativeAdLoader(fail: fail);
    container = ProviderContainer(
      overrides: [
        gachaRepositoryProvider.overrideWith(
          () => FixedGachaRepository(
            banners ?? {'1': _records(25)},
            bootstrapping: bootstrapping,
          ),
        ),
        itemImageIndexProvider.overrideWith(EmptyItemImageIndex.new),
        itemImageCacheDirProvider.overrideWithValue(Directory.systemTemp),
        isAndroidProvider.overrideWithValue(android),
        adsProvider.overrideWith(() => FakeAdsController(canRequestAds)),
        nativeAdLoaderProvider.overrideWithValue(loader.call),
      ],
    );
    addTearDown(container.dispose);
  }

  /// 以 [size] 與 [mode] 呈現總覽頁。
  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(360, 2400),
    ThemeMode mode = ThemeMode.dark,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: mode,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: const Scaffold(body: OverviewPage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 「類型分布」卡下緣到「各卡池最高稀有度件數」卡上緣的距離。
  double typeToBarsGap(WidgetTester tester) =>
      tester.getTopLeft(_barsCard).dy - tester.getBottomLeft(_typeCard).dy;

  testWidgets('有紀錄時進頁載入一次，廣告夾在兩張卡之間、前後間距都是 m', (tester) async {
    setUpContainer();
    await pumpPage(tester);
    expect(loader.calls(NativeAdPlacement.overview), 1);
    final block = find.byType(NativeAdBlock);
    expect(anyFakeNativeView, findsOneWidget);
    expect(
      tester.getTopLeft(block).dy - tester.getBottomLeft(_typeCard).dy,
      AppSpacing.m,
    );
    expect(
      tester.getTopLeft(_barsCard).dy - tester.getBottomLeft(block).dy,
      AppSpacing.m,
    );
  });

  for (final (name, android, canRequestAds, bootstrapping, noRecords) in [
    ('非 Android', false, true, false, false),
    ('尚未可請求廣告', true, false, false, false),
    ('沒有任何紀錄', true, true, false, true),
    ('啟動載入中', true, true, true, false),
  ]) {
    testWidgets('$name時不載入，版面與沒有廣告時相同', (tester) async {
      setUpContainer(
        android: android,
        canRequestAds: canRequestAds,
        bootstrapping: bootstrapping,
        banners: noRecords ? {'1': const []} : null,
      );
      await pumpPage(tester);
      expect(loader.loads, isEmpty);
      expect(anyFakeNativeView, findsNothing);
      if (!noRecords && !bootstrapping) {
        expect(typeToBarsGap(tester), AppSpacing.m);
      }
    });
  }

  testWidgets('內容寬度不足 320 時不載入、不多間距', (tester) async {
    setUpContainer();
    // 手機頁邊距 m：340 − 24 = 316。
    await pumpPage(tester, size: const Size(340, 2400));
    expect(loader.loads, isEmpty);
    expect(typeToBarsGap(tester), AppSpacing.m);
  });

  testWidgets('載入失敗時不顯示、不多間距', (tester) async {
    setUpContainer(fail: true);
    await pumpPage(tester);
    expect(loader.calls(NativeAdPlacement.overview), 1);
    expect(anyFakeNativeView, findsNothing);
    expect(typeToBarsGap(tester), AppSpacing.m);
  });

  testWidgets('深色切淺色：以 light 再載入一次，舊的離開畫面後才釋放', (tester) async {
    setUpContainer();
    await pumpPage(tester);
    final old = loader.loads.single;
    expect(old.brightness, Brightness.dark);

    await pumpPage(tester, mode: ThemeMode.light);
    await tester.pump();
    expect(loader.calls(NativeAdPlacement.overview), 2);
    expect(loader.loads.last.brightness, Brightness.light);
    expect(old.disposed, isTrue);
    expect(old.disposedWhileMounted, isFalse);
    expect(old.disposedAfterFrame, isTrue);
  });
}
