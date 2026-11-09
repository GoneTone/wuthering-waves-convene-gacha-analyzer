import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/app_info.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/banner_storage.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/models/gacha_record.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/app_shell.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/ads.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/app_release.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/cloud_sync.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/settings.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/ads/banner_ad_slot.dart';

/// 有紀錄的帳號。
const _withRecords = '701000000';

/// 沒有任何紀錄的帳號。
const _empty = '701000001';

/// 卡池 `1` 有一筆紀錄、可切換作用中帳號的 repository 替身。
class _Repo extends GachaRepository {
  @override
  GachaState build() => GachaState(
    activeUid: _withRecords,
    byUid: {
      _withRecords: BannerStorage(
        playerId: _withRecords,
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.now().toUtc(),
        banners: {
          '1': [
            GachaRecord(
              resourceId: 1000,
              qualityLevel: 5,
              resourceType: '角色',
              cardPoolType: '1',
              name: 'Item',
              count: 1,
              time: DateTime(2026, 5, 1),
            ),
          ],
        },
      ),
      _empty: BannerStorage(
        playerId: _empty,
        languageCode: 'zh-Hant',
        lastUpdated: DateTime.now().toUtc(),
        banners: const {},
      ),
    },
    isBootstrapping: false,
  );

  /// 切換作用中帳號。
  void activate(String uid) => state = state.copyWith(activeUid: uid);

  @override
  Future<void> update({bool afterPairing = false}) async {}
}

/// 狀態固定、不碰原生 SDK 的廣告控制器替身。
class _Ads extends AdsController {
  /// 建立替身，[canRequestAds] 為廣告是否可請求。
  _Ads({required this.canRequestAds});

  /// 固定的「可請求廣告」旗標。
  final bool canRequestAds;

  /// [start] 被呼叫的次數。
  int starts = 0;

  @override
  AdsState build() => AdsState(canRequestAds: canRequestAds);

  @override
  Future<void> start() async => starts++;
}

/// 不發請求的版本檢查替身。
class _Release extends AppReleaseNotifier {
  @override
  Future<void> check({required bool manual}) async {}
}

/// 不啟動同步的雲端同步替身。
class _Sync extends CloudSyncNotifier {
  @override
  Future<void> start() async {}
}

/// 假橫幅的 key。
const _banner = Key('fake-banner');

