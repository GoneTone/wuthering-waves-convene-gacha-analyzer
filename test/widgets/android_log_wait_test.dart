import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/log_access_setup_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_resolver.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/wuwa_game_package.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_repository.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/theme/app_theme.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/widgets/update_progress_dialog.dart';
import '../helpers/no_game_dir.dart';

/// 固定進度、記錄重試的 repository 替身。
class _Repo extends GachaRepository {
  _Repo(this._progress);

  final UpdateProgress _progress;

  /// retryLogAccess 被呼叫的次數。
  int retries = 0;

  @override
  GachaState build() => GachaState(progress: _progress, isBootstrapping: false);

  @override
  Future<void> retryLogAccess() async => retries++;

  /// selectGame 收到的套件。
  final selected = <String>[];

  @override
  Future<void> selectGame(String package) async => selected.add(package);

  /// update 被呼叫的次數。
  int updates = 0;

  @override
  Future<void> update({bool afterPairing = false}) async => updates++;

  @override
  Future<void> cancelCapture() async {
    cancels++;
    state = const GachaState(isBootstrapping: false);
  }

  /// cancelCapture 被呼叫的次數。
  int cancels = 0;
}

/// 記錄呼叫的平台替身。
class _Platform extends LogAccessPlatform {
  /// 被呼叫過的方法。
  final calls = <String>[];

  /// 無線偵錯開關目前的狀態。
  bool adbWifiOn = false;

  @override
  Future<bool> isAdbWifiEnabled() async => adbWifiOn;

  @override
  Future<bool> launchGame(String package) async {
    calls.add('launchGame $package');
    return true;
  }

  @override
  Future<void> openWirelessDebugging() async =>
      calls.add('openWirelessDebugging');
  @override
  Future<bool> requestStoragePermission({
    bool openSettingsIfBlocked = false,
  }) async {
    calls.add('requestStoragePermission settings=$openSettingsIfBlocked');
    return true;
  }
}

