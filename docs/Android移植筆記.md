# Android 移植筆記（踩雷與處理方式）

鳴潮版移植 Android 時實際踩到的問題、原因和處理方式，給之後原神版（`genshin_impact_wish_gacha_analyzer`）實作時參考。兩個專案架構相同（Flutter＋FVM、Windows 原生、Rust 攔截 helper、Riverpod），大部分內容可以直接套用。

- 總體設計：`docs/superpowers/specs/2026-11-05-android-support-roadmap-design.md`
- 這份筆記會隨每個子專案完成持續更新。
- 標示說明：**通用**＝兩個專案都會遇到；**鳴潮限定**＝和遊戲本身有關，原神要另外驗證。

---

## 一、取得紀錄（憑證）的方式

### 1. 攔截在 Android 上不可行（通用）

遊戲的 WebView 不信任使用者自己安裝的 CA，沒有 root 就沒辦法 MITM。PC 版的攔截做法要整條換掉。

### 2. 讀 log 可行，關鍵在權限（通用）

Android 11 起，一般 App 不能讀其他 App 的 `Android/data`；Android 13 也封掉了透過系統檔案選擇器（SAF）授權的路。所以 App 要用更高的權限去讀：

| 方式 | 適用情境 | 實作 |
|---|---|---|
| root | 有 root 的手機 | `Process.run('su', ['-c', 'cat <路徑>'])`，不用 Wi-Fi、不用配對 |
| 無線偵錯自我配對 | Android 11 以上、有 Wi-Fi | `flutter_adb`（純 Dart、BSD-3）配對 `127.0.0.1` 後取得 `uid=2000(shell)` |
| 直接讀 | Android 10 以下（尚未驗證） | 取得儲存權限，加上 `requestLegacyExternalStorage` |
| 手動貼網址 | 都不行的時候 | 兩個平台共用的輸入框 |

**無線偵錯的實測重點（ASUS、Android 16）：**
- 配對碼的視窗一離開設定頁就會關閉。第一次配對要用分割畫面，或做一個類似 Shizuku 的「在通知欄輸入配對碼」。
- Wi-Fi 一斷，無線偵錯會在 2 秒內被系統關掉；連回同一個 Wi-Fi 也**不會**自動恢復，而且連線埠會換。
- 金鑰會保留，**不需要重新配對**，只要找到新的連線埠重新連線。
- **一鍵恢復**：第一次拿到 shell 時，執行 `pm grant <自己的套件名> android.permission.WRITE_SECURE_SETTINGS`（manifest 要宣告這個權限，並加上 `tools:ignore="ProtectedPermissions"`）。之後 App 自己寫 `Settings.Global` 的 `adb_wifi_enabled=1` 打開無線偵錯，再用 `NsdManager` 找 `_adb-tls-connect._tcp` 的連線埠。實測從 Wi-Fi 斷線、App 冷啟動到拿到 shell 只要 1.2 秒。
- NSD 可能會找到同一個 Wi-Fi 上**其他手機**的無線偵錯，要比對 IP 是不是本機。
- 完全沒有 Wi-Fi 時做不到：系統會立刻把 `adb_wifi_enabled` 改回 0。
- 參考實作 Ascent（4o3F/Ascent）是 AGPL，MIT 專案**不能抄它的程式碼**，只能參考公開的做法。

**Google Play 的風險**：政策沒有明文規定。Play 上已經有同類的自我配對 ADB 工具在架，但讀取特定遊戲的 log 有可能被歸類為「存取其他 App」。要做好事前揭露，送審時也要附上審核說明。

### 3. 鳴潮的 log 位置和格式（鳴潮限定）

- 路徑：`/sdcard/Android/data/com.kurogame.wutheringwaves.global/files/UE4Game/Client/Client/Saved/Logs/Client.log`，會輪替成 `Client-backup-*.log`。
- XOR 混淆**和 PC 版完全相同**（`b ^ ((b & 1) != 0 ? 0xA5 : 0xEF)`），解碼和解析的程式碼可以直接共用。
- 喚取 URL 也會出現在 logcat（tag `KUROSDK`），格式和 PC 版一樣，只差 `platform=Android`。
- **原神要另外查**：原神 Android 版的 log 或 WebView 快取位置、是否有混淆。

---

## 二、建置與專案設定

### 4. `flutter create` 加平台時，會順手改到不該改的檔案（通用）