void main() {
  late _Repo repo;
  late int loads;
  late _Ads ads;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 以 [size]、[locale] 開啟外殼並停在 [path]；路由頁面只顯示 `page:<path>`，廣告一律以請求寬度載入成功。
  Future<void> pump(
    WidgetTester tester,
    Size size, {
    String path = '/banner/1',
    bool android = true,
    bool canRequestAds = true,
    double keyboard = 0,
    Locale locale = const Locale('zh'),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
    repo = _Repo();
    loads = 0;
    ads = _Ads(canRequestAds: canRequestAds);
    final container = ProviderContainer(
      overrides: [
        appVersionProvider.overrideWithValue('1.8.1'),
        gachaRepositoryProvider.overrideWith(() => repo),
        appReleaseProvider.overrideWith(_Release.new),
        cloudSyncProvider.overrideWith(_Sync.new),
        isAndroidProvider.overrideWithValue(android),
        adsProvider.overrideWith(() => ads),
        bannerLoaderProvider.overrideWithValue((width) async {
          loads++;
          return (
            view: SizedBox(key: _banner, width: width.toDouble(), height: 50),
            dispose: () {},
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).waitForLoad();
    Widget page(GoRouterState s) => Text('page:${s.uri.path}');
    final router = GoRouter(
      initialLocation: path,
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
  }

  /// 沒有例外；有的話把完整錯誤（含溢出元件的位置）放進失敗訊息。
  void expectNoException(WidgetTester tester) {
    final e = tester.takeException();
    expect(e, isNull, reason: e is FlutterError ? e.toStringDeep() : '$e');
  }

  /// 底部狀態列。
  final statusBar = find.byKey(const Key('shell-bottom-bar'));

  testWidgets('phone portrait puts the ad above the status bar', (
    tester,
  ) async {
    await pump(tester, const Size(412, 915));
    expectNoException(tester);
    final ad = tester.getRect(find.byKey(_banner));
    final bar = tester.getRect(statusBar);
    expect(ad.bottom, lessThanOrEqualTo(bar.top));
    expect(ad.width, 412);
    final between = find.byType(Divider).evaluate().where((e) {
      final r = tester.getRect(find.byWidget(e.widget));
      return r.top >= ad.bottom && r.bottom <= bar.top;
    });
    expect(between, isNotEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('phone landscape puts the ad at the bottom', (tester) async {
    await pump(tester, const Size(915, 412));
    expectNoException(tester);
    expect(statusBar, findsNothing);
    expect(tester.getRect(find.byKey(_banner)).bottom, 412);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('tablet keeps the ad in the content column', (tester) async {
    await pump(tester, const Size(1280, 800));
    expectNoException(tester);
    final ad = tester.getRect(find.byKey(_banner));
    final rail = tester.getRect(find.byType(VerticalDivider));
    expect(ad.left, greaterThanOrEqualTo(rail.right));
    expect(ad.right, 1280);
    expect(
      tester.getRect(statusBar).top - ad.bottom,
      greaterThanOrEqualTo(AppSpacing.l),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('tablet in a right-to-left locale keeps the ad off the rail', (
    tester,
  ) async {
    // 阿拉伯文、希伯來文的側欄在右邊，讓位要跟著換邊。
    await pump(tester, const Size(1280, 800), locale: const Locale('ar'));
    expectNoException(tester);
    final ad = tester.getRect(find.byKey(_banner));
    expect(
      ad.right,
      lessThanOrEqualTo(tester.getRect(find.byType(VerticalDivider)).left),
    );
    expect(ad.left, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('phone landscape keeps the ad above the gesture bar', (
    tester,
  ) async {
    await pump(tester, const Size(915, 412));
    tester.view.padding = const FakeViewPadding(bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    await tester.pumpAndSettle();
    expectNoException(tester);
    expect(
      tester.getRect(find.byKey(_banner)).bottom,
      lessThanOrEqualTo(412 - 24),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('tablet keeps the bottom bars above the keyboard', (
    tester,
  ) async {
    // 狀態列原本在內容欄裡、會跟著被推到鍵盤上方；搬到 bottomNavigationBar 後要維持。
    await pump(tester, const Size(1280, 800), keyboard: 300);
    expectNoException(tester);
    expect(tester.getRect(statusBar).bottom, 500);
    expect(
      tester.getRect(find.byKey(_banner)).bottom,
      lessThanOrEqualTo(tester.getRect(statusBar).top),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('switching pages keeps the loaded ad', (tester) async {
    // 每換一頁就重新請求會灌高請求數、拉低曝光率。
    await pump(tester, const Size(412, 915));
    GoRouter.of(tester.element(find.text('page:/banner/1'))).go('/settings');
    await tester.pumpAndSettle();
    expect(find.text('page:/settings'), findsOneWidget);
    expect(find.byKey(_banner), findsOneWidget);
    expect(loads, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('hides the ad on empty pages', (tester) async {
    await pump(tester, const Size(412, 915), path: '/banner/2');
    expect(find.byKey(_banner), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('hides the ad when the active account has no records', (
    tester,
  ) async {
    await pump(tester, const Size(412, 915));
    expect(find.byKey(_banner), findsOneWidget);
    repo.activate(_empty);
    await tester.pumpAndSettle();
    expect(find.byKey(_banner), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('hides the ad when ads are not allowed', (tester) async {
    await pump(tester, const Size(412, 915), canRequestAds: false);
    expect(find.byKey(_banner), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('never shows ads off Android', (tester) async {
    await pump(tester, const Size(1280, 800), android: false);
    expect(find.byKey(_banner), findsNothing);
    expect(loads, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('starts the ads flow on Android only', (tester) async {
    await pump(tester, const Size(412, 915));
    expect(ads.starts, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('never starts the ads flow off Android', (tester) async {
    await pump(tester, const Size(1280, 800), android: false);
    expect(ads.starts, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('hides the ad while the keyboard is open', (tester) async {
    await pump(tester, const Size(412, 915), keyboard: 300);
    expectNoException(tester);
    expect(find.byKey(_banner), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('snack bars float above the ad', (tester) async {
    // 貼著廣告的 SnackBar 按鈕容易誤觸廣告（AdMob 間距規定），要留出間距。
    await pump(tester, const Size(412, 915));
    final messenger = ScaffoldMessenger.of(
      tester.element(find.text('page:/banner/1')),
    );
    messenger.showSnackBar(const SnackBar(content: Text('hello')));
    await tester.pumpAndSettle();
    // floating 的外距包在 SnackBar 元件裡，要量看得到的 Material 本體。
    expect(
      tester.getRect(find.byKey(_banner)).top -
          tester
              .getRect(
                find
                    .descendant(
                      of: find.byType(SnackBar),
                      matching: find.byType(Material),
                    )
                    .first,
              )
              .bottom,
      greaterThanOrEqualTo(AppSpacing.l),
    );
    messenger.hideCurrentSnackBar();
    await tester.pumpAndSettle();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('restart?'),
        action: SnackBarAction(label: 'restart', onPressed: () {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(_banner)).top -
          tester.getRect(find.byType(SnackBarAction)).bottom,
      greaterThanOrEqualTo(AppSpacing.l),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('snack bars keep the default behavior without an ad', (
    tester,
  ) async {
    await pump(tester, const Size(412, 915), canRequestAds: false);
    ScaffoldMessenger.of(
      tester.element(find.text('page:/banner/1')),
    ).showSnackBar(const SnackBar(content: Text('hello')));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('hello'))).snackBarTheme.behavior,
      isNot(SnackBarBehavior.floating),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
