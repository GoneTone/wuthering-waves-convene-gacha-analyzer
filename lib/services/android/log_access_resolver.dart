import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/android/adb_shell_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/flutter_adb_session.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_method.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/root_shell.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/client_log_source.dart';

export 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_method.dart';

/// 沒有自動讀取方式的原因。
enum LogAccessUnavailable {
  /// 無線偵錯尚未配對。
  notPaired,

  /// 沒有連上 Wi‑Fi（無線偵錯無法使用）。
  noWifi,

  /// 已配對但連不上無線偵錯（配對可能失效）。
  adbConnectFailed,

  /// 無線偵錯是關的，App 也沒有權限打開（手動開關模式）。
  wirelessDebuggingOff,

  /// Android 10 以下沒有儲存空間權限。
  storagePermissionDenied,

  /// 這台裝置無法自動讀取。
  unsupported,
}

/// [LogAccessResolver.resolve] 的結果。
sealed class LogAccessOutcome {
  /// 建立結果。
  const LogAccessOutcome();
}

/// 可以讀取遊戲記錄。
final class LogAccessReady extends LogAccessOutcome {
  /// 建立結果。
  LogAccessReady({
    required this.source,
    required this.method,
    required this.release,
    Stream<bool>? healthChanges,
  }) : healthChanges = healthChanges ?? const Stream.empty();

  /// 讀取 Client.log 的來源。
  final ClientLogSource source;

  /// 使用的讀取方式。
  final LogAccessMethod method;

  /// 用完時呼叫：中斷連線並依規則關閉無線偵錯。
  ///
  /// 回傳 true 代表照規則應該關掉無線偵錯，但沒有權限關（手動開關模式），需要提示玩家自行關閉。
  final Future<bool> Function() release;

  /// 連線健康狀態變化（false＝中斷、true＝恢復）；root、直接讀為空 stream。
  final Stream<bool> healthChanges;
}

/// 沒有自動讀取方式。
final class LogAccessBlocked extends LogAccessOutcome {
  /// 建立結果。
  const LogAccessBlocked(this.reason);

  /// 原因。
  final LogAccessUnavailable reason;
}

/// 本 App 的套件名稱（授權 `WRITE_SECURE_SETTINGS` 用）。
const _appPackage = 'tw.reh.wuwa.gacha';

/// 授權自己開關無線偵錯的指令。
const grantWriteSecureSettingsCommand =
    'pm grant $_appPackage android.permission.WRITE_SECURE_SETTINGS';

/// 收回 [grantWriteSecureSettingsCommand] 的指令。
const revokeWriteSecureSettingsCommand =
    'pm revoke $_appPackage android.permission.WRITE_SECURE_SETTINGS';

/// 依 root → Android 10 以下直接讀 → 無線偵錯的順序決定怎麼讀遊戲記錄。
class LogAccessResolver {
  /// 建立 resolver；[makeConnector] 讀出配對金鑰並回傳連線函式。
  LogAccessResolver({
    required this.platform,
    required this.root,
    required this.keyStore,
    required this.makeConnector,
    this.discoverAttempts = 5,
    this.discoverRetryDelay = const Duration(seconds: 1),
  });

  /// 系統功能。
  final LogAccessPlatform platform;

  /// root shell。
  final RootShell root;

  /// 配對金鑰保存。
  final AdbKeyStore keyStore;

  /// 讀出金鑰後產生無線偵錯連線函式。
  final Future<AdbConnector> Function() makeConnector;

  /// NSD 找不到連接埠時最多嘗試幾次（剛打開無線偵錯時服務要一點時間才會出現）。
  final int discoverAttempts;

  /// NSD 重試間隔。
  final Duration discoverRetryDelay;

  /// 本 resolver 的 logger。
  static final _log = Logger('capture.android');

  /// 決定讀取方式；[preferred] 先試，[forceDisableAfterUse] 為 true 時用完一律關閉無線偵錯（剛配對完時）。
  Future<LogAccessOutcome> resolve({
    LogAccessMethod? preferred,
    bool forceDisableAfterUse = false,
  }) async {
    final sw = Stopwatch()..start();
    final order = {
      ?preferred,
      LogAccessMethod.root,
      LogAccessMethod.legacyDirect,
      LogAccessMethod.wirelessDebugging,
    };
    LogAccessBlocked? blocked;
    for (final method in order) {
      final outcome = switch (method) {
        LogAccessMethod.root => await _tryRoot(),
        LogAccessMethod.legacyDirect => await _tryLegacy(),
        LogAccessMethod.wirelessDebugging => await _tryWireless(
          forceDisableAfterUse,
        ),
      };
      if (outcome is LogAccessReady) {
        _log.info(
          'log access ready method=${method.name} ms=${sw.elapsedMilliseconds}',
        );
        return outcome;
      }
      if (outcome is LogAccessBlocked) blocked ??= outcome;
    }
    final result =
        blocked ?? const LogAccessBlocked(LogAccessUnavailable.unsupported);
    _log.info(
      'log access blocked reason=${result.reason.name} ms=${sw.elapsedMilliseconds}',
    );
    return result;
  }

