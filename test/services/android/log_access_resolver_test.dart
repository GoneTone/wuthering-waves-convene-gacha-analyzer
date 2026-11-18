import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/android/adb_shell_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/flutter_adb_session.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_resolver.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/root_shell.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/wuwa_game_package.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/client_log_source.dart';

import '../../helpers/wait_until.dart';

/// 可設定各項回傳值的平台替身。
class _FakePlatform extends LogAccessPlatform {
  int sdk = 34;
  bool wifi = true;
  bool adbWifiOn = false;
  bool canWriteSettings = true;

  /// false 時模擬還沒允許無線偵錯的 Wi‑Fi：系統立刻把開關改回關閉並跳詢問。
  bool networkTrusted = true;
  bool wss = true;
  bool storage = false;
  bool grantStorage = false;
  List<int> ports = [5555];
  final adbWifiWrites = <bool>[];

  /// 手機上裝的鳴潮；null 模擬查詢失敗。
  List<String>? games = [wuwaGlobalPackage];

  @override
  Future<List<String>?> installedGamePackages() async => games;

  @override
  Future<int> sdkInt() async => sdk;
  @override
  Future<bool> isWifiConnected() async => wifi;
  @override
  Future<bool> isAdbWifiEnabled() async => adbWifiOn;
  @override
  Future<bool> setAdbWifiEnabled(bool enabled) async {
    if (!canWriteSettings) return false;
    adbWifiWrites.add(enabled);
    adbWifiOn = enabled && networkTrusted;
    return true;
  }

  @override
  Future<bool> hasWriteSecureSettings() async => wss;

  /// 依序回傳的 NSD 結果；用完後改回傳 [ports]。
  final discoveries = <List<int>>[];

  /// NSD 查詢次數。
  int discoverCalls = 0;

  @override
  Future<List<int>> discoverAdbConnectPorts() async {
    discoverCalls++;
    return discoveries.isNotEmpty ? discoveries.removeAt(0) : ports;
  }

  @override
  Future<bool> hasStoragePermission() async => storage;

  /// requestStoragePermission 被呼叫的次數。
  int storageRequests = 0;
  @override
  Future<bool> requestStoragePermission({
    bool openSettingsIfBlocked = false,
  }) async {
    storageRequests++;
    return storage = grantStorage;
  }
}

/// root 狀態可設定的替身。
class _FakeRoot extends RootShell {
  bool present = false;
  bool granted = false;
  int verifies = 0;

  /// 設定後 verify 等它完成（模擬 root 工具的授權視窗還在等玩家按）。
  Completer<bool>? verifyGate;

  @override
  Future<bool> isSuPresent() async => present;
  @override
  Future<bool> verify() async {
    verifies++;
    return verifyGate?.future ?? granted;
  }

  @override
  Future<Uint8List> exec(String command) async => Uint8List(0);

  /// 健康狀態事件來源。
  final healthController = StreamController<bool>.broadcast();

  @override
  Stream<bool> get healthChanges => healthController.stream;

  /// close 被呼叫的次數。
  int closes = 0;

  @override
  Future<void> close() async => closes++;
}

/// 是否已配對可設定的金鑰替身。
class _FakeKeys extends AdbKeyStore {
  bool paired = true;

  @override
  Future<bool> hasKey() async => paired;
}

/// 記錄指令的 shell 連線替身。
class _Session implements AdbSession {
  final commands = <String>[];
  bool closed = false;

