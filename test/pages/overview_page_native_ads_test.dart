import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/overview_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/ads.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/ads/native_ad.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/chart_card.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/item_type_pie.dart';

/// 測試帳號。
const _uid = '701000000';

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

/// 狀態固定的 repository 替身，不做 bootstrap 與 I/O。
class _Repo extends GachaRepository {
  /// 建立替身；[bootstrapping] 時維持啟動載入中。
  _Repo(this.banners, {this.bootstrapping = false});

  /// 各卡池的紀錄。
  final Map<String, List<GachaRecord>> banners;

  /// 是否維持啟動載入中。
  final bool bootstrapping;

  @override
  GachaState build() => GachaState(
    activeUid: _uid,
    byUid: {
      _uid: BannerStorage(
        playerId: _uid,
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.utc(2026, 5, 1),
        banners: banners,
      ),
    },
    isBootstrapping: bootstrapping,
  );
}

/// 固定為空 index、不讀磁碟的圖片索引替身。
class _Index extends ItemImageIndexNotifier {
  @override
  ItemImageIndex build() => const ItemImageIndex.empty();
}

/// 狀態固定、不碰原生 SDK 的廣告控制器替身。
class _Ads extends AdsController {
  /// 建立替身。
  _Ads(this.canRequestAds);

  /// 固定的「可請求廣告」旗標。
  final bool canRequestAds;

  @override
  AdsState build() => AdsState(canRequestAds: canRequestAds);
}

/// 一則假原生廣告的載入紀錄。
class _FakeAd {
  /// 建立紀錄。
  _FakeAd(this.brightness, this.key);

  /// 載入時的深淺色。
  final Brightness brightness;

  /// 假 view 的 key。
  final Key key;

  /// 是否已被 dispose。
  bool disposed = false;

  /// dispose 當下假 view 是否還掛在畫面上。
  bool disposedWhileMounted = false;

  /// 是否在某一幀的 post-frame 階段才 dispose。
  bool disposedAfterFrame = false;
}

/// 記錄每次載入的假原生廣告載入器。
class _FakeLoader {
  /// 建立假載入器；[fail] 時一律回傳 null。
  _FakeLoader({this.fail = false});

  /// 是否模擬載入失敗。
  final bool fail;

  /// 每次載入的紀錄。
  final loads = <_FakeAd>[];

  /// 回傳帶唯一 key 的假廣告，或在 [fail] 時回傳 null。
  Future<LoadedNative?> call(
    NativeAdPlacement placement,
    Brightness brightness,
  ) async {
    expect(placement, NativeAdPlacement.overview);
    final ad = _FakeAd(brightness, ValueKey('native-${loads.length}'));
    loads.add(ad);
    if (fail) return null;
    return (
      view: SizedBox(key: ad.key, height: 100),
      dispose: () {
        ad.disposed = true;
        ad.disposedWhileMounted = find.byKey(ad.key).evaluate().isNotEmpty;
        ad.disposedAfterFrame =
            SchedulerBinding.instance.schedulerPhase ==
            SchedulerPhase.postFrameCallbacks;
      },
    );
  }
}

/// 畫面上的假原生廣告 view。
final _fakeView = find.byWidgetPredicate(
  (w) => w.key is ValueKey<String> && '${w.key}'.contains('native-'),
);

/// 「類型分布」卡。
final _typeCard = find.byType(ItemTypeChartCard);

/// 「各卡池最高稀有度件數」卡。
final _barsCard = find.byWidgetPredicate(
  (w) => w is ChartCard && w.icon == Icons.bar_chart,
);

void main() {
  late _FakeLoader loader;
  late ProviderContainer container;

  /// 建立 container：[android]／[canRequestAds] 為廣告條件，[banners] 為紀錄。
  void setUpContainer({
    Map<String, List<GachaRecord>>? banners,
    bool android = true,
    bool canRequestAds = true,
    bool fail = false,
    bool bootstrapping = false,
  }) {
    loader = _FakeLoader(fail: fail);
    container = ProviderContainer(
      overrides: [
        gachaRepositoryProvider.overrideWith(
          () => _Repo(
            banners ?? {'1': _records(25)},
            bootstrapping: bootstrapping,
          ),
        ),
        itemImageIndexProvider.overrideWith(_Index.new),
        itemImageCacheDirProvider.overrideWithValue(Directory.systemTemp),
        isAndroidProvider.overrideWithValue(android),
        adsProvider.overrideWith(() => _Ads(canRequestAds)),
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
    expect(loader.loads.length, 1);
    final block = find.byType(NativeAdBlock);
    expect(_fakeView, findsOneWidget);
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
      expect(_fakeView, findsNothing);
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
    expect(loader.loads.length, 1);
    expect(_fakeView, findsNothing);
    expect(typeToBarsGap(tester), AppSpacing.m);
  });

  testWidgets('深色切淺色：以 light 再載入一次，舊的離開畫面後才釋放', (tester) async {
    setUpContainer();
    await pumpPage(tester);
    final old = loader.loads.single;
    expect(old.brightness, Brightness.dark);

    await pumpPage(tester, mode: ThemeMode.light);
    await tester.pump();
    expect(loader.loads.length, 2);
    expect(loader.loads.last.brightness, Brightness.light);
    expect(old.disposed, isTrue);
    expect(old.disposedWhileMounted, isFalse);
    expect(old.disposedAfterFrame, isTrue);
  });
}
