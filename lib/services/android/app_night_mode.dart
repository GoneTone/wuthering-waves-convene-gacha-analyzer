import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/settings_storage.dart';

/// 把 App 內選的主題同步給 Android（Kotlin `AppThemeChannel`）。
///
/// 啟動畫面由系統在 App 執行前畫，讀不到 App 設定；Android 12 起可用
/// `UiModeManager.setApplicationNightMode` 告訴系統這個 App 要深色或淺色，系統會記住並在
/// 下次畫啟動畫面時套用。Android 11 以下不支援，Kotlin 端直接略過。
class AppNightMode {
  /// 與 Kotlin 端約定的 channel 名稱。
  static const channelName = 'tw.reh.wuwa.gacha/app_theme';

  /// 平台 channel。
  static const _channel = MethodChannel(channelName);

  /// 本包裝的 logger。
  static final _log = Logger('app.theme');

  /// 送出 [mode]；失敗只記 warning，不影響 App 本身的主題。
  static Future<void> sync(AppThemeMode mode) async {
    try {
      final applied = await _channel.invokeMethod<bool>('setNightMode', {
        'mode': mode.name,
      });
      _log.info('night mode synced mode=${mode.name} applied=$applied');
    } on PlatformException catch (e) {
      _log.warning(
        'night mode sync failed mode=${mode.name} code=${e.code} '
        'message=${e.message}',
      );
    } on MissingPluginException {
      _log.warning('night mode sync unavailable: no platform implementation');
    }
  }
}
