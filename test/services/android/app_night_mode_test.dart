import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/android/app_night_mode.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/settings_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AppNightMode.channelName);
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

  for (final mode in AppThemeMode.values) {
    test('sends the ${mode.name} theme to the platform', () async {
      respond((_) => true);
      await AppNightMode.sync(mode);
      expect(calls.single.method, 'setNightMode');
      expect(calls.single.arguments, {'mode': mode.name});
    });
  }

  test('platform errors are swallowed', () async {
    respond((_) => throw PlatformException(code: 'security'));
    await AppNightMode.sync(AppThemeMode.dark);
    expect(calls, hasLength(1));
  });

  test('a missing platform implementation is swallowed', () async {
    await AppNightMode.sync(AppThemeMode.light);
  });
}