在既有專案執行 `flutter create --platforms=android .` 時，它還會：
- 升級 `pubspec.lock` 裡的一堆間接依賴；
- 把 `.metadata` 裡 Windows 平台的紀錄換掉；
- 新增 `test/widget_test.dart`（會因為找不到 `MyApp` 而讓 analyze 失敗）。

**處理**：執行完先看 `git status`，還原 `pubspec.lock`，刪掉 `test/widget_test.dart`，手動合併 `.metadata`（保留 windows，新增 android）。`analysis_options.yaml` 自動加上的 `android/**` 排除可以保留。

### 5. Android 不需要編 Rust（通用）

App 自己的 Rust 只負責 Windows 的攔截。`main.dart` 用 `if (Platform.isWindows)` 包住 `RustLib.init()` 和 Rust log stream 就好，**不需要**把 `rust_builder` 接進 Gradle，也不用裝 NDK。
- 注意：沒有初始化 Rust 時，呼叫 FRB 的 API 會**同步**丟 `StateError`。要確認呼叫點都有既有的錯誤處理接住（鳴潮版在 `update()` 外層的 catch 接住，會顯示「失敗」對話框）。

### 6. Kotlin 增量編譯「different roots」（通用，看磁碟配置）

pub cache 在 C 槽、專案在 E 槽時，Kotlin 增量編譯會失敗（`this and base files have different roots`）。
**處理**：在 `android/gradle.properties` 加 `kotlin.incremental=false`。

### 7. Gradle 9 移除了 `Project.exec()`，cargokit 外掛編不過（通用，只要有用 super_clipboard）

`super_clipboard` → `super_native_extensions`／`irondash_engine_context` 自帶的 cargokit 還在呼叫 `project.exec {}`。Flutter 3.47 的範本是 AGP 9.1＋Gradle 9.3.1，而 JDK 25 只支援 Gradle 9.1 以上，**沒辦法降版**。
**處理**：新增 `android/cargokit_gradle9_shim.gradle`，並在 `android/build.gradle.kts` 第一行 `apply(from = ...)`：
- 用 `p.ext.exec = { ... }` 補回方法（Gradle 的 Project **不吃** Groovy `metaClass` 注入，但 `ext` 裡的 closure 可以當成方法呼叫）。
- 轉接到**透過 `@Inject` 注入的 `ExecOperations`**。不要用 `providers.exec`：它會吞掉子程序的輸出，建置失敗時看不到 cargo 的錯誤；而且它的參數必須可序列化，cargokit 傳進環境變數的 `java.nio.Path` 會出錯。
- 這兩個外掛也寫死了 `compileSdkVersion 31`，新版 androidx 要求 34 以上。在同一個檔案用 `afterEvaluate` 把它們改成 `:app` 的 compileSdk。
- 上游修正：superlistapp/super_native_extensions#565／#585、irondash/irondash#95。合併發布後就刪掉這個檔案。
- **不建議**改用 `clipboard` 套件：它在 Android 上每複製一次就把圖寫進公開相簿；在 Windows 上只寫 `CF_DIB`，透明背景會不見。

### 8. 只改 `pubspec.lock` 時，`flutter build apk` 不會重新編譯 Dart（通用）

升級依賴之後直接 `flutter build apk`，打包進去的 `kernel_blob.bin` 可能還是舊的，實機上跑的就是舊程式。
**處理**：依賴有變動時先 `flutter clean` 再建置。可以比對 `build/app/intermediates/flutter/debug/flutter_assets/kernel_blob.bin` 的時間戳確認。

### 9. Windows 路徑太長，WebView2 外掛編不過（通用）

`flutter_inappwebview_windows` 在很深的目錄（例如 `AppData\Local\Temp\...\scratchpad\...`）建置時，會出現「無法開啟包含檔案」和 `Invalid argument` 錯誤。這是路徑超過長度上限造成的。
**處理**：專案放在短一點的路徑，或用 `subst X: <長路徑>` 掛成磁碟機代號再建置（換路徑後要先刪掉 `build/windows`，否則 CMake 快取還會指向舊路徑）。

### 10. App 圖示（通用）

沿用既有的 `tool/generate_app_icons.dart`，從同一張主圖多輸出 `mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png`（48／72／96／144／192）。不需要另外引入圖示產生套件。

### 11. App 名稱多語系（通用）