void main() {
  late _Repo repo;
  late _Platform platform;

  Future<AppLocalizations> pump(
    WidgetTester tester,
    UpdateProgress progress, {
    bool android = true,
    Locale locale = const Locale('zh'),
  }) async {
    repo = _Repo(progress);
    platform = _Platform();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noGameDirOverride,
          isAndroidProvider.overrideWithValue(android),
          logAccessPlatformProvider.overrideWithValue(platform),
          gachaRepositoryProvider.overrideWith(() => repo),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: const Scaffold(body: Center(child: UpdateProgressDialog())),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return AppLocalizations.of(
      tester.element(find.byType(UpdateProgressDialog)),
    )!;
  }

  testWidgets(
    'android wait shows open game and manual input, no game dir link',
    (tester) async {
      final l = await pump(
        tester,
        const WaitingForCapture(gamePackage: wuwaSamsungPackage),
      );
      expect(find.text(l.progressWaitingLog), findsOneWidget);
      expect(find.text(l.progressNotDetectedLink), findsNothing);
      expect(find.text(l.progressManualInputLink), findsOneWidget);
      // 只裝一個版本時不提版本。
      expect(find.text(l.actionSwitchGameVersion), findsNothing);
      await tester.tap(find.text(l.actionOpenGame));
      expect(platform.calls, ['launchGame $wuwaSamsungPackage']);
    },
  );

  testWidgets('checking log access offers only cancel', (tester) async {
    // 判斷完成前給「開啟鳴潮」，玩家進遊戲後才看到「無法自動讀取」，要來回切換兩次。
    final l = await pump(
      tester,
      const WaitingForCapture(checkingLogAccess: true),
    );
    expect(find.text(l.progressCheckingLogAccess), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text(l.actionOpenGame), findsNothing);
    expect(find.text(l.progressManualInputLink), findsNothing);
    expect(find.text(l.actionCancel), findsOneWidget);
  });

  testWidgets('open game hidden until the game is known', (tester) async {
    final l = await pump(tester, const WaitingForCapture());
    expect(find.text(l.actionOpenGame), findsNothing);
  });

  testWidgets('several versions show the one being read and can switch', (
    tester,
  ) async {
    final l = await pump(
      tester,
      const WaitingForCapture(
        gamePackage: wuwaSamsungPackage,
        installedGames: [wuwaGlobalPackage, wuwaSamsungPackage],
      ),
    );
    expect(
      find.text(l.progressGameVersion(l.gameVersionGalaxyStore)),
      findsOneWidget,
    );
    await tester.tap(find.text(l.actionSwitchGameVersion));
    await tester.pumpAndSettle();
    expect(repo.cancels, 1);
    expect(repo.updates, 1);
  });

  testWidgets('choose game lists every installed version', (tester) async {
    const other = 'com.kurogame.wutheringwaves.other';
    final l = await pump(
      tester,
      const WaitingForCapture(
        logAccessUnavailable: LogAccessUnavailable.chooseGame,
        installedGames: [wuwaGlobalPackage, wuwaSamsungPackage, other],
      ),
    );
    expect(find.text(l.progressCheckingLogAccess), findsOneWidget);
    expect(find.text(l.logChooseGameVersion), findsOneWidget);
    expect(find.text(l.gameVersionGooglePlay), findsOneWidget);
    expect(find.text(other), findsOneWidget);
    await tester.tap(find.text(l.gameVersionGalaxyStore));
    expect(repo.selected, [wuwaSamsungPackage]);
    expect(find.text(l.progressManualInputLink), findsOneWidget);
  });

  testWidgets('game not installed offers check again and the store', (
    tester,
  ) async {
    final l = await pump(
      tester,
      const WaitingForCapture(
        logAccessUnavailable: LogAccessUnavailable.gameNotInstalled,
      ),
    );
    expect(find.text(l.updateOpenPlayStore), findsOneWidget);
    await tester.tap(find.text(l.actionRedetectGame));
    expect(repo.retries, 1);
  });

  testWidgets('windows wait is unchanged', (tester) async {
    final l = await pump(tester, const WaitingForCapture(), android: false);
    expect(find.text(l.progressWaiting), findsOneWidget);
    expect(find.text(l.progressNotDetectedLink), findsOneWidget);
    expect(find.text(l.actionOpenGame), findsNothing);
  });

  testWidgets('credential ready asks to return to the app', (tester) async {
    final l = await pump(
      tester,
      const WaitingForCapture(credentialReady: true),
    );
    expect(find.text(l.progressCredentialReady), findsOneWidget);
    expect(find.text(l.progressOpenGameHint), findsNothing);
    expect(find.text(l.actionOpenGame), findsNothing);
  });

  testWidgets('root denial explains how to allow it', (tester) async {
    final l = await pump(
      tester,
      const WaitingForCapture(
        logAccessUnavailable: LogAccessUnavailable.notPaired,
        rootDenied: true,
      ),
    );
    expect(find.text(l.logRootDeniedHint), findsOneWidget);
  });

  testWidgets('no root denial hint otherwise', (tester) async {
    final l = await pump(
      tester,
      const WaitingForCapture(
        logAccessUnavailable: LogAccessUnavailable.notPaired,
      ),
    );
    expect(find.text(l.logRootDeniedHint), findsNothing);
  });

  testWidgets('connection lost shows the warning', (tester) async {
    final l = await pump(
      tester,
      const WaitingForCapture(logConnectionLost: true),
    );
    expect(find.text(l.progressLogConnectionLost), findsOneWidget);
  });

  for (final reason in LogAccessUnavailable.values) {
    if (reason == LogAccessUnavailable.chooseGame) continue;
    testWidgets(
      'unavailable ${reason.name} shows reason without progress bar',
      (tester) async {
        final l = await pump(
          tester,
          WaitingForCapture(logAccessUnavailable: reason),
        );
        expect(find.text(l.progressLogUnavailableTitle), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        final text = switch (reason) {
          LogAccessUnavailable.notPaired => l.logUnavailableNotPaired,
          LogAccessUnavailable.noWifi => l.logUnavailableNoWifi,
          LogAccessUnavailable.adbConnectFailed => l.logUnavailableAdbFailed,
          LogAccessUnavailable.wirelessDebuggingOff =>
            l.logUnavailableWirelessOff,
          LogAccessUnavailable.storagePermissionDenied =>
            l.logUnavailableStorage,
          LogAccessUnavailable.unsupported => l.logUnavailableUnsupported,
          LogAccessUnavailable.networkNotAllowed =>
            l.logUnavailableNetworkNotAllowed,
          LogAccessUnavailable.gameNotInstalled =>
            l.logUnavailableGameNotInstalled,
          LogAccessUnavailable.chooseGame => l.logChooseGameVersion,
        };
        expect(find.text(text), findsOneWidget);
        expect(find.text(l.progressManualInputLink), findsOneWidget);
      },
    );
  }

  for (final (reason, label) in [
    (LogAccessUnavailable.notPaired, 'setup'),
    (LogAccessUnavailable.adbConnectFailed, 'repair'),
  ]) {
    testWidgets('${reason.name} ends the update and opens the setup page', (
      tester,
    ) async {
      final l = await pump(
        tester,
        WaitingForCapture(logAccessUnavailable: reason),
      );
      await tester.tap(
        find.text(label == 'setup' ? l.actionSetupLogAccess : l.actionRepair),
      );
      await tester.pumpAndSettle();
      expect(repo.cancels, 1);
      expect(find.byType(LogAccessSetupPage), findsOneWidget);
    });
  }

  testWidgets('wireless debugging off offers to open it', (tester) async {
    final l = await pump(
      tester,
      const WaitingForCapture(
        logAccessUnavailable: LogAccessUnavailable.wirelessDebuggingOff,
      ),
    );
    await tester.tap(find.text(l.actionOpenWirelessDebugging));
    expect(platform.calls, ['openWirelessDebugging']);
  });

  testWidgets('storage denied re-requests and retries', (tester) async {
    final l = await pump(
      tester,
      const WaitingForCapture(
        logAccessUnavailable: LogAccessUnavailable.storagePermissionDenied,
      ),
    );
    await tester.tap(find.text(l.actionRegrantStorage));
    await tester.pump();
    // 玩家主動按的才可以在永久拒絕時改開系統設定頁。
    expect(platform.calls, ['requestStoragePermission settings=true']);
    expect(repo.retries, 1);
  });

  testWidgets('network not allowed: resume retries only once allowed', (
    tester,
  ) async {
    // 玩家在系統視窗按「取消」也會回到本 App；這時重試會再跳一次詢問，變成關不掉的迴圈。
    final l = await pump(
      tester,
      const WaitingForCapture(
        logAccessUnavailable: LogAccessUnavailable.networkNotAllowed,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 3));
    expect(repo.retries, 0);

    platform.adbWifiOn = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 3));
    expect(repo.retries, 1);

    await tester.tap(find.text(l.actionRetry));
    await tester.pump();
    expect(repo.retries, 2, reason: 'the button asks again');
  });

  testWidgets('resuming the app retries when unavailable', (tester) async {
    await pump(
      tester,
      const WaitingForCapture(
        logAccessUnavailable: LogAccessUnavailable.wirelessDebuggingOff,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(repo.retries, 1);
  });

  for (final (label, progress) in [
    ('checking', const WaitingForCapture(checkingLogAccess: true)),
    ('waiting', const WaitingForCapture()),
    (
      'waiting with several versions',
      const WaitingForCapture(
        gamePackage: 'com.kurogame.wutheringwaves.some_long_store_name',
        installedGames: [
          wuwaGlobalPackage,
          'com.kurogame.wutheringwaves.some_long_store_name',
        ],
      ),
    ),
    (
      'choose game',
      const WaitingForCapture(
        logAccessUnavailable: LogAccessUnavailable.chooseGame,
        installedGames: [
          wuwaGlobalPackage,
          wuwaSamsungPackage,
          'com.kurogame.wutheringwaves.some_long_store_name',
        ],
      ),
    ),
    (
      'game not installed',
      const WaitingForCapture(
        logAccessUnavailable: LogAccessUnavailable.gameNotInstalled,
      ),
    ),
    ('connection lost', const WaitingForCapture(logConnectionLost: true)),
    (
      'not paired',
      const WaitingForCapture(
        logAccessUnavailable: LogAccessUnavailable.notPaired,
      ),
    ),
    (
      'wireless off',
      const WaitingForCapture(
        logAccessUnavailable: LogAccessUnavailable.wirelessDebuggingOff,
      ),
    ),
  ]) {
    testWidgets('$label fits a landscape phone without overflow', (
      tester,
    ) async {
      // 實機橫向 2400×1080、dpr 2.75 → 約 873×393 邏輯像素。
      tester.view.physicalSize = const Size(873, 393);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(tester, progress);
      expect(tester.takeException(), isNull);
    });
  }

  for (final reason in [
    LogAccessUnavailable.notPaired,
    LogAccessUnavailable.gameNotInstalled,
    LogAccessUnavailable.chooseGame,
  ]) {
    testWidgets('long english ${reason.name} wraps on a narrow phone', (
      tester,
    ) async {
      // 實機直向 1080 寬、dpr 2.625 → 約 411 邏輯像素。
      tester.view.physicalSize = const Size(411, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(
        tester,
        WaitingForCapture(
          logAccessUnavailable: reason,
          installedGames: const [
            wuwaGlobalPackage,
            wuwaSamsungPackage,
            'com.kurogame.wutheringwaves.some_long_store_name',
          ],
        ),
        locale: const Locale('en'),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('completed shows wireless left on hint', (tester) async {
    final l = await pump(
      tester,
      UpdateCompleted(
        totalNewRecords: 0,
        failedBanners: const [],
        updatedAt: DateTime.utc(2026),
        itemImagesDownloaded: 0,
        wirelessDebuggingLeftOn: true,
      ),
    );
    expect(find.text(l.progressWirelessLeftOnHint), findsOneWidget);
  });
}
