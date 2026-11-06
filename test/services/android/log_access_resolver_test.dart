import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/android/adb_shell_client.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/flutter_adb_session.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_platform.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_resolver.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/android/root_shell.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/client_log_source.dart';

/// 可設定各項回傳值的平台替身。
class _FakePlatform extends LogAccessPlatform {
  int sdk = 34;
  bool wifi = true;
  bool adbWifiOn = false;
  bool canWriteSettings = true;
  bool wss = true;
  bool storage = false;
  bool grantStorage = false;
  List<int> ports = [5555];
  final adbWifiWrites = <bool>[];

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
    adbWifiOn = enabled;
    return true;
  }

  @override
  Future<bool> hasWriteSecureSettings() async => wss;
  @override
  Future<List<int>> discoverAdbConnectPorts() async => ports;
  @override
  Future<bool> hasStoragePermission() async => storage;
  @override
  Future<bool> requestStoragePermission() async => storage = grantStorage;
}

/// root 狀態可設定的替身。
class _FakeRoot extends RootShell {
  bool present = false;
  bool granted = false;
  int verifies = 0;

  @override
  Future<bool> isSuPresent() async => present;
  @override
  Future<bool> verify() async {
    verifies++;
    return granted;
  }

  @override
  Future<Uint8List> exec(String command) async => Uint8List(0);

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

  setUp(() {
    platform = _FakePlatform();
    root = _FakeRoot();
    keys = _FakeKeys();
    session = _Session();
    connectable = true;
  });

  LogAccessResolver resolver() => LogAccessResolver(
    platform: platform,
    root: root,
    keyStore: keys,
    makeConnector: () async =>
        (port) async => connectable ? session : null,
    discoverRetryDelay: Duration.zero,
  );

  test('root wins when su present and verified', () async {
    root
      ..present = true
      ..granted = true;
    final r = await resolver().resolve() as LogAccessReady;
    expect(r.method, LogAccessMethod.root);
    expect(r.source, isA<ShellLogSource>());
    expect(platform.adbWifiWrites, isEmpty);
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
    expect((r.source as LocalFileLogSource).path, androidClientLogPath);
  });

  test('android 10 permission denied is blocked', () async {
    platform.sdk = 29;
    final r = await resolver().resolve() as LogAccessBlocked;
    expect(r.reason, LogAccessUnavailable.storagePermissionDenied);
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