`android:label` 不能讀 ARB，要用 `res/values*/strings.xml`（`values`、`values-zh-rTW`、`values-zh-rCN`、`values-ja`），內容和各 ARB 的 `appName` 一致。英文名稱太長的話，桌面上會被截斷。

---

## 三、執行時的問題（實機才會發現）

### 12. 系統語言是繁中，App 卻顯示簡中（通用）

Android 回報的語言帶 script code，格式是 `zh-Hant-TW`（Windows 是 `zh_TW`）。專案沒有 `zh_Hant` 這個語系時，Flutter 預設的判斷只會把它記成「語言相符」並繼續往下找，結果被系統語言清單裡排在後面的 `zh-Hans-CN` 搶走。
**處理**：在 `localeListResolutionCallback` 把 `zh-Hant-*` 明確對應到裸 `zh`。

### 13. Flutter 內建元件文字在裸 `zh` 時是簡中（通用，Windows 也有）

`flutter_localizations` 對裸 `zh` 預設給簡中，例如關閉按鈕的提示文字會顯示「关闭」。
**處理**：把 `GlobalMaterialLocalizations`／`GlobalCupertinoLocalizations` 的 delegate 包一層，遇到裸 `zh` 時改成載入 `zh-Hant-TW`，`MaterialApp` 改用這份 delegate 清單。

### 14. Android 匯入時中文變亂碼（通用）

`file_selector` 在 Android 回傳的是 `XFile.fromData`（記憶體中的 bytes）。`cross_file` 0.3.5+2 的 `readAsString` 會忽略編碼，直接用 `String.fromCharCodes`，中文就變亂碼（Windows 回傳的是檔案路徑，所以不受影響）。
**處理**：把 `cross_file` 升到 0.3.5+5 以上，並加一個回歸測試防止日後降版。

### 15. 手機版面會溢出（通用）

桌面版的標題列（App 名稱、UID、更新按鈕排成一列）在約 400 dp 寬的手機上會溢出，側邊欄也會一直占掉寬度。這是子專案 3 的範圍。

---

## 四、喚取立繪（離屏 WebView 擷取 Spine canvas）

### 16. `flutter_inappwebview` 可以讓兩個平台共用（通用）

- **穩定版 6.1.5 在 AGP 9 上編不過**（`getDefaultProguardFile('proguard-android.txt') is no longer supported`）。要用 **6.2.0-beta.3**（2026-02 發布）。這是 beta 版，有維護上的風險。
- **`HeadlessInAppWebView`（不放進畫面的 WebView）在 Android 和 Windows 上 `requestAnimationFrame` 都不會停**，可以直接擷取，不需要 Windows 版那種 `Opacity(0.004)` 藏在 UI 後面的做法。
- 擷取流程和 Windows 版一樣：輪詢 → 武裝 rAF → 在 rAF 內 `toDataURL` → 用 `evaluateJavascript` 分塊讀回（每塊 200,000 字元）。
- 實測（角色 1508）：

| 平台 | 方式 | 首次 | 熱啟動 | canvas 解析度 |
|---|---|---|---|---|
| Android（dpr 2.625） | Headless，700×590 | 3.8 秒 | 1.1 秒 | 1423×1187 |
| Android | 隱藏 widget | — | 1.2 秒 | 1423×1187 |
| Windows（dpr 1） | Headless，2000×1680 | 3.2 秒 | 1.4 秒 | 1246×1038 |
| Windows | Headless＋CDP `deviceScaleFactor: 2`，1400×1180 | — | 1.7 秒 | **1624×1354** |

- **canvas 解析度由裝置像素比（dpr）決定，和 viewport 寬度無關**（Windows dpr 1 時把寬度從 2000 加到 3200，結果都還是 1246）。Windows 可以用 `callDevToolsProtocolMethod('Emulation.setDeviceMetricsOverride', {deviceScaleFactor})` 把 dpr 調高。所以「1422×1185 是 encore 上限」這個舊結論是錯的。
- 手機上的 AdGuard 之類的廣告攔截會讓頁面的部分資源 `ERR_CONNECTION_CLOSED`，但不影響擷取。

### 17. 正式實作的做法（通用）

