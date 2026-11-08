package tw.reh.wuwa.gacha

import android.app.UiModeManager
import android.content.Context
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 把 App 內選的主題告訴系統（`UiModeManager.setApplicationNightMode`，Android 12+），
 * 系統下次畫啟動畫面時才會用對的深淺色。對應 Dart 端 `AppNightMode`。
 */
class AppThemeChannel(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "tw.reh.wuwa.gacha/app_theme"
    }

    private val channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setNightMode" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                    result.success(false)
                    return
                }
                // 對 App 層級而言 MODE_NIGHT_AUTO 就是「不覆寫、跟隨系統」。
                val mode = when (call.argument<String>("mode")) {
                    "dark" -> UiModeManager.MODE_NIGHT_YES
                    "light" -> UiModeManager.MODE_NIGHT_NO
                    else -> UiModeManager.MODE_NIGHT_AUTO
                }
                context.getSystemService(UiModeManager::class.java).setApplicationNightMode(mode)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    /** 解除 channel handler。 */
    fun detach() = channel.setMethodCallHandler(null)
}
