import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/banner_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/contributors_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/log_access_setup_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/overview_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/settings_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cancellable_http_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/gacha_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/adb_pairing.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/item_image_index.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/chart_card.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/pity_card.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/item_type_pie.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/rarity_pie.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/stat_card.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/five_star_overview.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/empty_state.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/gacha_item_icon.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/last_updated_label.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/page_header.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/share/share_action_button.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/cards/timeline_vertical.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/data/sortable_table.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/inline_section_title.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/data/pager.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/data/search_filter_bar.dart';

import '../helpers/no_game_dir.dart';

/// 空 [GachaCapture] 替身。
class _NullCapture implements GachaCapture {
  @override
  CaptureSession start() =>
      CaptureSession(result: Future.value(null), cancel: () async {});
}

/// 固定在 [phase] 的配對流程替身（讀取設定頁用）。
class _Ctl extends AdbPairingController {
  /// 建立替身。
  _Ctl(this.phase);

  /// 固定的階段。
  final PairingPhase phase;

  @override
  AdbPairingState build() => AdbPairingState(phase);
  @override
  Future<void> refresh() async {}
}

/// 角色活動池的測試紀錄：5★、4★、3★ 交錯，名稱刻意偏長。
List<GachaRecord> _records() => [
  for (var i = 0; i < 30; i++)
    GachaRecord(
      resourceId: 1000 + i,
      qualityLevel: i % 10 == 0 ? 5 : (i % 3 == 0 ? 4 : 3),
      resourceType: i % 2 == 0 ? '角色' : '武器',
      cardPoolType: '1',
      name: i % 10 == 0 ? 'Character With A Long Name $i' : 'Item $i',
      count: 1,
      time: DateTime(2026, 5, 1).subtract(Duration(hours: i)),
    ),
];

