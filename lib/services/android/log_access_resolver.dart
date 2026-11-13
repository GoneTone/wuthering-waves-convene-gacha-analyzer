import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/android/adb_shell_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/flutter_adb_session.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_method.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/root_shell.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/wuwa_game_package.dart';
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

  /// 目前的 Wi‑Fi 還沒允許無線偵錯：系統擋下開啟並跳出詢問視窗，要等玩家按「允許」。
  networkNotAllowed,

  /// Android 10 以下沒有儲存空間權限。
  storagePermissionDenied,

  /// 這台裝置無法自動讀取。
  unsupported,

  /// 手機上找不到國際服鳴潮。
  gameNotInstalled,

  /// 裝了多個版本的鳴潮、還沒選要讀哪一個（候選見 [LogAccessBlocked.games]）。
  chooseGame,
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
    required this.game,
    this.games = const [],
    Stream<bool>? healthChanges,
  }) : healthChanges = healthChanges ?? const Stream.empty();

  /// 讀取 Client.log 的來源。
  final ClientLogSource source;

  /// 讀取的是哪個版本的鳴潮（套件名稱）。
  final String game;

  /// 手機上裝的所有鳴潮版本；超過一個時等待畫面提供「切換版本」。
  final List<String> games;

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
  const LogAccessBlocked(
    this.reason, {
    this.rootDenied = false,
    this.enabledWireless = false,
    this.games = const [],
  });

  /// [LogAccessUnavailable.chooseGame] 時可選的鳴潮版本（套件名稱）。
  final List<String> games;

  /// 原因。
  final LogAccessUnavailable reason;

  /// 裝置有 `su` 但沒拿到 root 授權（被拒或沒按允許）；root 工具可能已記成永久拒絕而不再詢問。
  final bool rootDenied;

  /// 這次判斷曾由 App 打開無線偵錯（原本是關的）。之後若由系統打開（例如玩家在詢問視窗按允許），
  /// 重試時不能當成玩家原本就開著而在用完後留著。
  final bool enabledWireless;
}

/// 本 App 的套件名稱（授權 `WRITE_SECURE_SETTINGS` 用）。
const _appPackage = 'tw.reh.wuwa.gacha';

/// 授權自己開關無線偵錯的指令。
const grantWriteSecureSettingsCommand =
    'pm grant $_appPackage android.permission.WRITE_SECURE_SETTINGS';

/// 收回 [grantWriteSecureSettingsCommand] 的指令。
const revokeWriteSecureSettingsCommand =
    'pm revoke $_appPackage android.permission.WRITE_SECURE_SETTINGS';

