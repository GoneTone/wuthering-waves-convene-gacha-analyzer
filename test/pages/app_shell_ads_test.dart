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

/// 有紀錄的帳號。
const _withRecords = '701000000';

/// 卡池 `1` 有一筆紀錄的 repository 替身。
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
    },
    isBootstrapping: false,
  );

  @override
  Future<void> update({bool afterPairing = false}) async {}
}

/// 狀態固定、不碰原生 SDK 的廣告控制器替身。
class _Ads extends AdsController {
  /// [start] 被呼叫的次數。
  int starts = 0;

  @override
  AdsState build() => const AdsState(canRequestAds: true);

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

void main() {
  late _Ads ads;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 以 [size] 開啟外殼並停在卡池 1；路由頁面只顯示 `page:<path>`。
  Future<void> pump(
    WidgetTester tester,
    Size size, {
    bool android = true,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
    ads = _Ads();
    final container = ProviderContainer(
      overrides: [
        appVersionProvider.overrideWithValue('1.8.1'),
        gachaRepositoryProvider.overrideWith(_Repo.new),
        appReleaseProvider.overrideWith(_Release.new),
        cloudSyncProvider.overrideWith(_Sync.new),
        isAndroidProvider.overrideWithValue(android),
        adsProvider.overrideWith(() => ads),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).waitForLoad();
    Widget page(GoRouterState s) => Text('page:${s.uri.path}');
    final router = GoRouter(
      initialLocation: '/banner/1',
      routes: [
        ShellRoute(
          builder: (_, _, child) => AppShell(child: child),
          routes: [
            GoRoute(path: '/', builder: (_, s) => page(s)),
            GoRoute(path: '/banner/:type', builder: (_, s) => page(s)),
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
          locale: const Locale('zh'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 底部狀態列。
  final statusBar = find.byKey(const Key('shell-bottom-bar'));

  testWidgets('phone portrait has only the status bar at the bottom', (
    tester,
  ) async {
    // 底部橫幅已拿掉：狀態列直接貼底，上方沒有廣告與分隔線。
    await pump(tester, const Size(412, 915));
    expect(tester.takeException(), isNull);
    expect(tester.getRect(statusBar).bottom, 915);
    expect(find.byType(Divider), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('tablet keeps the status bar above the keyboard', (tester) async {
    // 狀態列在 bottomNavigationBar，Scaffold 不會自動把它推到鍵盤上方。
    await pump(tester, const Size(1280, 800), keyboard: 300);
    expect(tester.takeException(), isNull);
    expect(tester.getRect(statusBar).bottom, 500);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('starts the ads flow on Android only', (tester) async {
    await pump(tester, const Size(412, 915));
    expect(ads.starts, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('never starts the ads flow off Android', (tester) async {
    await pump(tester, const Size(1280, 800), android: false);
    expect(ads.starts, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('snack bars keep the default behavior', (tester) async {
    // 有橫幅時曾改成浮動以避開廣告；拿掉後回到預設。
    await pump(tester, const Size(412, 915));
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
