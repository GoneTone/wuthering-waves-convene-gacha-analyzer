import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/banner_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_filter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/ads.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/record_filter.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/ads/native_ad.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/chart_card.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/inline_section_title.dart';

/// 測試帳號。
const _uid = '701000000';

/// 卡池 [pool] 的 [count] 筆紀錄（名稱 `Item 1`..）；[withFive] 時每 10 筆有一筆 5★。
List<GachaRecord> _records(
  int count, {
  bool withFive = true,
  String pool = '1',
}) => [
  for (var i = 1; i <= count; i++)
    GachaRecord(
      resourceId: 1000 + i,
      qualityLevel: withFive && i % 10 == 0 ? 5 : 3,
      resourceType: '武器',
      cardPoolType: pool,
      name: 'Item $i',
      count: 1,
      time: DateTime(2026, 5, 1).subtract(Duration(hours: i)),
    ),
];

/// 狀態固定為 [banners] 的 repository 替身，不做 bootstrap 與 I/O。
class _Repo extends GachaRepository {
  /// 建立替身。
  _Repo(this.banners);

  /// 各卡池的紀錄。
  final Map<String, List<GachaRecord>> banners;

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
    isBootstrapping: false,
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
  _FakeAd(this.placement, this.brightness, this.key);

  /// 載入的位置。
  final NativeAdPlacement placement;

  /// 載入時的深淺色。
  final Brightness brightness;

  /// 假 view 的 key。
  final Key key;

  /// 是否已被 dispose。
  bool disposed = false;

  /// dispose 當下假 view 是否還掛在畫面上。
  bool disposedWhileMounted = false;
}

/// 記錄每次載入的假原生廣告載入器。
class _FakeLoader {
  /// 建立假載入器；[fail] 時一律回傳 null。
  _FakeLoader({this.fail = false});

  /// 是否模擬載入失敗。
  final bool fail;

  /// 每次載入的紀錄。
  final loads = <_FakeAd>[];

  /// [placement] 被載入的次數。
  int calls(NativeAdPlacement placement) =>
      loads.where((a) => a.placement == placement).length;

  /// 回傳帶唯一 key 的假廣告，或在 [fail] 時回傳 null。
  Future<LoadedNative?> call(
    NativeAdPlacement placement,
    Brightness brightness,
  ) async {
    final ad = _FakeAd(
      placement,
      brightness,
      ValueKey('native-${placement.name}-${loads.length}'),
    );
    loads.add(ad);
    if (fail) return null;
    return (
      view: SizedBox(key: ad.key),
      dispose: () {
        ad.disposed = true;
        ad.disposedWhileMounted = find.byKey(ad.key).evaluate().isNotEmpty;
      },
    );
  }
}

/// 畫面上任何一則假原生廣告的 view。
final _anyFakeView = find.byWidgetPredicate(
  (w) => w.key is ValueKey<String> && '${w.key}'.contains('native-'),
);

/// 目前顯示的 [placement] 假 view。
Finder _viewOf(NativeAdPlacement placement) => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      '${w.key}'.contains('native-${placement.name}-'),
);

/// 紀錄列表的卡片外框（圓角邊框的 Container）。
final _cardFrames = find.byWidgetPredicate(
  (w) =>
      w is Container &&
      w.decoration is BoxDecoration &&
      (w.decoration! as BoxDecoration).border != null &&
      (w.decoration! as BoxDecoration).borderRadius ==
          BorderRadius.circular(AppRadius.md),
);

/// 紀錄卡片（私有型別，以型別名稱比對）。
final _recordCards = find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == '_RecordCard',
  skipOffstage: false,
);

/// 時間軸那張卡。
final _timelineCard = find.byWidgetPredicate(
  (w) => w is ChartCard && w.icon == Icons.timeline,
);

/// 以 [icon] 找到的段落標題。
Finder _sectionTitle(IconData icon) =>
    find.byWidgetPredicate((w) => w is InlineSectionTitle && w.icon == icon);