/// 透過 shell 關閉無線偵錯（解除配對收回權限後，App 自己已經不能關，交給 shell 做；會中斷目前連線）。
const disableAdbWifiCommand = 'settings put global adb_wifi_enabled 0';

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
    this.enableSettleDelay = const Duration(milliseconds: 500),
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

  /// 打開無線偵錯後等多久再讀回開關（系統擋下時會立刻改回關閉）。
  final Duration enableSettleDelay;

  /// 本 resolver 的 logger。
  static final _log = Logger('capture.android');

  /// 決定讀取方式；[preferred] 先試，[forceDisableAfterUse] 為 true 時用完一律關閉無線偵錯（剛配對完時）。
  ///
  /// [requestPermissions] 為 false 時（自動重試）只檢查權限、不跳系統詢問。
  /// [abort] 完成時（玩家取消或手動送出）結束 root 授權等待，之後的方式都不再嘗試。
  /// 讀取方式之前先找鳴潮：沒裝就不跳 root 授權或打開無線偵錯；裝了多個版本時用 [preferredGame]，沒選過就請玩家選。
  Future<LogAccessOutcome> resolve({
    LogAccessMethod? preferred,
    String? preferredGame,
    bool forceDisableAfterUse = false,
    bool requestPermissions = true,
    Future<void>? abort,
  }) async {
    final sw = Stopwatch()..start();
    var finished = false;
    var aborted = false;
    unawaited(
      abort?.then((_) async {
        if (finished) return;
        aborted = true;
        _log.info('log access resolve aborted ms=${sw.elapsedMilliseconds}');
        // 關掉 su 會讓還在等授權的 verify 立刻失敗，root 工具的詢問視窗也跟著結束。
        await root.close();
      }),
    );
    try {
      final picked = await _pickGame(preferredGame);
      if (picked is LogAccessBlocked) return picked;
      final (game, games) = picked as (String, List<String>);
      return await _resolve(
        game: game,
        games: games,
        preferred: preferred,
        forceDisableAfterUse: forceDisableAfterUse,
        requestPermissions: requestPermissions,
        isAborted: () => aborted,
        sw: sw,
      );
    } finally {
      finished = true;
    }
  }

  /// 決定讀哪個版本：回傳 `(套件, 已安裝的版本)`，或沒裝／要玩家選時的 [LogAccessBlocked]。
  ///
  /// 查詢失敗（channel 出錯）不能當成沒裝，退回 Google Play 版照舊讀取。
  Future<Object> _pickGame(String? preferredGame) async {
    final games = await platform.installedGamePackages();
    if (games == null) {
      _log.warning('game detection failed, assuming $wuwaGlobalPackage');
      return (wuwaGlobalPackage, const <String>[]);
    }
    _log.info('games installed=${games.join(',')} preferred=$preferredGame');
    if (games.isEmpty) {
      return const LogAccessBlocked(LogAccessUnavailable.gameNotInstalled);
    }
    if (games.length == 1) return (games.single, games);
    if (preferredGame != null && games.contains(preferredGame)) {
      return (preferredGame, games);
    }
    return LogAccessBlocked(LogAccessUnavailable.chooseGame, games: games);
  }

  /// [resolve] 的實際流程；[isAborted] 為 true 後不再嘗試下一種方式。
  Future<LogAccessOutcome> _resolve({
    required String game,
    required List<String> games,
    required LogAccessMethod? preferred,
    required bool forceDisableAfterUse,
    required bool requestPermissions,
    required bool Function() isAborted,
    required Stopwatch sw,
  }) async {
    final order = {
      ?preferred,
      LogAccessMethod.root,
      LogAccessMethod.legacyDirect,
      LogAccessMethod.wirelessDebugging,
    };
    LogAccessBlocked? blocked;
    var rootDenied = false;
    for (final method in order) {
      if (isAborted()) break;
      final outcome = switch (method) {
        LogAccessMethod.root => await _tryRoot(
          game,
          games,
          onDenied: () => rootDenied = true,
        ),
        LogAccessMethod.legacyDirect => await _tryLegacy(
          game,
          games,
          requestPermissions,
        ),
        LogAccessMethod.wirelessDebugging => await _tryWireless(
          game,
          games,
          forceDisableAfterUse,
        ),
      };
      if (outcome is LogAccessReady) {
        _log.info(
          'log access ready method=${method.name} game=$game '
          'ms=${sw.elapsedMilliseconds}',
        );
        return outcome;
      }
      if (outcome is LogAccessBlocked) blocked ??= outcome;
    }
    final result = LogAccessBlocked(
      blocked?.reason ?? LogAccessUnavailable.unsupported,
      rootDenied: rootDenied,
      enabledWireless: blocked?.enabledWireless ?? false,
    );
    _log.info(
      'log access blocked reason=${result.reason.name} rootDenied=$rootDenied '
      'ms=${sw.elapsedMilliseconds}',
    );
    return result;
  }

  /// root：有 `su` 且授權成功才可用；否則回 null 讓下一種方式接手。有 `su` 卻沒拿到授權時呼叫 [onDenied]。
  Future<LogAccessOutcome?> _tryRoot(
    String game,
    List<String> games, {
    required void Function() onDenied,
  }) async {
    if (!await root.isSuPresent()) return null;
    if (!await root.verify()) {
      onDenied();
      return null;
    }
    return LogAccessReady(
      source: _shellSource(root.exec, 'root', game),
      method: LogAccessMethod.root,
      game: game,
      games: games,
      release: () async {
        await root.close();
        return false;
      },
    );
  }

  /// Android 10 以下：取得儲存權限後直接讀檔；[request] 為 false 時只檢查不詢問。
  Future<LogAccessOutcome?> _tryLegacy(
    String game,
    List<String> games,
    bool request,
  ) async {
    if (await platform.sdkInt() > 29) return null;
    if (!await platform.hasStoragePermission() &&
        !(request && await platform.requestStoragePermission())) {
      return const LogAccessBlocked(
        LogAccessUnavailable.storagePermissionDenied,
      );
    }
    return LogAccessReady(
      source: LocalFileLogSource(androidClientLogPathFor(game)),
      method: LogAccessMethod.legacyDirect,
      game: game,
      games: games,
      release: () async => false,
    );
  }

  /// 收集本機無線偵錯的連接埠；剛打開無線偵錯時 NSD 還找不到，所以重試幾次。
  Future<List<int>> discoverConnectPorts() async {
    for (var i = 0; i < discoverAttempts; i++) {
      final ports = await platform.discoverAdbConnectPorts();
      if (ports.isNotEmpty) return ports;
      await Future<void>.delayed(discoverRetryDelay);
    }
    return const [];
  }

  /// 無線偵錯：檢查配對與 Wi‑Fi、必要時打開無線偵錯、連線、補授權。
  Future<LogAccessOutcome?> _tryWireless(
    String game,
    List<String> games,
    bool forceDisableAfterUse,
  ) async {
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
    if (!wasOn) {
      await Future<void>.delayed(enableSettleDelay);
      if (!await platform.isAdbWifiEnabled()) {
        _log.info('wireless debugging not allowed on this network yet');
        return const LogAccessBlocked(
          LogAccessUnavailable.networkNotAllowed,
          enabledWireless: true,
        );
      }
    }
    final client = AdbShellClient(
      connect: await makeConnector(),
      rediscover: () async {
        if (!await platform.isAdbWifiEnabled()) {
          await platform.setAdbWifiEnabled(true);
        }
        return discoverConnectPorts();
      },
    );
    if (!await client.connectAny(await discoverConnectPorts())) {
      await client.close();
      if (!wasOn) await platform.setAdbWifiEnabled(false);
      return LogAccessBlocked(
        LogAccessUnavailable.adbConnectFailed,
        enabledWireless: !wasOn,
      );
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
      source: _shellSource(client.exec, 'adb', game),
      method: LogAccessMethod.wirelessDebugging,
      game: game,
      games: games,
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

  /// 讀 [game] 版本 log 的 shell 來源；log 不在預期路徑時記下實際找到的 `.log` 路徑（只記路徑），供之後修正。
  ShellLogSource _shellSource(ShellExec exec, String label, String game) {
    final path = androidClientLogPathFor(game);
    unawaited(_logIfMissing(exec, path, game));
    return ShellLogSource(exec: exec, path: path, label: label);
  }

  /// [path] 不存在時把 [game] 資料夾裡找到的 `.log` 路徑寫進 log。
  Future<void> _logIfMissing(ShellExec exec, String path, String game) async {
    try {
      final out = await exec(
        clientLogMissingCommand(path, '/sdcard/Android/data/$game/files'),
      );
      final found = utf8.decode(out, allowMalformed: true).trim();
      if (found.isEmpty) return;
      _log.warning(
        'client log missing game=$game found=${found.split('\n').join(' | ')}',
      );
    } on Object catch (e) {
      _log.info('client log missing check failed error=${e.runtimeType}');
    }
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
      final crypto = await keyStore.load();
      return (port) async =>
          crypto == null ? null : connectFlutterAdb(crypto, port);
    },
  );
});
