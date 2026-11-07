import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/data/gacha_types.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/data/team_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/app_shell.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/app_release.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/cloud_sync.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/play_update_download.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/last_updated_label.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/team_links_bar.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/uid_indicator.dart';

import '../helpers/fake_url_launcher.dart';

/// 已有一個帳號、記錄 update 呼叫次數的 repository 替身。
class _Repo extends GachaRepository {
  /// update 被呼叫的次數。
  int updates = 0;

  @override
  GachaState build() => GachaState(
    activeUid: '701000000',
    byUid: {
      '701000000': BannerStorage(
        playerId: '701000000',
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.now().toUtc(),
        banners: const {},
      ),
    },
    isBootstrapping: false,
  );

  @override
  Future<void> update({bool afterPairing = false}) async => updates++;
}

/// 不發請求的版本檢查替身。
class _Release extends AppReleaseNotifier {
  @override
  Future<void> check({required bool manual}) async {}
}

/// 可手動切換階段、記錄 install 呼叫的下載替身。
class _Download extends PlayUpdateDownloadNotifier {
  /// install 被呼叫的次數。
  int installs = 0;

  /// 直接把狀態設為 [phase]。
  void setPhase(PlayDownloadPhase phase) => state = phase;

  @override
  Future<void> install() async => installs++;
}

/// 不啟動同步的雲端同步替身。
class _Sync extends CloudSyncNotifier {
  @override
  Future<void> start() async {}
}

