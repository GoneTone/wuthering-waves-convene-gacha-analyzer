import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/pages/log_access_setup_page.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_resolver.dart';
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
  _Platform({this.installed = true});

  /// 是否安裝遊戲。
  final bool installed;

  /// 被呼叫過的方法。
  final calls = <String>[];

  @override
  Future<bool> isGameInstalled() async => installed;
  @override
  Future<bool> launchGame() async {
    calls.add('launchGame');
    return true;
  }

  @override
  Future<void> openWirelessDebugging() async =>
      calls.add('openWirelessDebugging');
  @override
  Future<bool> requestStoragePermission() async {
    calls.add('requestStoragePermission');
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
    bool installed = true,
  }) async {
    repo = _Repo(progress);
    platform = _Platform(installed: installed);
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
          locale: const Locale('zh'),
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
      final l = await pump(tester, const WaitingForCapture());
      expect(find.text(l.progressWaitingLog), findsOneWidget);
      expect(find.text(l.progressNotDetectedLink), findsNothing);
      expect(find.text(l.progressManualInputLink), findsOneWidget);
      await tester.tap(find.text(l.actionOpenGame));
      expect(platform.calls, ['launchGame']);
    },
  );

  testWidgets('open game hidden when the game is not installed', (
    tester,
  ) async {
    final l = await pump(tester, const WaitingForCapture(), installed: false);
    expect(find.text(l.actionOpenGame), findsNothing);
  });

  testWidgets('windows wait is unchanged', (tester) async {
    final l = await pump(tester, const WaitingForCapture(), android: false);
    expect(find.text(l.progressWaiting), findsOneWidget);
    expect(find.text(l.progressNotDetectedLink), findsOneWidget);
    expect(find.text(l.actionOpenGame), findsNothing);
  });

  testWidgets('connection lost shows the warning', (tester) async {
    final l = await pump(
      tester,
      const WaitingForCapture(logConnectionLost: true),
    );
    expect(find.text(l.progressLogConnectionLost), findsOneWidget);
  });

  for (final reason in LogAccessUnavailable.values) {
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
    expect(platform.calls, ['requestStoragePermission']);
    expect(repo.retries, 1);
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