void main() {
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = await Directory.systemTemp.createTemp('phone_pages_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// 在 [size] 的畫面上呈現 [page]（已有一個帳號的紀錄，預設為 [_records]），回傳 container。
  Future<ProviderContainer> pump(
    WidgetTester tester,
    Size size,
    Widget page, {
    double keyboard = 0,
    PairingPhase phase = PairingPhase.disclosure,
    List<GachaRecord>? records,
    bool synced = true,
    Locale locale = const Locale('zh'),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
    late ProviderContainer container;
    await tester.runAsync(() async {
      final storage = GachaStorage(tempDir);
      if (synced) {
        await storage.save(
          BannerStorage(
            playerId: '701000000',
            languageCode: 'zh-Hant',
            lastUpdated: DateTime.utc(2026, 5, 1),
            banners: {'1': records ?? _records()},
          ),
        );
      }
      container = ProviderContainer(
        overrides: [
          noGameDirOverride,
          isAndroidProvider.overrideWithValue(true),
          wirelessPairingStatusProvider.overrideWith(
            (ref) async => (paired: true, canToggle: false),
          ),
          adbPairingProvider.overrideWith(() => _Ctl(phase)),
          gachaStorageProvider.overrideWithValue(storage),
          gachaCaptureProvider.overrideWithValue(_NullCapture()),
          cancellableHttpClientFactoryProvider.overrideWithValue(
            () => CancellableHttpClient(
              client: MockClient((_) async => http.Response('{}', 200)),
              cancel: () {},
            ),
          ),
          itemImageIndexStorageProvider.overrideWithValue(
            ItemImageIndexStorage(tempDir),
          ),
          itemImageCacheDirProvider.overrideWithValue(tempDir),
          appVersionProvider.overrideWithValue('0.0.0-test'),
        ],
      );
      await container.read(settingsProvider.notifier).waitForLoad();
      await container.read(gachaRepositoryProvider.notifier).waitForBootstrap();
    });
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: Scaffold(body: page),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return container;
  }

  /// 沒有例外；有的話把完整錯誤（含溢出元件的位置）放進失敗訊息。
  void expectNoException(WidgetTester tester) {
    final e = tester.takeException();
    expect(e, isNull, reason: e is FlutterError ? e.toStringDeep() : '$e');
  }

  /// 一路捲到底，途中任何 overflow 都算失敗。
  Future<void> scrollToEnd(WidgetTester tester) async {
    expectNoException(tester);
    final scrollables = find.byType(Scrollable);
    if (scrollables.evaluate().isEmpty) return;
    final main = scrollables.first;
    for (var i = 0; i < 40; i++) {
      final position = tester.state<ScrollableState>(main).position;
      if (position.pixels >= position.maxScrollExtent) break;
      await tester.drag(main, const Offset(0, -400), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 50));
      expectNoException(tester);
    }
  }

  for (final (name, size) in [
    ('portrait', const Size(360, 800)),
    ('landscape', const Size(800, 360)),
  ]) {
    testWidgets('overview page fits a phone ($name)', (tester) async {
      await pump(tester, size, const OverviewPage());
      await scrollToEnd(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('banner page fits a phone ($name)', (tester) async {
      await pump(tester, size, const BannerPage(cardPoolType: '1'));
      await scrollToEnd(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('settings page fits a phone ($name)', (tester) async {
      await pump(tester, size, const SettingsPage());
      await scrollToEnd(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('contributors page fits a phone ($name)', (tester) async {
      await pump(tester, size, const ContributorsPage());
      await scrollToEnd(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    for (final phase in [
      PairingPhase.disclosure,
      PairingPhase.ready,
      PairingPhase.grantFailed,
    ]) {
      testWidgets('log access setup page fits a phone ($name, ${phase.name})', (
        tester,
      ) async {
        await pump(tester, size, const LogAccessSetupPage(), phase: phase);
        await scrollToEnd(tester);
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    }
  }

  testWidgets('banner page with keyboard open does not overflow', (
    tester,
  ) async {
    await pump(
      tester,
      const Size(360, 800),
      const BannerPage(cardPoolType: '1'),
      keyboard: 300,
    );
    await scrollToEnd(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final (name, page) in [
    ('overview', const OverviewPage()),
    ('banner', const BannerPage(cardPoolType: '1')),
  ]) {
    testWidgets('$name header shows last updated in phone landscape', (
      tester,
    ) async {
      await pump(tester, const Size(800, 360), page);
      expect(find.byType(LastUpdatedLabel), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('$name landscape header: label after title, share at edge', (
      tester,
    ) async {
      await pump(tester, const Size(800, 360), page);
      final title = tester.getRect(
        find
            .descendant(
              of: find.byType(PageHeader),
              matching: find.byType(Text),
            )
            .first,
      );
      final label = tester.getRect(find.byType(LastUpdatedLabel));
      expect(label.left - title.right, inInclusiveRange(0, 16));
      expect(label.center.dy, inInclusiveRange(title.top, title.bottom));
      // 頁面左右內距 12：分享按鈕和直向一樣貼齊右緣。
      expect(tester.getRect(find.byType(ShareActionButton)).right, 800 - 12);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('$name header has no last updated in phone portrait', (
      tester,
    ) async {
      await pump(tester, const Size(360, 800), page);
      expect(find.byType(LastUpdatedLabel), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('$name unsynced landscape shows not-synced text and empty', (
      tester,
    ) async {
      await pump(tester, const Size(800, 360), page, synced: false);
      expect(find.text('尚未同步'), findsOneWidget);
      expect(find.byType(EmptyState), findsOneWidget);
      expectNoException(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('banner page padding is 12 on phones', (tester) async {
    await pump(
      tester,
      const Size(360, 800),
      const BannerPage(cardPoolType: '1'),
    );
    expect(tester.getTopLeft(find.byType(PityCard).first).dx, 12);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('banner page padding stays 16 on desktop', (tester) async {
    await pump(
      tester,
      const Size(1280, 800),
      const BannerPage(cardPoolType: '1'),
    );
    expect(tester.getTopLeft(find.byType(PityCard).first).dx, 16);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  testWidgets('overview builds bottom sections only when scrolled near', (
    tester,
  ) async {
    await pump(tester, const Size(360, 800), const OverviewPage());
    expect(find.byType(TimelineVertical, skipOffstage: false), findsNothing);
    await tester.scrollUntilVisible(
      find.byType(TimelineVertical),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byType(TimelineVertical), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('banner page builds the record table only when scrolled near', (
    tester,
  ) async {
    await pump(
      tester,
      const Size(360, 800),
      const BannerPage(cardPoolType: '1'),
    );
    expect(find.byType(SortableTable, skipOffstage: false), findsNothing);
    await tester.scrollUntilVisible(
      find.byType(SortableTable),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byType(SortableTable), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('overview keeps its three stat cards in one row on desktop', (
    tester,
  ) async {
    await pump(tester, const Size(1280, 800), const OverviewPage());
    expectNoException(tester);
    final tops = [
      for (final e in find.byType(StatCard).evaluate())
        tester.getTopLeft(find.byWidget(e.widget)).dy,
    ];
    expect(tops, hasLength(3));
    expect(tops.toSet(), hasLength(1));
    final heights = {
      for (final e in find.byType(StatCard).evaluate())
        tester.getSize(find.byWidget(e.widget)).height,
    };
    expect(heights, hasLength(1), reason: 'IntrinsicHeight keeps cards equal');
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  /// [finder] 第 [i] 個元件的左上角。
  Offset topLeftAt(WidgetTester tester, Finder finder, int i) =>
      tester.getTopLeft(finder.at(i));

  testWidgets('overview pairs the last two stat cards on a phone', (
    tester,
  ) async {
    await pump(tester, const Size(360, 800), const OverviewPage());
    expectNoException(tester);
    final cards = find.byType(StatCard);
    expect(cards, findsNWidgets(3));
    final a = topLeftAt(tester, cards, 1);
    final b = topLeftAt(tester, cards, 2);
    expect(a.dy, b.dy);
    expect(a.dx, isNot(b.dx));
    expect(topLeftAt(tester, cards, 0).dy, lessThan(a.dy));
    expect(
      tester.getSize(cards.at(1)).height,
      tester.getSize(cards.at(2)).height,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('banner page pairs secondary pity and total on a phone', (
    tester,
  ) async {
    await pump(
      tester,
      const Size(360, 800),
      const BannerPage(cardPoolType: '1'),
    );
    expectNoException(tester);
    final pity = find.byType(PityCard);
    final total = find.byType(StatCard);
    expect(pity, findsNWidgets(2));
    expect(
      topLeftAt(tester, pity, 0).dy,
      lessThan(topLeftAt(tester, pity, 1).dy),
    );
    expect(topLeftAt(tester, pity, 1).dy, topLeftAt(tester, total, 0).dy);
    expect(
      tester.getSize(pity.at(1)).height,
      tester.getSize(total.first).height,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('banner page shows three cards in a row in phone landscape', (
    tester,
  ) async {
    await pump(
      tester,
      const Size(800, 360),
      const BannerPage(cardPoolType: '1'),
    );
    expectNoException(tester);
    final pity = find.byType(PityCard);
    expect(pity, findsNWidgets(2));
    final dy = topLeftAt(tester, find.byType(StatCard), 0).dy;
    expect(topLeftAt(tester, pity, 0).dy, dy);
    expect(topLeftAt(tester, pity, 1).dy, dy);
    expect(
      find.descendant(of: pity, matching: find.byType(FractionallySizedBox)),
      findsNWidgets(2),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('banner page has one sort button, inside the filter bar', (
    tester,
  ) async {
    await pump(
      tester,
      const Size(360, 800),
      const BannerPage(cardPoolType: '1'),
    );
    await tester.scrollUntilVisible(
      find.byType(SortableTable),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byType(RecordSortButton), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SearchFilterBar),
        matching: find.byType(RecordSortButton),
      ),
      findsOneWidget,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('banner page shows record cards in phone landscape', (
    tester,
  ) async {
    await pump(
      tester,
      const Size(800, 360),
      const BannerPage(cardPoolType: '1'),
    );
    await tester.scrollUntilVisible(
      find.byType(SortableTable),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    final l = AppLocalizations.of(tester.element(find.byType(SortableTable)))!;
    expect(find.text(l.tableTotalIndex), findsNothing);
    expect(find.byType(RecordSortButton), findsOneWidget);
    expect(find.textContaining('#', findRichText: true), findsWidgets);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('changing the record page scrolls back to the list title', (
    tester,
  ) async {
    await pump(
      tester,
      const Size(360, 800),
      const BannerPage(cardPoolType: '1'),
      records: [
        for (var i = 0; i < 45; i++)
          GachaRecord(
            resourceId: 2000 + i,
            qualityLevel: 3,
            resourceType: '武器',
            cardPoolType: '1',
            name: 'Item $i',
            count: 1,
            time: DateTime(2026, 5, 1).subtract(Duration(hours: i)),
          ),
      ],
    );
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byType(Pager),
      100,
      scrollable: scrollable,
    );
    final l = AppLocalizations.of(tester.element(find.byType(Pager)))!;
    await tester.ensureVisible(find.byTooltip(l.actionNextPage));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l.actionNextPage));
    await tester.pumpAndSettle();
    final title = find.widgetWithText(
      InlineSectionTitle,
      l.pageBannerRecordList,
    );
    final top = tester.getTopLeft(scrollable).dy;
    expect(tester.getTopLeft(title).dy, closeTo(top, 8));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final locale in [const Locale('en'), const Locale('ja')]) {
    for (final (name, page) in [
      ('overview', const OverviewPage() as Widget),
      ('banner', const BannerPage(cardPoolType: '1')),
    ]) {
      testWidgets('$name at 1.3x text scale in $locale does not overflow', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pump(tester, const Size(360, 800), page, locale: locale);
        if (name == 'overview') {
          await scrollToEnd(tester);
        } else {
          expect(find.byType(PityCard), findsNWidgets(2));
          await tester.scrollUntilVisible(
            find.byType(ItemTypeChartCard),
            200,
            scrollable: find.byType(Scrollable).first,
          );
        }
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    }
  }

  /// 兩張圓餅卡目前的版面。
  List<ChartCardLayout> pieLayouts(WidgetTester tester) => [
    tester.widget<RarityChartCard>(find.byType(RarityChartCard)).layout,
    tester.widget<ItemTypeChartCard>(find.byType(ItemTypeChartCard)).layout,
  ];

  for (final (name, page) in [
    ('overview', const OverviewPage() as Widget),
    ('banner', const BannerPage(cardPoolType: '1')),
  ]) {
    testWidgets('$name pie cards are compact on a portrait phone', (
      tester,
    ) async {
      await pump(tester, const Size(360, 800), page);
      expectNoException(tester);
      expect(pieLayouts(tester), everyElement(ChartCardLayout.compact));
      expect(
        tester.getSize(find.byType(RarityChartCard)).height,
        lessThan(260),
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('$name pie cards sit side by side in phone landscape', (
      tester,
    ) async {
      await pump(tester, const Size(800, 360), page);
      expect(
        pieLayouts(tester),
        everyElement(ChartCardLayout.compactTitleBeside),
      );
      expect(
        tester.getTopLeft(find.byType(RarityChartCard)).dy,
        tester.getTopLeft(find.byType(ItemTypeChartCard)).dy,
      );
      expect(
        tester.getTopLeft(find.byType(ItemTypeChartCard)).dx,
        greaterThan(tester.getTopRight(find.byType(RarityChartCard)).dx),
      );
      await scrollToEnd(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('$name pie cards stay standard on desktop', (tester) async {
      await pump(tester, const Size(1280, 800), page);
      expect(pieLayouts(tester), everyElement(ChartCardLayout.standard));
      expect(tester.getSize(find.byType(RarityChartCard)).height, 380);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  testWidgets('banner page keeps pity and total cards in one row on desktop', (
    tester,
  ) async {
    await pump(
      tester,
      const Size(1280, 800),
      const BannerPage(cardPoolType: '1'),
    );
    expectNoException(tester);
    expect(
      tester.getTopLeft(find.byType(StatCard).first).dy,
      tester.getTopLeft(find.byType(PityCard).first).dy,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  testWidgets(
    'desktop builds the whole overview so the scrollbar stays stable',
    (tester) async {
      await pump(tester, const Size(1280, 800), const OverviewPage());
      expect(
        find.byType(TimelineVertical, skipOffstage: false),
        findsOneWidget,
      );
      expectNoException(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'desktop builds the whole banner page so the scrollbar stays stable',
    (tester) async {
      await pump(
        tester,
        const Size(1280, 400),
        const BannerPage(cardPoolType: '1'),
      );
      expect(find.byType(SortableTable, skipOffstage: false), findsOneWidget);
      expectNoException(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
  testWidgets('android tablets still build the overview on demand', (
    tester,
  ) async {
    await pump(tester, const Size(1280, 800), const OverviewPage());
    expect(find.byType(TimelineVertical, skipOffstage: false), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  testWidgets(
    'banner page keeps table and search state when the five-star section appears',
    (tester) async {
      List<GachaRecord> records({required bool withFiveStar}) => [
        for (var i = 0; i < 45; i++)
          GachaRecord(
            resourceId: 2000 + i,
            qualityLevel: withFiveStar && i == 44 ? 5 : (i % 3 == 0 ? 4 : 3),
            resourceType: '武器',
            cardPoolType: '1',
            name: 'Item $i',
            count: 1,
            time: DateTime(2026, 5, 1).subtract(Duration(hours: i)),
          ),
      ];
      final container = await pump(
        tester,
        const Size(360, 800),
        const BannerPage(cardPoolType: '1'),
        records: records(withFiveStar: false),
      );
      await tester.scrollUntilVisible(
        find.byType(Pager),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.byType(Pager));
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(Pager),
          matching: find.byIcon(Icons.chevron_right),
        ),
      );
      await tester.pump();
      expect(tester.widget<Pager>(find.byType(Pager)).page, 1);
      final searchBar = find.byType(SearchFilterBar, skipOffstage: false);
      final searchState = tester.state(searchBar);

      container
          .read(gachaRepositoryProvider.notifier)
          .debugSeedAccount(
            BannerStorage(
              playerId: '701000000',
              languageCode: 'zh-Hant',
              lastUpdated: DateTime.utc(2026, 5, 1),
              banners: {'1': records(withFiveStar: true)},
            ),
          );
      await tester.pump();

      final after = searchBar.evaluate();
      expect(after, hasLength(1), reason: 'search bar state was dropped');
      expect((after.single as StatefulElement).state, same(searchState));
      expect(tester.widget<Pager>(find.byType(Pager)).page, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  /// 200 個不同的五星（手機寬約 40 列），用來驗證五星一覽按列建構。
  List<GachaRecord> manyFiveStars() => [
    for (var i = 0; i < 200; i++)
      GachaRecord(
        resourceId: 3000 + i,
        qualityLevel: 5,
        resourceType: '角色',
        cardPoolType: '1',
        name: 'Star $i',
        count: 1,
        time: DateTime(2026, 5, 1).subtract(Duration(hours: i)),
      ),
  ];

  for (final (name, page) in [
    ('overview', const OverviewPage() as Widget),
    ('banner page', const BannerPage(cardPoolType: '1')),
  ]) {
    testWidgets('$name builds the five-star overview row by row', (
      tester,
    ) async {
      await pump(tester, const Size(360, 800), page, records: manyFiveStars());
      await tester.scrollUntilVisible(
        find.byIcon(Icons.star_outline),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      final chips = find.descendant(
        of: find.byType(SliverFiveStarOverview, skipOffstage: false),
        matching: find.byType(GachaItemIcon, skipOffstage: false),
      );
      expect(chips.evaluate(), isNotEmpty);
      expect(chips.evaluate().length, lessThan(200));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