void main() {
  late _Repo repo;
  late ProviderContainer container;
  late _Download download;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 以 [size] 開啟外殼；路由頁面只顯示 `page:<path>`。
  Future<AppLocalizations> pump(
    WidgetTester tester,
    Size size, {
    Locale locale = const Locale('zh'),
    double textScale = 1,
    String? alias,
    double keyboard = 0,
    Widget? body,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    repo = _Repo();
    download = _Download();
    container = ProviderContainer(
      overrides: [
        appVersionProvider.overrideWithValue('1.8.1'),
        gachaRepositoryProvider.overrideWith(() => repo),
        appReleaseProvider.overrideWith(_Release.new),
        cloudSyncProvider.overrideWith(_Sync.new),
        playUpdateDownloadProvider.overrideWith(() => download),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).waitForLoad();
    if (alias != null) {
      await container
          .read(settingsProvider.notifier)
          .setUidAlias('701000000', alias);
    }
    Widget page(GoRouterState s) => body ?? Text('page:${s.uri.path}');
    final router = GoRouter(
      routes: [
        ShellRoute(
          builder: (_, _, child) => AppShell(child: child),
          routes: [
            GoRoute(path: '/', builder: (_, s) => page(s)),
            GoRoute(path: '/banner/:type', builder: (_, s) => page(s)),
            GoRoute(path: '/contributors', builder: (_, s) => page(s)),
            GoRoute(path: '/settings', builder: (_, s) => page(s)),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: buildDarkTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.of(tester.element(find.byType(AppShell)))!;
  }

  /// 抽屜按鈕（Scaffold 自動加在 AppBar 左上）。
  Finder drawerButton(WidgetTester tester) => find.byTooltip(
    MaterialLocalizations.of(
      tester.element(find.byType(AppShell)),
    ).openAppDrawerTooltip,
  );

  testWidgets('downloaded update shows a persistent restart snackbar', (
    tester,
  ) async {
    final l = await pump(tester, const Size(360, 800));
    expect(find.text(l.updateDownloadedMessage), findsNothing);
    download.setPhase(PlayDownloadPhase.downloaded);
    await tester.pump();
    await tester.pump(const Duration(minutes: 5));
    expect(find.text(l.updateDownloadedMessage), findsOneWidget);
    await tester.tap(find.text(l.updateRestartAction));
    expect(download.installs, 1);
    final bar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(bar.persist, isTrue);
  });

  for (final (locale, scale) in const [
    (Locale('zh'), 1.0),
    (Locale('en'), 1.0),
    (Locale('ja'), 1.0),
    (Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'), 1.0),
    (Locale('en'), 1.3),
    (Locale('ja'), 1.3),
  ]) {
    testWidgets('in-app update failure offers Google Play; denial stays '
        'silent ($locale x$scale)', (tester) async {
      final launcher = installFakeUrlLauncher();
      final l = await pump(
        tester,
        const Size(320, 640),
        locale: locale,
        textScale: scale,
      );
      download.setPhase(PlayDownloadPhase.downloading);
      await tester.pump();
      download.setPhase(PlayDownloadPhase.idle);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);

      download.setPhase(PlayDownloadPhase.failed);
      await tester.pumpAndSettle();
      expect(find.text(l.updateInAppUnavailable), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(l.updateOpenPlayStore));
      await tester.pumpAndSettle();
      expect(launcher.launched, [
        'https://play.google.com/store/apps/details?id=tw.reh.wuwa.gacha',
      ]);
      expect(find.text(l.updateInAppUnavailable), findsNothing);
    });
  }

  testWidgets('phone portrait uses a drawer instead of the rail', (
    tester,
  ) async {
    final l = await pump(tester, const Size(360, 800));
    expect(drawerButton(tester), findsOneWidget);
    expect(find.text(l.navOverview), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('drawer lists the same destinations as the rail', (tester) async {
    final l = await pump(tester, const Size(360, 800));
    await tester.tap(drawerButton(tester));
    await tester.pumpAndSettle();
    for (final label in [
      l.navOverview,
      l.gachaTypeCharacterShort,
      l.gachaTypeReverbWeaponShort,
      l.navContributors,
      l.navSettings,
    ]) {
      final f = find.text(label);
      await tester.scrollUntilVisible(
        f,
        50,
        scrollable: find
            .descendant(
              of: find.byType(Drawer),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(f, findsOneWidget, reason: label);
      expect(
        tester
            .getSize(find.ancestor(of: f, matching: find.byType(InkWell)).first)
            .height,
        greaterThanOrEqualTo(48),
        reason: label,
      );
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('tapping a drawer item navigates and closes the drawer', (
    tester,
  ) async {
    final l = await pump(tester, const Size(360, 800));
    await tester.tap(drawerButton(tester));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.gachaTypeWeaponShort));
    await tester.pumpAndSettle();
    expect(find.text('page:/banner/${gachaTypes[1].key}'), findsOneWidget);
    expect(find.byType(Drawer), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('phone landscape also uses the drawer', (tester) async {
    await pump(tester, const Size(800, 360));
    expect(drawerButton(tester), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('desktop keeps the rail and the version', (tester) async {
    final l = await pump(tester, const Size(1280, 800));
    expect(drawerButton(tester), findsNothing);
    expect(find.text(l.navOverview), findsOneWidget);
    expect(find.textContaining('v1.8.1'), findsOneWidget);
    expect(find.text(TeamInfo.name), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  for (final (name, locale, scale) in [
    ('zh', const Locale('zh'), 1.0),
    ('en', const Locale('en'), 1.0),
    ('large text', const Locale('zh'), 1.3),
  ]) {
    testWidgets('phone title hides the version and never overflows ($name)', (
      tester,
    ) async {
      await pump(
        tester,
        const Size(360, 800),
        locale: locale,
        textScale: scale,
        alias: 'AVeryLongAccountAliasName',
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('v1.8.1'), findsNothing);
      expect(find.textContaining('701000000'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('phone update button is an icon with a tooltip', (tester) async {
    final l = await pump(tester, const Size(360, 800));
    final button = find.byTooltip(l.actionUpdate);
    expect(
      find.ancestor(of: button, matching: find.byType(IconButton)),
      findsOneWidget,
    );
    await tester.tap(button);
    await tester.pump();
    expect(repo.updates, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final (name, locale) in [('ja', Locale('ja')), ('en', Locale('en'))]) {
    testWidgets('account menu fits a phone and shows the full alias ($name)', (
      tester,
    ) async {
      await pump(
        tester,
        const Size(360, 800),
        locale: locale,
        textScale: 1.3,
        alias: 'MainAcct',
      );
      await tester.tap(find.byType(AccountTriggerButton));
      await tester.pumpAndSettle();
      final e = tester.takeException();
      expect(e, isNull, reason: e is FlutterError ? e.toStringDeep() : '$e');
      final menuAlias = tester.renderObject<RenderParagraph>(
        find.text('MainAcct').last,
      );
      expect(menuAlias.didExceedMaxLines, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('phone account button uses 12dp side padding', (tester) async {
    // 按鈕內距從 24 縮到 12，360dp 手機上 UID 才放得下。
    await pump(tester, const Size(360, 800));
    final button = tester.widget<OutlinedButton>(
      find.descendant(
        of: find.byType(AccountTriggerButton),
        matching: find.byType(OutlinedButton),
      ),
    );
    final padding = button.style!.padding!.resolve({});
    expect(padding, const EdgeInsets.symmetric(horizontal: 12));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('phone landscape with the keyboard open hides the footer', (
    tester,
  ) async {
    // 橫向手機開鍵盤後只剩約 50dp，固定的底部狀態列會把畫面擠到溢出。
    await pump(tester, const Size(800, 360), keyboard: 250);
    final e = tester.takeException();
    expect(e, isNull, reason: e is FlutterError ? e.toStringDeep() : '$e');
    expect(find.byType(TeamLinksBar), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('phone footer is 48dp tall', (tester) async {
    await pump(tester, const Size(360, 800));
    expect(
      tester.getSize(find.byKey(const Key('shell-bottom-bar'))).height,
      48,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('phone portrait footer keeps only last updated', (tester) async {
    await pump(tester, const Size(360, 800));
    final bar = find.byKey(const Key('shell-bottom-bar'));
    expect(
      find.descendant(of: bar, matching: find.byType(LastUpdatedLabel)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bar, matching: find.byType(TeamLinksBar)),
      findsNothing,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('phone landscape has no footer', (tester) async {
    await pump(tester, const Size(800, 360));
    expect(find.byKey(const Key('shell-bottom-bar')), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('phone drawer shows the full team links', (tester) async {
    await pump(tester, const Size(360, 800));
    await tester.tap(drawerButton(tester));
    await tester.pumpAndSettle();
    final bar = find.descendant(
      of: find.byType(Drawer),
      matching: find.byType(TeamLinksBar),
    );
    expect(bar, findsOneWidget);
    expect(tester.widget<TeamLinksBar>(bar).compact, isFalse);
    expect(find.text(TeamInfo.name), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('desktop footer has last updated and team links, no drawer', (
    tester,
  ) async {
    await pump(tester, const Size(1280, 800));
    final bar = find.byKey(const Key('shell-bottom-bar'));
    expect(
      find.descendant(of: bar, matching: find.byType(LastUpdatedLabel)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bar, matching: find.byType(TeamLinksBar)),
      findsOneWidget,
    );
    expect(find.byType(Drawer), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('system back closes the open drawer instead of leaving the app', (
    tester,
  ) async {
    // Android 16 的預測返回：App 沒先宣告「自己處理返回」時，系統會直接關掉 App。
    final handlesBack = <bool>[];
    var systemPops = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
          handlesBack.add(call.arguments as bool);
        }
        if (call.method == 'SystemNavigator.pop') systemPops++;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pump(tester, const Size(360, 800));
    await tester.tap(drawerButton(tester));
    await tester.pumpAndSettle();
    expect(handlesBack, isNotEmpty);
    expect(handlesBack.last, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);
    expect(systemPops, 0);
    expect(find.byType(AppShell), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('rotating with the drawer open does not throw', (tester) async {
    await pump(tester, const Size(360, 800));
    await tester.tap(drawerButton(tester));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(800, 360);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('crossing the breakpoint twice does not reopen the drawer', (
    tester,
  ) async {
    await pump(tester, const Size(500, 800));
    await tester.tap(drawerButton(tester));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(500, 800);
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('phone app bar leaves the app name to the drawer header', (
    tester,
  ) async {
    final l = await pump(tester, const Size(360, 800));
    final appBar = find.byType(AppBar);
    expect(
      find.descendant(of: appBar, matching: find.text(l.appName)),
      findsNothing,
    );
    expect(
      find.descendant(of: appBar, matching: find.byType(Image)),
      findsNothing,
    );
    await tester.tap(drawerButton(tester));
    await tester.pumpAndSettle();
    final drawer = find.byType(Drawer);
    expect(
      find.descendant(of: drawer, matching: find.text(l.appName)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: drawer, matching: find.textContaining('v1.8.1')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: drawer, matching: find.byType(Image)),
      findsOneWidget,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('phone account button gets the space the title used', (
    tester,
  ) async {
    // 舊版保留給 App 圖示的 48dp 讓給帳號按鈕；360 寬時上限從 160 變成 232。
    await pump(
      tester,
      const Size(360, 800),
      alias: 'AVeryLongAccountAliasName',
    );
    final indicator = tester.getRect(find.byType(UidIndicator));
    expect(indicator.width, greaterThan(160));
    expect(
      indicator.left,
      greaterThanOrEqualTo(tester.getRect(drawerButton(tester)).right),
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final (name, size, pinned) in [
    ('portrait pins them', const Size(360, 800), true),
    ('landscape scrolls them with the list', const Size(800, 360), false),
  ]) {
    testWidgets('drawer contributors and settings: $name', (tester) async {
      // 橫向高度只剩約 360dp，固定在底部會占掉三分之一，改成跟著清單一起捲。
      final l = await pump(tester, size);
      await tester.tap(drawerButton(tester));
      await tester.pumpAndSettle();
      final list = find
          .descendant(
            of: find.byType(Drawer),
            matching: find.byType(Scrollable),
          )
          .first;
      for (final label in [l.navContributors, l.navSettings, l.appName]) {
        final inList = find
            .descendant(of: list, matching: find.text(label))
            .evaluate()
            .isNotEmpty;
        // 頂部的 App 資訊一律跟著清單捲；貢獻者／設定只有高度夠時才固定。
        expect(inList, label == l.appName || !pinned, reason: label);
      }
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('phone landscape keeps the page clear of the camera cutout', (
    tester,
  ) async {
    // 橫向時開孔鏡頭在左邊；標題列由 AppBar 自己避開，內容區也要避開。
    await pump(tester, const Size(800, 360));
    tester.view.padding = const FakeViewPadding(left: 44);
    tester.view.viewPadding = const FakeViewPadding(left: 44);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('page:/')).left, greaterThanOrEqualTo(44));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('phone footer sits above the gesture bar', (tester) async {
    // 背景延伸到螢幕底，但文字要在手勢列上方。
    await pump(tester, const Size(360, 800));
    tester.view.padding = const FakeViewPadding(bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(LastUpdatedLabel)).bottom,
      lessThanOrEqualTo(800 - 24),
    );
    expect(
      tester.getRect(find.byKey(const Key('shell-bottom-bar'))).bottom,
      800,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  group('phone landscape top bar collapse', () {
    /// 頂端標題列目前的高度。
    double barHeight(WidgetTester tester) =>
        tester.getSize(find.byKey(const Key('shell-top-bar'))).height;

    /// 一頁很長的垂直列表。
    final longList = ListView.builder(
      itemCount: 100,
      itemBuilder: (_, i) => SizedBox(height: 48, child: Text('row $i')),
    );

    /// 在列表上拖曳 [dy]（負值＝內容往上捲）並等動畫結束。
    Future<void> drag(WidgetTester tester, double dy) async {
      await tester.drag(find.byType(ListView), Offset(0, dy));
      await tester.pumpAndSettle();
    }

    testWidgets('collapses on scroll down and returns on any scroll up', (
      tester,
    ) async {
      await pump(tester, const Size(800, 360), body: longList);
      expect(barHeight(tester), kToolbarHeight);
      await drag(tester, -300);
      expect(barHeight(tester), lessThan(1));
      await drag(tester, 50);
      expect(barHeight(tester), kToolbarHeight);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('is always visible at the top of the page', (tester) async {
      await pump(tester, const Size(800, 360), body: longList);
      await drag(tester, -300);
      await drag(tester, 1000);
      expect(barHeight(tester), kToolbarHeight);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('ignores horizontal scrollers', (tester) async {
      await pump(
        tester,
        const Size(800, 360),
        body: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (var i = 0; i < 50; i++)
              SizedBox(width: 100, child: Text('c$i')),
          ],
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(barHeight(tester), kToolbarHeight);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('rotating to portrait shows the collapsed bar at once', (
      tester,
    ) async {
      await pump(tester, const Size(800, 360), body: longList);
      await drag(tester, -300);
      tester.view.physicalSize = const Size(360, 800);
      await tester.pump();
      expect(barHeight(tester), kToolbarHeight);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('keyboard in landscape does not throw and bar returns', (
      tester,
    ) async {
      await pump(tester, const Size(800, 360), body: longList);
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(barHeight(tester), kToolbarHeight);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('portrait never collapses', (tester) async {
      await pump(tester, const Size(360, 800), body: longList);
      await drag(tester, -300);
      expect(barHeight(tester), kToolbarHeight);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });
}