- `pubspec.yaml` 移除 `webview_windows`，改成 `flutter_inappwebview: 6.2.0-beta.3`，**版本釘死不加 `^`**。之後要升級或換套件時，只需要改 `LuckdrawCaptureService` 裡的 `_InAppWebEngine`：服務只透過 `LuckdrawWebEngine` 介面（`loadUrl`、`evaluate`、`dispose`）操作 webview。
- 服務自己延遲建立並重用一個 `HeadlessInAppWebView`，**不再需要掛在 UI 上的宿主元件**，`MaterialApp.builder` 裡的 `Stack` 也拿掉了。建立失敗只試一次，之後 `capture` 都回傳 `null`。
- probe 腳本改成回傳 `JSON.stringify(...)` 字串，Dart 端再 `jsonDecode`。因為 `flutter_inappwebview` 回傳 JS 物件時，各平台給的 Dart 型別不一致，用字串最穩。
- viewport：**兩個平台都固定 1400×1180**，Windows 再用 CDP 把 `deviceScaleFactor` 設成 2。
  - 實機量測（Android dpr 2.625）：encore 的 canvas CSS 寬度會隨 viewport 寬度**依版面斷點階梯式變化**，和高度無關。760 以下約 542，1050 約 472，1400 約 822。
  - 用「比例反推寬度」是錯的：踩過兩次，先拿到 1011，再拿到 1239。1400 是最大的一階，乘上 dpr 之後，Windows 約 1624，Android 約 1644～2877。
- Windows 檢查 runtime：`WebViewEnvironment.getAvailableVersion() == null` 時代表沒有 WebView2，直接放棄。
- **Windows 建置**：
  - `flutter_inappwebview_windows` 在建置時會用 **NuGet** 下載 WIL 和 CppWinRT。開發機要先安裝（`winget install Microsoft.NuGet`）；GitHub Actions 的 `windows-latest` 已經內建。
  - 它的 CMakeLists 同樣會觸發 CMP0175 警告，`windows/CMakeLists.txt` 裡的 `set(CMAKE_POLICY_DEFAULT_CMP0175 OLD)` 要保留。
  - 原本為了 `webview_windows` 在 `build_release.ps1` 用 `CL` 注入 `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`，現在可以拿掉，因為新套件沒有用到 `<experimental/coroutine>`，release 建置已驗證通過。
- 延遲初始化已驗證：Windows App 啟動後閒置時，沒有任何屬於本 App 的 `msedgewebview2.exe`。
- **WebView2 資料資料夾一定要自己指定（Windows）**：`flutter_inappwebview_windows` 沒有傳 `WebViewEnvironment` 時，會用 `userDataFolder = nullptr`，WebView2 就把資料寫在**執行檔旁邊**（`<exe>.WebView2`）。安裝在 `Program Files` 的版本沒有寫入權限，WebView2 啟動會失敗，功能就靜靜地消失了。開發時從 `build` 資料夾執行一切正常，所以測不出來。**處理**：用 `WebViewEnvironment.create(settings: WebViewEnvironmentSettings(userDataFolder: <getApplicationCacheDirectory()>/webview2))` 建立環境，傳給 `HeadlessInAppWebView(webViewEnvironment: ...)`，dispose 時一起釋放。舊的 `webview_windows` 預設就放在使用者可寫的位置，所以以前沒遇過這個問題。

---

## 五、外部資料來源

### 18. encore 的資源網址變成回傳 HTML（通用，2026-11 起）

encore API 回傳的圖片網址變成 `https://api-v2.encore.moe/api/resource/...`，但這個路徑回的是網站的 HTML，不是圖片；真正的檔案在去掉 `/api` 的 `/resource/...`。
- 原本的程式只看 HTTP 200 就把內容存成 `.webp`，而且判斷「已有快取」只看檔案在不在。結果壞檔永遠不會重抓，畫面顯示 `Invalid image data`。
- 舊快取在 encore 改版前就下載好的使用者看起來正常，所以很難發現。是在 Android 上**全新安裝**時才發現的。
- **處理**（hotfix `fix/encore-resource-url`）：
  1. `downloadImage` 下載前先把網址的 `/api/resource/` 改成 `/resource/`，這樣索引裡已經存的舊網址也一併修好。
  2. 用檔頭（magic bytes）確認是 PNG、JPEG、WebP 或 GIF 才寫進快取。
  3. 載入圖片索引時，自動刪掉內容不是圖片的快取檔，讓已經中招的使用者更新後自動恢復。
- 原神版如果也用第三方資源站，**一律要用檔頭檢查下載內容**，不要只信 HTTP 狀態碼或副檔名。