  @override
  Future<Uint8List> shell(String command) async {
    commands.add(command);
    return Uint8List.fromList(utf8.encode(command == 'id' ? 'uid=2000' : ''));
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  late _FakePlatform platform;
  late _FakeRoot root;
  late _FakeKeys keys;
  late _Session session;
  late bool connectable;
  late Set<int> refusedPorts;
  late List<int> attemptedPorts;

  setUp(() {
    platform = _FakePlatform();
    root = _FakeRoot();
    keys = _FakeKeys();
    session = _Session();
    connectable = true;
    refusedPorts = {};
    attemptedPorts = [];
  });

  LogAccessResolver resolver({
    Duration connectRetryDelay = Duration.zero,
    int connectRetryAttempts = 3,
  }) => LogAccessResolver(
    platform: platform,
    root: root,
    keyStore: keys,
    makeConnector: () async => (port) async {
      attemptedPorts.add(port);
      return connectable && !refusedPorts.contains(port) ? session : null;
    },
    discoverRetryDelay: Duration.zero,
    enableSettleDelay: Duration.zero,
    connectRetryDelay: connectRetryDelay,
    connectRetryAttempts: connectRetryAttempts,
  );

  group('connect retry after a stale port', () {
    test('rediscovers and connects to the new port without toggling', () async {
      // 無線偵錯剛關又開時，NSD 還會回報上一輪的連接埠；不能再切一次開關，要等它跟上。
      platform
        ..ports = [37001, 41002]
        ..discoveries.add([37001]);
      refusedPorts = {37001};
      final r = await resolver().resolve() as LogAccessReady;
      expect(r.method, LogAccessMethod.wirelessDebugging);
      expect(attemptedPorts, [37001, 41002]);
      expect(platform.adbWifiWrites, [true]);
    });

    test('gives up after the configured attempts and turns it off', () async {
      platform.ports = [37001];
      refusedPorts = {37001};
      final r =
          await resolver(connectRetryAttempts: 2).resolve() as LogAccessBlocked;
      expect(r.reason, LogAccessUnavailable.adbConnectFailed);
      expect(platform.discoverCalls, 3);
      expect(attemptedPorts, [37001], reason: 'refused ports are not retried');
      expect(platform.adbWifiWrites, [true, false]);
    });

    test('no port found at all fails without retrying', () async {
      platform.ports = [];
      final res = resolver();
      final r = await res.resolve() as LogAccessBlocked;
      expect(r.reason, LogAccessUnavailable.adbConnectFailed);
      expect(platform.discoverCalls, res.discoverAttempts);
      expect(platform.adbWifiWrites, [true, false]);
    });

    test('abort during the retry wait stops further attempts', () {
      fakeAsync((async) {
        connectable = false;
        final abort = Completer<void>();
        LogAccessOutcome? outcome;
        resolver(
          connectRetryDelay: const Duration(seconds: 1),
        ).resolve(abort: abort.future).then((o) => outcome = o);
        async.elapse(const Duration(milliseconds: 1));
        expect(platform.discoverCalls, 1);
        abort.complete();
        async.elapse(const Duration(seconds: 5));
        expect(
          (outcome! as LogAccessBlocked).reason,
          LogAccessUnavailable.adbConnectFailed,
        );
        expect(platform.discoverCalls, 1);
        expect(platform.adbWifiWrites, [true, false]);
      });
    });
  });

  test(
    'abort while root verify waits closes su and tries nothing else',
    () async {
      // 玩家按取消或手動送出後，不能再跳儲存權限詢問或打開無線偵錯。
      root
        ..present = true
        ..verifyGate = Completer<bool>();
      platform.sdk = 29;
      final abort = Completer<void>();
      final result = resolver().resolve(abort: abort.future);
      await Future<void>.delayed(Duration.zero);
      abort.complete();
      await Future<void>.delayed(Duration.zero);
      expect(root.closes, 1, reason: 'closing su dismisses the grant prompt');
      root.verifyGate!.complete(false);
      expect(await result, isA<LogAccessBlocked>());
      expect(platform.storageRequests, 0);
      expect(platform.adbWifiWrites, isEmpty);
    },
  );

  test('abort after resolve finished does not close the session', () async {
    root
      ..present = true
      ..granted = true;
    final abort = Completer<void>();
    await resolver().resolve(abort: abort.future);
    abort.complete();
    await Future<void>.delayed(Duration.zero);
    expect(root.closes, 0);
  });

  test(
    'wi-fi not yet allowed for wireless debugging has its own reason',
    () async {
      // 換到沒允許過的網路時，系統會把開關改回關閉並跳詢問；這不是配對失效。
      platform.networkTrusted = false;
      final r = await resolver().resolve() as LogAccessBlocked;
      expect(r.reason, LogAccessUnavailable.networkNotAllowed);
      expect(r.enabledWireless, isTrue);
    },
  );

  test('connect failure after turning wireless on is flagged', () async {
    connectable = false;
    final r = await resolver().resolve() as LogAccessBlocked;
    expect(r.reason, LogAccessUnavailable.adbConnectFailed);
    expect(r.enabledWireless, isTrue);
  });

  test(
    'connect failure turns wireless off when it must be off after use',
    () async {
      // 玩家照引導打開（或剛配對完）時開著，連不上也要關回去，之後的重試仍要關。
      connectable = false;
      platform.adbWifiOn = true;
      final r =
          await resolver().resolve(forceDisableAfterUse: true)
              as LogAccessBlocked;
      expect(platform.adbWifiWrites, [false]);
      expect(r.enabledWireless, isTrue);
      expect(r.wirelessLeftOn, isFalse);
    },
  );

  test('connect failure without permission reports it left on', () async {
    connectable = false;
    platform
      ..adbWifiOn = true
      ..canWriteSettings = false;
    final r =
        await resolver().resolve(forceDisableAfterUse: true)
            as LogAccessBlocked;
    expect(r.enabledWireless, isTrue);
    expect(r.wirelessLeftOn, isTrue);
  });

  test('connect failure with wireless already on is not flagged', () async {
    connectable = false;
    platform.adbWifiOn = true;
    final r = await resolver().resolve() as LogAccessBlocked;
    expect(r.enabledWireless, isFalse);
  });

  test('root wins when su present and verified', () async {
    root
      ..present = true
      ..granted = true;
    final r = await resolver().resolve() as LogAccessReady;
    expect(r.method, LogAccessMethod.root);
    expect(r.source, isA<ShellLogSource>());
    expect(platform.adbWifiWrites, isEmpty);
  });

  test('root ready reports the su session health', () async {
    // su 意外結束時等待畫面要顯示連線中斷。
    root
      ..present = true
      ..granted = true;
    final r = await resolver().resolve() as LogAccessReady;
    final health = <bool>[];
    final sub = r.healthChanges.listen(health.add);
    root.healthController.add(false);
    await Future<void>.delayed(Duration.zero);
    expect(health, [false]);
    await sub.cancel();
  });

  test(
    'su present but not granted is reported with the blocked reason',
    () async {
      // Magisk 倒數結束沒按允許會記成永久拒絕，之後不再詢問；要讓畫面說得出原因。
      root.present = true;
      keys.paired = false;
      final r = await resolver().resolve() as LogAccessBlocked;
      expect(r.reason, LogAccessUnavailable.notPaired);
      expect(r.rootDenied, isTrue);
    },
  );

  test('no su means root was not denied', () async {
    keys.paired = false;
    final r = await resolver().resolve() as LogAccessBlocked;
    expect(r.rootDenied, isFalse);
  });

  test('root release closes the su session', () async {
    root
      ..present = true
      ..granted = true;
    final r = await resolver().resolve() as LogAccessReady;
    expect(await r.release(), isFalse);
    expect(root.closes, 1);
  });

  test('root denied falls through to wireless debugging', () async {
    root.present = true;
    final r = await resolver().resolve() as LogAccessReady;
    expect(r.method, LogAccessMethod.wirelessDebugging);
  });

  test('android 10 with permission uses local file source', () async {
    platform
      ..sdk = 29
      ..storage = true;
    final r = await resolver().resolve() as LogAccessReady;
    expect(r.method, LogAccessMethod.legacyDirect);
    expect(
      (r.source as LocalFileLogSource).path,
      androidClientLogPathFor(wuwaGlobalPackage),
    );
  });

  group('game detection', () {
    test('no game: blocked before asking for root', () async {
      root
        ..present = true
        ..granted = true;
      platform.games = [];
      final r = await resolver().resolve() as LogAccessBlocked;
      expect(r.reason, LogAccessUnavailable.gameNotInstalled);
      expect(root.verifies, 0);
      expect(platform.adbWifiWrites, isEmpty);
    });

    test('several versions without a pick ask to choose', () async {
      platform.games = [wuwaGlobalPackage, wuwaSamsungPackage];
      final r = await resolver().resolve() as LogAccessBlocked;
      expect(r.reason, LogAccessUnavailable.chooseGame);
      expect(r.games, [wuwaGlobalPackage, wuwaSamsungPackage]);
    });

    test('a saved pick that is no longer installed asks again', () async {
      platform.games = [wuwaGlobalPackage, wuwaSamsungPackage];
      final r =
          await resolver().resolve(preferredGame: '$wuwaPackagePrefix.gone')
              as LogAccessBlocked;
      expect(r.reason, LogAccessUnavailable.chooseGame);
    });

    test('the saved pick reads that version', () async {
      root
        ..present = true
        ..granted = true;
      platform.games = [wuwaGlobalPackage, wuwaSamsungPackage];
      final r =
          await resolver().resolve(preferredGame: wuwaSamsungPackage)
              as LogAccessReady;
      expect(r.game, wuwaSamsungPackage);
      expect(r.games, [wuwaGlobalPackage, wuwaSamsungPackage]);
      expect(
        (r.source as ShellLogSource).path,
        androidClientLogPathFor(wuwaSamsungPackage),
      );
    });

    test('a single version is used even if another was saved', () async {
      platform
        ..sdk = 29
        ..storage = true
        ..games = [wuwaSamsungPackage];
      final r =
          await resolver().resolve(preferredGame: wuwaGlobalPackage)
              as LogAccessReady;
      expect(r.game, wuwaSamsungPackage);
      expect(
        (r.source as LocalFileLogSource).path,
        androidClientLogPathFor(wuwaSamsungPackage),
      );
    });

    test('detection failure keeps reading the google play version', () async {
      // channel 出錯不代表沒裝，不能因此擋住原本能用的流程。
      platform
        ..sdk = 29
        ..storage = true
        ..games = null;
      final r = await resolver().resolve() as LogAccessReady;
      expect(r.game, wuwaGlobalPackage);
    });

    test('shell source checks once where the log really is', () async {
      final r = await resolver().resolve() as LogAccessReady;
      final check = clientLogMissingCommand(
        androidClientLogPathFor(wuwaGlobalPackage),
        '/sdcard/Android/data/$wuwaGlobalPackage/files',
      );
      await waitUntil(() => session.commands.contains(check));
      await r.release();
    });
  });

  test('android 10 permission denied is blocked', () async {
    platform.sdk = 29;
    final r = await resolver().resolve() as LogAccessBlocked;
    expect(r.reason, LogAccessUnavailable.storagePermissionDenied);
  });

  test('retries only check the storage permission', () async {
    // 自動重試若再要求權限，永久拒絕時會一直跳去系統設定頁。
    platform
      ..sdk = 29
      ..grantStorage = true;
    final r =
        await resolver().resolve(requestPermissions: false) as LogAccessBlocked;
    expect(r.reason, LogAccessUnavailable.storagePermissionDenied);
    expect(platform.storageRequests, 0);
  });

  test('android 10 asks for permission once and uses it', () async {
    platform
      ..sdk = 28
      ..grantStorage = true;
    expect(await resolver().resolve(), isA<LogAccessReady>());
  });

  test('not paired is blocked before touching wifi debugging', () async {
    keys.paired = false;
    final r = await resolver().resolve() as LogAccessBlocked;
    expect(r.reason, LogAccessUnavailable.notPaired);
    expect(platform.adbWifiWrites, isEmpty);
  });

  test('no wifi is blocked', () async {
    platform.wifi = false;
    final r = await resolver().resolve() as LogAccessBlocked;
    expect(r.reason, LogAccessUnavailable.noWifi);
  });

  test('cannot enable wifi debugging means manual toggle mode', () async {
    platform.canWriteSettings = false;
    final r = await resolver().resolve() as LogAccessBlocked;
    expect(r.reason, LogAccessUnavailable.wirelessDebuggingOff);
  });

  test('manual toggle mode works once the user turned it on', () async {
    platform
      ..canWriteSettings = false
      ..wss = false
      ..adbWifiOn = true;
    expect(await resolver().resolve(), isA<LogAccessReady>());
  });

  test('release turns wifi debugging off only if we turned it on', () async {
    final r = await resolver().resolve() as LogAccessReady;
    expect(platform.adbWifiWrites, [true]);
    expect(await r.release(), isFalse);
    expect(platform.adbWifiWrites, [true, false]);
    expect(session.closed, isTrue);

    platform.adbWifiWrites.clear();
    platform.adbWifiOn = true;
    final kept = await resolver().resolve() as LogAccessReady;
    expect(await kept.release(), isFalse);
    expect(platform.adbWifiWrites, isEmpty);
  });

  test('forceDisableAfterUse turns it off even if it was on', () async {
    platform.adbWifiOn = true;
    final r =
        await resolver().resolve(forceDisableAfterUse: true) as LogAccessReady;
    await r.release();
    expect(platform.adbWifiWrites, [false]);
  });

  test('release reports wifi debugging left on without permission', () async {
    platform
      ..adbWifiOn = true
      ..wss = false
      ..canWriteSettings = false;
    final r =
        await resolver().resolve(forceDisableAfterUse: true) as LogAccessReady;
    expect(await r.release(), isTrue);
  });

  test('connect failure turns wifi debugging back off', () async {
    connectable = false;
    final r = await resolver().resolve() as LogAccessBlocked;
    expect(r.reason, LogAccessUnavailable.adbConnectFailed);
    expect(platform.adbWifiWrites, [true, false]);
  });

  test('grants write secure settings once when missing', () async {
    platform.wss = false;
    platform.adbWifiOn = true;
    await resolver().resolve();
    expect(
      session.commands.where((c) => c.startsWith('pm grant')).single,
      'pm grant tw.reh.wuwa.gacha android.permission.WRITE_SECURE_SETTINGS',
    );
  });

  test('preferred method is tried first', () async {
    root
      ..present = true
      ..granted = true;
    final r =
        await resolver().resolve(preferred: LogAccessMethod.wirelessDebugging)
            as LogAccessReady;
    expect(r.method, LogAccessMethod.wirelessDebugging);
    expect(root.verifies, 0);
  });
}