  /// root：有 `su` 且授權成功才可用；否則回 null 讓下一種方式接手。
  Future<LogAccessOutcome?> _tryRoot() async {
    if (!await root.isSuPresent() || !await root.verify()) return null;
    return LogAccessReady(
      source: ShellLogSource(exec: root.exec, label: 'root'),
      method: LogAccessMethod.root,
      release: () async => false,
    );
  }

  /// Android 10 以下：取得儲存權限後直接讀檔。
  Future<LogAccessOutcome?> _tryLegacy() async {
    if (await platform.sdkInt() > 29) return null;
    if (!await platform.hasStoragePermission() &&
        !await platform.requestStoragePermission()) {
      return const LogAccessBlocked(
        LogAccessUnavailable.storagePermissionDenied,
      );
    }
    return LogAccessReady(
      source: LocalFileLogSource(androidClientLogPath),
      method: LogAccessMethod.legacyDirect,
      release: () async => false,
    );
  }

  /// 收集連接埠；剛打開無線偵錯時 NSD 還找不到，所以重試幾次。
  Future<List<int>> _discover() async {
    for (var i = 0; i < discoverAttempts; i++) {
      final ports = await platform.discoverAdbConnectPorts();
      if (ports.isNotEmpty) return ports;
      await Future<void>.delayed(discoverRetryDelay);
    }
    return const [];
  }

  /// 無線偵錯：檢查配對與 Wi‑Fi、必要時打開無線偵錯、連線、補授權。
  Future<LogAccessOutcome?> _tryWireless(bool forceDisableAfterUse) async {
    if (await platform.sdkInt() < 30) return null;
    if (!await keyStore.hasKey()) {
      return const LogAccessBlocked(LogAccessUnavailable.notPaired);
    }
    if (!await platform.isWifiConnected()) {
      return const LogAccessBlocked(LogAccessUnavailable.noWifi);
    }
    final wasOn = await platform.isAdbWifiEnabled();
    if (!wasOn && !await platform.setAdbWifiEnabled(true)) {
      return const LogAccessBlocked(LogAccessUnavailable.wirelessDebuggingOff);
    }
    final client = AdbShellClient(
      connect: await makeConnector(),
      rediscover: () async {
        if (!await platform.isAdbWifiEnabled()) {
          await platform.setAdbWifiEnabled(true);
        }
        return _discover();
      },
    );
    if (!await client.connectAny(await _discover())) {
      await client.close();
      if (!wasOn) await platform.setAdbWifiEnabled(false);
      return const LogAccessBlocked(LogAccessUnavailable.adbConnectFailed);
    }
    if (!await platform.hasWriteSecureSettings()) {
      try {
        await client.exec(grantWriteSecureSettingsCommand);
        _log.info(
          'write secure settings granted=${await platform.hasWriteSecureSettings()}',
        );
      } on AdbShellException catch (e) {
        _log.warning('write secure settings grant failed: ${e.message}');
      }
    }
    return LogAccessReady(
      source: ShellLogSource(exec: client.exec, label: 'adb'),
      method: LogAccessMethod.wirelessDebugging,
      healthChanges: client.healthChanges,
      release: () async {
        await client.close();
        if (wasOn && !forceDisableAfterUse) return false;
        if (await platform.setAdbWifiEnabled(false)) return false;
        _log.info('wireless debugging left on: no permission to turn it off');
        return true;
      },
    );
  }
}

/// 提供 [LogAccessResolver]，測試可 override。
final logAccessResolverProvider = Provider<LogAccessResolver>((ref) {
  final keyStore = ref.watch(adbKeyStoreProvider);
  return LogAccessResolver(
    platform: ref.watch(logAccessPlatformProvider),
    root: RootShell(),
    keyStore: keyStore,
    makeConnector: () async {
      final crypto = await keyStore.loadOrCreate();
      return (port) => connectFlutterAdb(crypto, port);
    },
  );
});