void main() {
  late _FakeLoader loader;
  late ProviderContainer container;

  /// 建立 container：[banners] 為各卡池紀錄，[android]／[canRequestAds] 為廣告條件。
  void setUpContainer({
    required Map<String, List<GachaRecord>> banners,
    bool android = true,
    bool canRequestAds = true,
    bool fail = false,
  }) {
    loader = _FakeLoader(fail: fail);
    container = ProviderContainer(
      overrides: [
        gachaRepositoryProvider.overrideWith(() => _Repo(banners)),
        itemImageIndexProvider.overrideWith(_Index.new),
        itemImageCacheDirProvider.overrideWithValue(Directory.systemTemp),
        isAndroidProvider.overrideWithValue(android),
        adsProvider.overrideWith(() => _Ads(canRequestAds)),
        nativeAdLoaderProvider.overrideWithValue(loader.call),
      ],
    );
    addTearDown(container.dispose);
  }

  /// 以 [size] 與 [mode] 呈現卡池 [pool] 的頁面。
  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(360, 800),
    String pool = '1',
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
          home: Scaffold(body: BannerPage(cardPoolType: pool)),
        ),
      ),
    );
    await _settle(tester);
  }

  /// 第 10 與第 11 張紀錄卡是否在同一個外框裡（列表沒被切開）。
  void expectListNotSplit(WidgetTester tester) {
    final cards = _recordCards.evaluate().toList();
    expect(cards.length, greaterThan(10));
    Element frameOf(Element card) => find
        .ancestor(of: find.byWidget(card.widget), matching: _cardFrames)
        .evaluate()
        .first;
    expect(frameOf(cards[9]), same(frameOf(cards[10])));
  }

  /// 時間軸卡下緣到「5★ 一覽」標題上緣的距離（內容座標，途中會捲動）。
  Future<double> timelineToFiveStarGap(WidgetTester tester) async {
    final timelineBottom = _bottom(tester, _timelineCard);
    await _scrollTo(tester, _sectionTitle(Icons.star_outline));
    return _top(tester, _sectionTitle(Icons.star_outline)) - timelineBottom;
  }

  testWidgets('手機直向進頁即載入兩個位置，位置 3 在時間軸之下、5★ 一覽之上', (tester) async {
    setUpContainer(banners: {'1': _records(25)});
    await pumpPage(tester);
    expect(loader.calls(NativeAdPlacement.bannerList), 1);
    expect(loader.calls(NativeAdPlacement.bannerMid), 1);

    final timelineBottom = _bottom(tester, _timelineCard);
    final mid = _viewOf(NativeAdPlacement.bannerMid);
    await _scrollTo(tester, mid);
    expect(_top(tester, mid), greaterThanOrEqualTo(timelineBottom));
    final midBottom = _bottom(tester, mid);
    await _scrollTo(tester, _sectionTitle(Icons.star_outline));
    expect(
      _top(tester, _sectionTitle(Icons.star_outline)),
      greaterThanOrEqualTo(midBottom),
    );

    await _scrollTo(tester, _viewOf(NativeAdPlacement.bannerList));
    expect(_viewOf(NativeAdPlacement.bannerList), findsOneWidget);
  });

  testWidgets('沒有 5★ 時位置 3 照放，與「紀錄列表」標題至少隔 xl', (tester) async {
    setUpContainer(banners: {'1': _records(25, withFive: false)});
    await pumpPage(tester);
    final mid = _viewOf(NativeAdPlacement.bannerMid);
    await _scrollTo(tester, mid);
    final midBottom = _bottom(tester, mid);
    final title = _sectionTitle(Icons.table_chart_outlined);
    await _scrollTo(tester, title);
    expect(
      _top(tester, title) - midBottom,
      greaterThanOrEqualTo(AppSpacing.xl),
    );

    // 「同畫面最多一則」的佐證：位置 3 下緣到位置 1 上緣的距離。
    final list = _viewOf(NativeAdPlacement.bannerList);
    await _scrollTo(tester, list);
    final gap = _top(tester, list) - midBottom;
    expect(gap, greaterThan(0));
  });

  testWidgets('只有 8 筆時不載入位置 1，仍載入位置 3', (tester) async {
    setUpContainer(banners: {'1': _records(8)});
    await pumpPage(tester);
    expect(loader.calls(NativeAdPlacement.bannerList), 0);
    expect(loader.calls(NativeAdPlacement.bannerMid), 1);
  });

  testWidgets('平板寬（表格模式）不載入位置 1', (tester) async {
    setUpContainer(banners: {'1': _records(25)});
    await pumpPage(tester, size: const Size(1000, 800));
    expect(loader.calls(NativeAdPlacement.bannerList), 0);
    expect(loader.calls(NativeAdPlacement.bannerMid), 1);
  });

  testWidgets('內容寬度不足 320 時兩個都不載入、不多間距', (tester) async {
    setUpContainer(banners: {'1': _records(25)});
    // 手機頁邊距 m：340 − 24 = 316。
    await pumpPage(tester, size: const Size(340, 800));
    expect(loader.loads, isEmpty);
    expect(await timelineToFiveStarGap(tester), AppSpacing.xl);
    await _scrollTo(tester, _recordCards.at(10));
    expectListNotSplit(tester);
  });

  for (final (name, android, canRequestAds) in [
    ('非 Android', false, true),
    ('尚未可請求廣告', true, false),
  ]) {
    testWidgets('$name時兩個都不載入，版面與沒有廣告時相同', (tester) async {
      setUpContainer(
        banners: {'1': _records(25)},
        android: android,
        canRequestAds: canRequestAds,
      );
      await pumpPage(tester);
      expect(loader.loads, isEmpty);
      expect(_anyFakeView, findsNothing);
      expect(await timelineToFiveStarGap(tester), AppSpacing.xl);
      await _scrollTo(tester, _recordCards.at(10));
      expectListNotSplit(tester);
    });
  }

  testWidgets('卡池沒有紀錄時兩個都不載入', (tester) async {
    setUpContainer(banners: {'1': const []});
    await pumpPage(tester);
    expect(loader.loads, isEmpty);
    expect(_anyFakeView, findsNothing);
  });

  testWidgets('載入失敗時不顯示、不插入間距', (tester) async {
    setUpContainer(banners: {'1': _records(25)}, fail: true);
    await pumpPage(tester);
    expect(loader.calls(NativeAdPlacement.bannerList), 1);
    expect(loader.calls(NativeAdPlacement.bannerMid), 1);
    expect(_anyFakeView, findsNothing);
    expect(await timelineToFiveStarGap(tester), AppSpacing.xl);
    await _scrollTo(tester, _recordCards.at(10));
    expectListNotSplit(tester);
  });

  testWidgets('翻到第 2 頁不再載入', (tester) async {
    setUpContainer(banners: {'1': _records(25)});
    await pumpPage(tester);
    await _scrollTo(tester, find.byIcon(Icons.chevron_right));
    await tester.tap(find.byIcon(Icons.chevron_right));
    await _settle(tester);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(loader.loads.length, 2);
    expect(loader.loads.where((a) => a.disposed), isEmpty);
  });

  testWidgets('深色切淺色：兩個位置以 light 各再載入一次，舊廣告離開畫面後才釋放', (tester) async {
    setUpContainer(banners: {'1': _records(25)});
    await pumpPage(tester);
    final old = [...loader.loads];
    expect(old.map((a) => a.brightness), everyElement(Brightness.dark));

    await pumpPage(tester, mode: ThemeMode.light);
    // 舊廣告在 provider 釋放後的下一幀才 dispose。
    await tester.pump();
    final fresh = loader.loads.skip(old.length).toList();
    expect(
      fresh.map((a) => (a.placement, a.brightness)),
      unorderedEquals([
        (NativeAdPlacement.bannerList, Brightness.light),
        (NativeAdPlacement.bannerMid, Brightness.light),
      ]),
    );
    for (final ad in old) {
      expect(ad.disposed, isTrue, reason: '${ad.placement}');
      expect(ad.disposedWhileMounted, isFalse, reason: '${ad.placement}');
    }
  });

  testWidgets('切到另一個卡池：舊卡池的廣告釋放，新卡池依自己的條件載入', (tester) async {
    setUpContainer(
      banners: {
        '1': _records(25),
        '2': _records(8, pool: '2'),
      },
    );
    await pumpPage(tester);
    final old = [...loader.loads];
    expect(old.length, 2);

    await pumpPage(tester, pool: '2');
    expect(loader.calls(NativeAdPlacement.bannerList), 1);
    expect(loader.calls(NativeAdPlacement.bannerMid), 2);
    for (final ad in old) {
      expect(ad.disposed, isTrue, reason: '${ad.placement}');
      expect(ad.disposedWhileMounted, isFalse, reason: '${ad.placement}');
    }
  });

  testWidgets('篩選到 10 筆以下不載入位置 1；清掉後補載一次；再篩回去不釋放、不顯示', (tester) async {
    setUpContainer(banners: {'1': _records(25)});
    final filter = container.read(recordFilterProvider('1').notifier);
    // 「Item 2」只符合 Item 2、20..25，共 7 筆。
    filter.setFilter(const RecordFilter(query: 'Item 2'));
    await pumpPage(tester);
    expect(loader.calls(NativeAdPlacement.bannerList), 0);
    expect(loader.calls(NativeAdPlacement.bannerMid), 1);

    filter.clear();
    await _settle(tester);
    expect(loader.calls(NativeAdPlacement.bannerList), 1);

    filter.setFilter(const RecordFilter(query: 'Item 2'));
    await _settle(tester);
    expect(loader.calls(NativeAdPlacement.bannerList), 1);
    expect(loader.calls(NativeAdPlacement.bannerMid), 1);
    expect(loader.loads.where((a) => a.disposed), isEmpty);
    expect(_viewOf(NativeAdPlacement.bannerList), findsNothing);
  });
}

/// 推進到動畫（換頁、主題切換）結束；頁面有持續動畫，不能用 pumpAndSettle。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 捲到 [finder] 可見。
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await _settle(tester);
}

/// 主捲動區目前的捲動位移。
double _pixels(WidgetTester tester) => tester
    .state<ScrollableState>(find.byType(Scrollable).first)
    .position
    .pixels;

/// [finder] 上緣在捲動內容中的位置（不受捲動影響）。
double _top(WidgetTester tester, Finder finder) =>
    tester.getTopLeft(finder).dy + _pixels(tester);

/// [finder] 下緣在捲動內容中的位置（不受捲動影響）。
double _bottom(WidgetTester tester, Finder finder) =>
    tester.getBottomLeft(finder).dy + _pixels(tester);
