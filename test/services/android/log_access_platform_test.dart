import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/android/log_access_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(LogAccessPlatform.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  /// 讓 Kotlin 端以 [handler] 回應。
  void respond(Object? Function(MethodCall call) handler) {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('discoverAdbConnectPorts maps the port list', () async {
    respond((_) => [37155, 44091]);
    expect(await LogAccessPlatform().discoverAdbConnectPorts(), [37155, 44091]);
    expect(calls.single.method, 'discoverAdbConnectPorts');
  });

  test('discoverAdbConnectPorts tolerates platform errors', () async {
    respond((_) => throw PlatformException(code: 'nsd'));
    expect(await LogAccessPlatform().discoverAdbConnectPorts(), isEmpty);
  });

  test('setAdbWifiEnabled passes the flag and maps the result', () async {
    respond((_) => true);
    expect(await LogAccessPlatform().setAdbWifiEnabled(true), isTrue);
    expect(calls.single.arguments, {'enabled': true});
  });

  test('setAdbWifiEnabled is false on platform error', () async {
    respond((_) => throw PlatformException(code: 'security'));
    expect(await LogAccessPlatform().setAdbWifiEnabled(true), isFalse);
  });

  test('installedGamePackages filters, sorts and sends the prefix', () async {
    respond(
      (_) => [
        'com.kurogame.wutheringwaves.samsung',
        'com.kurogame.mingchao',
        'com.kurogame.wutheringwaves.global',
      ],
    );
    expect(await LogAccessPlatform().installedGamePackages(), [
      'com.kurogame.wutheringwaves.global',
      'com.kurogame.wutheringwaves.samsung',
    ]);
    expect(calls.single.method, 'installedGames');
    expect(
      (calls.single.arguments as Map)['prefix'],
      'com.kurogame.wutheringwaves',
    );
  });

  test('installedGamePackages is null on error, not empty', () async {
    // 空清單代表「沒裝」，查詢失敗不能被當成沒裝。
    respond((_) => throw PlatformException(code: 'pm'));
    expect(await LogAccessPlatform().installedGamePackages(), isNull);
  });

  test('launchGame passes the package', () async {
    respond((_) => true);
    expect(
      await LogAccessPlatform().launchGame(
        'com.kurogame.wutheringwaves.samsung',
      ),
      isTrue,
    );
    expect(calls.single.arguments, {
      'package': 'com.kurogame.wutheringwaves.samsung',
    });
  });

  test('missing plugin returns conservative defaults', () async {
    final p = LogAccessPlatform();
    expect(await p.isWifiConnected(), isFalse);
    expect(await p.hasWriteSecureSettings(), isFalse);
    expect(await p.sdkInt(), 0);
    expect(await p.discoverAdbConnectPorts(), isEmpty);
    await p.openWirelessDebugging();
  });
}
