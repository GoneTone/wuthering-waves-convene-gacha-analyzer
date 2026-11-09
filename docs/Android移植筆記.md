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
| 手動輸入 | 都不行的時候 | 兩個平台共用：貼上網址（可整段貼上，例如飛航模式複製的錯誤訊息）或選擇 `Client.log` 檔案（見第 19 節） |

**無線偵錯的實測重點（ASUS、Android 16）：**
- 配對碼的視窗一離開設定頁就會關閉。第一次配對要用分割畫面，或做一個類似 Shizuku 的「在通知欄輸入配對碼」。**通知欄輸入已實測可行**，做法見第 19 節。
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

桌面版的標題列（App 名稱、UID、更新按鈕排成一列）在約 400 dp 寬的手機上會溢出，側邊欄也會一直占掉寬度。已在子專案 3 處理，見「七、手機版面」。

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
- 服務自己延遲建立並重用一個 `HeadlessInAppWebView`，**不再需要掛在 UI 上的宿主元件**，`MaterialApp.builder` 裡的 `Stack` 也拿掉了。
  - 工廠回傳 `null`（平台不支援，例如 Windows 沒有 WebView2）時記住，不再嘗試。
  - 建立時丟例外（例如低階手機冷啟系統 WebView 逾時）**不鎖死**，下次擷取會再試。
  - 擷取途中 webview 出錯（renderer 被系統回收、WebView2 程序崩潰）時，丟掉這個 engine，下次重建。否則之後每次擷取都會卡到逾時。
  - `run()` 之後的步驟（等 controller、CDP 設定）失敗時，要把已經啟動的 webview 和 `WebViewEnvironment` 一起 dispose，不然 webview 程序會一直留到 App 結束。
  - `dispose()` 要等鎖內進行中的擷取結束才釋放，之後也不再建立新的 webview。
  - 判斷是否已經 arm，要看**頁面上的** `window.__capArmed`，不要用 Dart 端的區域變數：頁面自行重載或轉址後旗標會消失，必須重新 arm。
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
  1. `downloadImage` **先用原網址**下載。只有「2xx 但內容不是圖片」，而且網址是 `https://api-v2.encore.moe/api/resource/...` 這種格式時，才改用去掉 `/api` 的 `/resource/...` 重試一次。encore 修好後原網址會直接成功，不需要更新 App。連線失敗或非 2xx 不重試，以免逾時時間加倍。
  2. 用檔頭（magic bytes）確認是 PNG、JPEG、WebP 或 GIF 才寫進快取。
  3. 載入圖片索引時，自動刪掉內容不是圖片的快取檔，讓已經中招的使用者更新後自動恢復。
     - 只檢查 `_icon.`、`_illustration`、`_luckdraw` 這幾種檔名，跳過 `.tmp`、其他檔案和子目錄。
     - **只執行一次**：完成後在快取目錄留下 `.non_image_purged_v1` 標記檔。
     - 用**自己的 try/catch** 包住，失敗也不能擋住索引載入。否則 state 會停在空索引，之後的寫入會把磁碟上的索引覆寫掉。
- 原神版如果也用第三方資源站，**一律要用檔頭檢查下載內容**，不要只信 HTTP 狀態碼或副檔名。

---

## 六、取得紀錄的實作細節（子專案 2）

設計：`docs/superpowers/specs/2026-11-06-android-credential-capture-design.md`。

### 19. 無線偵錯配對與一鍵恢復的實測結果（通用，2026-11-06，ASUS Android 16）

**直接跳到「無線偵錯」頁**
- 系統設定沒有公開「無線偵錯」頁的 Activity。但快速設定磚長按的入口可以用：送 `android.service.quicksettings.action.QS_TILE_PREFERENCES`，**只指定套件 `com.android.settings`、不要寫死類別**（接這個 action 的 Activity 各版本名稱不同：Android 13 是 `Settings$DevelopmentSettingsDashboardActivity`，ASUS Android 16 是 `Settings$DevelopmentSettingsActivity`；系統介面處理磚長按時也是只指定套件），並帶 `Intent.EXTRA_COMPONENT_NAME = com.android.settings/.development.qstile.DevelopmentTiles$WirelessDebugging`，就會直接開「無線偵錯」頁。這不是公開保證的介面，其他廠牌要另外驗證。
- **這個 intent 一定要加 `FLAG_ACTIVITY_NO_HISTORY`**：開發人員選項處理完磚的 intent 後會留在無線偵錯頁底下，每次回到它（例如橫向 App 跳過去、返回時被重建）都會再開一次無線偵錯頁，玩家按返回永遠回不到 App。加上 NO_HISTORY 讓它開完頁面就結束，返回一次就回到 App。退回開發人員選項的那條路沒有這個問題。
- Shizuku 的做法是開 `Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS`，帶 `":settings:fragment_args_key" = "toggle_adb_wireless"`，系統會捲到「無線偵錯」那一項。把這個參數也加在上面的 intent 上，系統不認得直接開頁時，至少會捲到正確位置。
- 用 `adb shell am start` 測試時，PowerShell 要注意 `$` 的跳脫：在雙引號字串裡用 `` `$ ``，不要用 `\$`，否則 `\` 會被原樣送到手機上，導致找不到 Activity。

**配對期間的前景服務**
- 玩家在系統設定頁配對時，App 在背景。Android 14 以後背景 App 很快會被凍結，所以配對期間要開前景服務（Shizuku 也是這樣做）。
- 服務類型用 `shortService`（Android 14 起）：不需要額外的類型權限，上限約 3 分鐘。比 `connectedDevice` 單純，後者在 Android 14 還要另外宣告前置權限。
- 通知的 RemoteInput 回覆要用 `PendingIntent.getForegroundService`（`FLAG_MUTABLE`）送回服務；服務每次收到指令都要再呼叫一次 `startForeground`。
- 服務用 NsdManager 找 `_adb-tls-pairing._tcp` 取得配對連接埠，玩家只要輸入 6 位數。配對碼經 MethodChannel 交給 Dart，由 `flutter_adb` 的 `AdbPairing.pair` 完成。實測找到連接埠後約 2 秒配對成功。
- **Shizuku 沒有處理 3 分鐘逾時**（沒覆寫 `onTimeout`，「重試」按鈕的程式碼被註解掉了）。我們的做法：確認開發人員選項已開啟後才啟動服務；逾時就停止服務並發通知讓玩家重新開始。

**一鍵恢復與重開機**
- 首次連上 shell 後執行 `pm grant <套件> android.permission.WRITE_SECURE_SETTINGS`。**重開機後授權仍在**；無線偵錯會被系統關掉，但 App 可以自己再打開，約 2.2 秒拿到 shell。
- **NSD 會回傳已關閉的舊連接埠**：無線偵錯重新開啟後連接埠會換，NSD 結果裡舊的記錄還在，而且常排在前面，連過去會 `Connection refused`。要收集約 2 秒內的所有結果，逐一嘗試連線。
- **緊接著開下一個 shell 串流會失敗**：前一個串流剛結束就立刻開下一個，`flutter_adb` 偶爾回 `Stream open failed or refused by remote peer`，稍等再開就正常。指令要排隊執行，失敗時延遲重試一次。實機上連上後的第一條指令常卡滿 10 秒才失敗，所以每條指令前都補足 250 ms 間隔，比事後重試快得多。
- 鳴潮的 `Client.log` 實測將近 10 MB，透過 shell 讀時要只讀新增的部分（`stat -c %s` 取長度，`tail -c +N | head -c M` 取範圍）。

**飛航模式取得網址（鳴潮限定，原神要另外驗證）**
- 這是 WuWa Tracker 教學提供的 Android 手動方式。開飛航模式後進「喚取記錄」，頁面只顯示載入失敗，但長按可以全選複製出看不見的文字，內容是整段錯誤訊息（「網頁無法使用...無法載入位於 <網址> 的網頁...」），裡面有完整網址。
- 所以手動輸入欄位要能從整段文字裡找出網址，不能要求玩家只貼網址。

**WuWa Tracker 的其他方式（參考）**
- Android：上傳 `Client.log`（由網站解碼）、使用 Ascent App（原理同我們的無線偵錯）。
- Windows：執行從 GitHub 下載腳本的 PowerShell 指令，或上傳 `Client.log`。我們的 App 能直接讀檔，不需要叫使用者執行外部腳本。

### 20. 實作後在實機與模擬器才發現的問題（通用，2026-11-06）

**權限與系統限制**
- **要宣告 `ACCESS_NETWORK_STATE`**：沒宣告時 `ConnectivityManager.getNetworkCapabilities` 會丟 SecurityException，判斷 Wi-Fi 的程式回 false，結果被誤判成「沒連 Wi-Fi」。
- **背景 App 的網路會被擋（`APP_BACKGROUND`）**：玩家還在遊戲裡時 App 就讀到網址，此時立刻抓資料會直接 `Failed host lookup`。要等玩家切回本 App（`AppLifecycleListener` 的 resume）才開始抓，等待時畫面提示「請回到本 App」。
- **儲存權限被「不要再詢問」後，再要求也不會跳視窗**（Android 10 以下的直接讀檔）：玩家按「重新授權」時被拒、且 `shouldShowRequestPermissionRationale` 為 false，就改開本 App 的系統設定頁（`ACTION_APPLICATION_DETAILS_SETTINGS`）。**回到 App 時的自動重試只能檢查權限、不能再要求**，否則永久拒絕時每次回來都會再被送去設定頁，玩家連「取消」都按不到。
- **能自動開關的裝置被收回 `WRITE_SECURE_SETTINGS` 後，下次連上會自動補回**（連上 shell 時順便 `pm grant`）。設定頁的配對狀態要在每次讀取結束後重讀，否則開著的設定頁會一直顯示「需手動開啟」。
- **解除配對只能刪掉本機金鑰**：系統「已配對的裝置」清單裡的紀錄 shell 刪不掉，會留著（不影響使用，重新配對也正常）。
- **換到沒允許過的 Wi‑Fi，無線偵錯會被系統擋下**：App 寫入 `adb_wifi_enabled=1` 後，系統立刻改回 0，並跳出「要允許透過這個網路執行無線偵錯嗎？」。玩家按允許前什麼都連不上，所以打開後要約 0.5 秒讀回開關：變回 0 就是這個情況，要提示玩家按允許，而不是說「配對失效、請重新配對」。按允許後是**系統**把開關打開的，重試時不能當成玩家原本就開著，用完要關回去，否則之後每次都會留著。玩家按「取消」也會回到本 App；這時若自動重試，系統視窗會馬上再跳出來，變成關不掉的迴圈。所以只有在開關已經被打開（玩家按了允許）時才自動重試，另外提供「重試」按鈕。
- **重開機後系統會自己恢復無線偵錯（ASUS Android 16 實測）**：重開機前是開的，開機完成時讀到 0，解鎖後幾秒內就自動變回 1，不必開 App。所以開機後第一次更新時 App 看到它已經開著，照「原本開著就保留」的規則處理是對的。
- **沒有 Wi‑Fi 時從通知欄打開 Wi‑Fi 也會自動繼續**：收起通知欄會觸發 Flutter 的 resume，自動重試就會接上，不一定要切出 App 再回來。

**root**
- **root 時每條指令都 `su -c` 會讓 root 工具每秒跳一次授權提示**：改成整次更新只開一個常駐 `su`，指令從 stdin 送進去，以隨機結束標記切出每條指令的輸出。
- **Google APIs 模擬器內建的 `su`（`4750 root:shell`）一般 App 用不了**：SELinux 連 `stat` 都擋，`File('/system/xbin/su').exists()` 回 false，所以會直接略過 root，不會白等授權逾時。要實測真正的 root 讀取，得用 Magisk root 過的裝置或模擬器（例如 rootAVD）。
- **root 授權被拒要說出原因**：有 `su` 但 verify 失敗時（拒絕或倒數結束），結果要帶旗標，等待畫面多一行說明，請玩家到 root 工具的「超級使用者」頁允許本 App。實測：拒絕後出現說明，到 Magisk 改成允許、回到 App，自動重試就改用 root 讀到了。
- **讀 `su` 輸出不能每批都從頭掃**：大檔會分成很多批送來，每批都把整個緩衝區合併再找結束標記會變成平方時間（8 MB 約 20 秒）。只在「上一批結尾＋這一批」裡找，找到完整標記行才合併一次。
- **Magisk 實測（rootAVD 修補的 API 33 模擬器）**：整次更新只跳一次 Magisk 授權，監看沿用同一個 `su`，讀到命中後關閉 session，各卡池抓取正常。Magisk 授權提示約 10 秒倒數，逾時視同拒絕並記成 `policy=1`（拒絕），之後不會再問；要重測得先清掉授權（Magisk App 的「超級使用者」頁，或 `magisk --sqlite "DELETE FROM policies"`）。

**配對與輸入**
- **注音輸入法會把組字中的注音一起送進 RemoteInput**：配對碼只保留數字（`filter { it.isDigit() }`）。
- **橫幅通知幾秒就收起**：玩家來不及點「配對」時要從通知欄拉下來找；教學文字寫「從螢幕頂端往下拉」是對的。
- **「點這裡回到 App」點了不會消失**（2026-11-09 發現）：配對成功的通知沒設 `setAutoCancel(true)`；而且成功後服務還要再跑 4 秒才 `stopForeground(DETACH)`，這段期間它仍是前景服務的通知，系統不會因為點擊就收起。改成成功時先 `stopForeground(STOP_FOREGROUND_DETACH)` 再排 4 秒後結束服務，通知本身加 `setAutoCancel(openApp)`。
- **輸入法的自動校正會改網址**：手動輸入欄位要設 `keyboardType: TextInputType.url`、`autocorrect: false`、`enableSuggestions: false`，否則 `&lang=` 會被改成 `&Lang=`，網址就失效了。

**版面**
- 手機橫向時對話框高度只剩約 390，等待畫面放不下，`AppDialog` 要開 `scrollable: true`。
- 英文標題很長（「Can't read convene history automatically」），標題列 `Row` 裡的文字要包 `Flexible` 才會換行。

**流程（2026-11-09 從 Play 全新安裝後發現）**
- **判斷完讀取方式前，不要顯示「開啟鳴潮」**。原本按下更新就顯示等待畫面與「開啟鳴潮」，同時在背景判斷能不能自動讀取；全新安裝第一次讀加密儲存區（確認有沒有配對金鑰）要產生金鑰，約 2 秒，玩家已經按下按鈕進遊戲，畫面才換成「無法自動讀取，請設定」，要切回來設定再切回去。改成等待狀態多一個 `checkingLogAccess`：判斷中只顯示「正在確認讀取方式...」、進度條與「取消」（不放說明文字和手動輸入，判斷完的兩個畫面都有手動輸入），判斷完才換成「開啟鳴潮」或原因＋「設定讀取方式」；按「重試」重新判斷時也先回到判斷中。代價是已配對的玩家要等連線完成（約 1～3 秒）才看到「開啟鳴潮」，但連線前本來就還沒開始讀記錄。

### 21. 用 adb 測試的小技巧（通用）

- **Git Bash 會把 `/sdcard/...` 轉成 Windows 路徑**：送給 `adb shell`、`adb push` 的裝置路徑前要先 `export MSYS_NO_PATHCONV=1`。
- **假的 `Client.log`**：鳴潮的混淆規則是明文位元組為偶數就 XOR `0xA5`、奇數就 XOR `0xEF`，用這個規則就能自己產生測試檔。推到 `/sdcard/Android/data/<遊戲套件>/files/UE4Game/Client/Client/Saved/Logs/Client.log`，再用 `cat hit.log >> Client.log` 模擬遊戲寫入新網址。
- **`adb shell input text` 會受輸入法影響**：注音輸入法下數字會變成注音符號，要先切到數字鍵盤再點按鍵。`&` 在裝置 shell 的雙引號內不需要跳脫，加了 `\` 會被原樣輸入。
- **ROG 手機閒置時可能自動進入「鎖定觸控模式」**，要雙指上滑才能解除，adb 做不到，需要人工操作。
- **Android 13 模擬器要用 `-gpu host` 啟動**：用 `swiftshader_indirect`（即使加 `-feature -Vulkan`）時，一打開 Flutter App 模擬器就會 Segmentation fault；API 28／29 沒有這個問題。
- **用 `settings put global development_settings_enabled 1` 開開發人員選項不完整**：設定 App 不會啟用開發人員選項相關的頁面，直接跳轉會找不到 Activity。測試時要用正規方式（連點版本號碼 7 次）。

---

## 七、手機版面（子專案 3）

設計：`docs/superpowers/specs/2026-11-06-mobile-layout-design.md`。原則是**和桌面版一致，只做 RWD 和觸控調整**，不另做一套手機 UI。

### 22. 什麼時候切成手機排版（通用）

- 判斷集中在 `isCompactLayout()`（`lib/theme/layout.dart`），門檻 600 dp。**手機作業系統看短邊**，轉向時不會在兩種排版間跳來跳去，橫向仍是手機排版；**電腦作業系統只看寬度**，寬而矮的筆電視窗維持側欄，只有把視窗拉窄才切換（Windows 縮小視窗也能用手機排版，算是附帶好處）。
- Windows 最小視窗寬度從 800 降到 360，才拉得到手機排版。
- 個別元件依「自己拿到的寬度」切換（`LayoutBuilder`，例如紀錄表格在 600 dp 以下改成卡片、搜尋框獨占一行），不是看整個畫面。

### 23. 各元件的手機版做法（通用）

- **導覽**：側欄改成抽屜（漢堡選單），項目高 48 dp。標題列只留 ☰、帳號選單和更新鈕（改成圓形圖示鈕）；App 圖示、名稱和版本號移到抽屜頂部，跟著清單捲動。抽屜高度不到 600 dp（手機橫向、分割畫面）時，「貢獻者／設定」不固定在底部，跟著清單一起捲，否則會壓縮中間的清單。底部狀態列直向橫向都顯示，只隱藏團隊名稱和分隔線，按鈕 48 dp。
- **返回鍵**：側欄／抽屜切換的頁面是同一層，原本每一頁按返回都直接關掉 App。改成：抽屜開著先關抽屜；不在綜合頁就回綜合；在綜合頁才交給系統離開。外殼 `PopScope` 的 `canPop` 只在「綜合頁且抽屜關著」時為 true，其餘在 `onPopInvokedWithResult` 處理，Android 13 起的預測返回動畫只在真的要離開時出現。不照瀏覽紀錄倒退（同層頁面來回切幾次就要按很多下才離得開），也不跳「確定離開？」對話框（Android 不建議攔截返回，也會破壞預測返回）。不限手機排版，Android 平板的側欄排版一樣適用；電腦版沒有系統返回鍵，不受影響。`app_shell_test` 用手機與平板寬度鎖住。
- **紀錄表格**：窄寬度改成卡片列表，每張卡顯示名稱、類型、稀有度、時間（相對時間）、總抽數、保底內；排序改成「排序：xxx」按鈕叫出底部面板。
- **對話框**：`AppDialog` 在手機上邊距 12 dp。物品詳情在手機橫向改成左右兩欄（左：說明與造型說明，右：立繪），避免立繪被壓扁。
- **看圖**：觸控單擊不做事（避免誤觸），雙擊放大／還原，雙指縮放，長按叫出選單（取代右鍵），未放大時往下滑關閉。滑鼠行為維持桌面版（單擊縮放、右鍵選單）。
- **觸控目標**：所有可點的東西至少 48 dp（捲動箭頭、拖曳把手、底部狀態列按鈕等），畫面上可以畫得比較小，但點擊範圍要夠。
- **提示框**：Flutter 的 `Tooltip` 在觸控下預設是長按。點了沒有其他動作的（相對時間、時間軸節點與日期）在手機上改成點一下顯示（`tapTooltipTrigger()`）；外層本身可點的（例如勾選列裡的時間、會開詳情的紀錄卡片）維持長按，否則提示框會搶走那個點擊。
- **安全區（開孔鏡頭、手勢列）**：Android 15 起 App 一律延伸到全螢幕（edge-to-edge），`Scaffold` 只幫 `AppBar` 避開安全區，`body` 不會。原則是**內容全部避開安全區，只有背景色延伸到螢幕邊緣**：內容區包 `SafeArea(top: false, bottom: false)` 避開橫向的開孔鏡頭；底部狀態列的背景色延伸到底，裡面的文字和連結包 `SafeArea(top: false)` 避開手勢列。抽屜、底部面板、浮動提示要自己包 `SafeArea`；`showDialog` 預設 `useSafeArea: true`（看圖、詳情都在內），SnackBar 和彈出選單 Flutter 會自己處理。實測 ROG Phone 的開孔在橫向時位於左或右側，兩個方向都要看。
- **抽屜開著時把視窗拉寬再縮回，抽屜會自己開著出現**：抽屜被拿掉時 Scaffold 仍記得「開著」。拉寬時先保留抽屜、關好再拿掉。
- **文字會變長**：日文、英文和放大字級（1.3 倍）下都要測，單行資訊用一段 `Text.rich` 加省略號，不要用多個 `Text` 排一列。

### 24. 實機才發現的問題（通用，2026-11-06，ASUS ROG Phone 1080×2400）

- **抽屜開著按返回會直接離開 App**：Android 16 的預測返回只看頁面堆疊，抽屜不是一個頁面，所以系統以為可以直接結束。要用 `PopScope` 在抽屜開著時宣告「由 App 處理返回」，收到後關抽屜。
- **底部面板跑到標題列和狀態列下面**：頁面放在 go_router `ShellRoute` 的巢狀 Navigator 裡，`showModalBottomSheet` 要加 `useRootNavigator: true` 才會蓋住整個 App。
- **橫向開鍵盤後內容幾乎看不到**：橫向高度只剩約 390 dp，鍵盤再占掉一半，底部狀態列也還在。鍵盤開著（`viewInsets.bottom > 0`）時隱藏底部狀態列。
- **關掉對話框後鍵盤又跳出來**：Flutter 在手機上點文字欄位外部**不會**收焦點（桌面會）。按返回收起鍵盤後欄位仍有焦點，之後開任何對話框再關掉，焦點回到欄位、鍵盤就跳出來；「失焦才儲存」的帳號別名欄位也因此一直沒存。處理：在 `MaterialApp.actions` 覆寫 `EditableTextTapOutsideIntent`，任何裝置點外部都收焦點（`appActions`）。
- **滑鼠按久一點會叫出長按選單**：長按只給觸控與觸控筆（`GestureDetector(supportedDevices: ...)`），否則桌面上按住再放開會跳選單而不是縮放。
- **`InteractiveViewer` 開了雙指縮放，滑鼠滾輪也會一起縮放**，而且每一格疊加到約 1.8 倍：設 `scaleFactor: double.infinity` 關掉它自己的滾輪縮放，保留我們原本的滾輪處理。
- **帳號選單被壓窄**：手機上標題列的帳號按鈕很窄，選單預設跟按鈕一樣寬，別名和 UID 都被截掉。改成至少和按鈕一樣寬、最多 336 dp。

### 25. 測試手機版面的方法（通用）

- 用 `TargetPlatformVariant.only(TargetPlatform.android)` 指定平台；直接設 `debugDefaultTargetPlatformOverride` 再 `addTearDown` 還原，會在測試結束的檢查時失敗。
- 字級用 `tester.platformDispatcher.textScaleFactorTestValue`，鍵盤用 `tester.view.viewInsets = FakeViewPadding(bottom: ...)` 模擬。
- `tester.takeException()` 只回傳溢出的摘要，看不出是哪個元件；要找來源時先拿掉 `takeException`，讓測試印出完整的 render tree。
- 實機轉向：`adb shell cmd window user-rotation lock 1`（橫向），測完用 `cmd window user-rotation free`，並把 `settings` 的 `accelerometer_rotation` 改回 1。只改 `settings put system user_rotation` 有時不會立刻轉。

---

## 八、檔案存取與分享（子專案 4）

設計：`docs/superpowers/specs/2026-11-06-file-access-and-sharing-design.md`。桌面版行為不變；手機在「儲存」之外多一個「分享」（分享圖、物品圖、日誌、備份）。

### 26. 換成 `file_picker`＋`share_plus`（通用）

- **`file_selector` 在 Android 沒有實作「另存新檔」**（`getSaveLocation` 直接丟例外），匯出備份、匯出日誌、另存圖片在手機上全部不能用。改用 `file_picker` 統一處理開檔、選資料夾、存檔，兩個平台同一段程式；分享用 `share_plus`（可直接分享記憶體中的資料，不用先存檔）。
- 所有存檔／分享／複製集中在 `lib/services/file_access.dart`，原本物品圖與分享圖兩份重複的存檔程式一併合併。
- **讀檔自己用 `utf8.decode`**：不依賴套件的字串讀取（`#14` 的中文亂碼就是套件讀字串造成的），不合法的 UTF-8 走既有的「無法讀取」訊息。

### 27. `file_picker` 在 AGP 9 編不過（通用）

- `file_picker` 11.0.3 偵測到 AGP 9 就**假設 AGP 內建 Kotlin 會編它**，自己不套 Kotlin 外掛、也不設 `jvmTarget`。但 Flutter 範本的 `android.builtInKotlin=false`，結果沒人編它的 Kotlin，建置報 `FilePickerPlugin` 找不到。
- **不能直接改 `builtInKotlin=true`**：實測還有 `device_info_plus`、`package_info_plus`、`share_plus`、`shared_preferences_android`、`url_launcher_android` 會自己套 Kotlin 外掛，改了就換它們壞（專案在 E 槽、pub cache 在 C 槽時報「different roots」）。
- 處理：`android/file_picker_kotlin_shim.gradle` 只替 `file_picker` 補套 Kotlin 外掛並把 Kotlin `jvmTarget` 對齊 Java 17（不對齊會報「Inconsistent JVM Target Compatibility」）。上游修好後刪除。

### 28. 實測發現（通用，2026-11-06）

- **`file_picker` 存檔回傳的是字串**，不是 Uri。Android 回傳的是 `content:` Uri 的 path 部分（例如 `/document/primary:Download/a.json`，下載資料夾的 provider 則是 `/document/msf:1234`），**沒有 scheme**，所以要依平台判斷，不能看字串長相；檔名取最後一段、副檔名不符就顯示建議檔名。Android 存檔後沒有可開啟的路徑，成功訊息只顯示檔名、不放「開啟資料夾」。
- **Windows 存檔對話框有兩處和 `file_selector` 不同**：標題預設是英文「File Picker」（已用 `dialogTitle` 改成在地化的「另存新檔」）；「存檔類型」的名稱寫死成「Files (*.json)」（原本是「JSON (*.json)」），使用者接受此差異。預設檔名、覆蓋確認、實際寫入都一樣。
- **`super_clipboard` 在 Android 複製圖片要宣告 content provider**（`com.superlist.super_native_extensions.DataProvider`，authority 用 `${applicationId}.SuperClipboardDataProvider`）；補上後複製會出現系統剪貼簿預覽。
- Android 開檔的副檔名篩選有效：系統選檔畫面中非 JSON 檔是灰色不可選。
- 「分享」「儲存」是否出現看 `isAndroidProvider`，不看螢幕寬度：Windows 視窗拉窄時仍是桌面行為。
- **Windows 對話框要傳 `lockParentWindow: true`** 才會像 `file_selector` 一樣歸屬於應用程式視窗（強制在前、模態）；開檔與選資料夾對話框的標題同樣預設是英文「File Picker」，要另外傳在地化的 `dialogTitle`（`dialogOpenTitle`、`dialogSelectFolderTitle`）。
- **`file_picker` 在 Windows 的 isolate 遇到檔名含 `<>:"/\|?*` 會丟例外，而且 `await` 永遠不會完成**（存檔看起來像卡死），所以建議檔名一定要先把這些字元換成 `_`。
- **暫存檔殘留**：`share_plus` 的 `XFile.fromData` 會在暫存目錄留下 `<uuid>/<檔名>` 的副本，不會被刪除，所以改成自己把 bytes 寫到 `getTemporaryDirectory()/share_out/<檔名>`（寫前先刪掉上一次的 `share_out`），再用 `XFile(path)` 分享，暫存目錄最多只殘留一個分享檔；`file_picker` 在 Android 即使 `withData: true` 也會把選到的檔案複製到 `cache/file_picker/...`，現在讀完 bytes 後會呼叫 `FilePicker.clearTemporaryFiles()` 清掉（只限 Android，Windows 的預設實作會丟 `UnimplementedError`）。


## 九、雲端同步登入（子專案 5）

設計：`docs/superpowers/specs/2026-11-06-android-cloud-sync-login-design.md`。手機和 PC 讀寫同一份雲端硬碟同步檔，只有登入那段依平台分流；同步本體共用。

### 29. 只走「授權」，不走「登入」（通用，2026-11-06 實機驗證）

- `google_sign_in` 7.x 在 Android 有兩套介面：「登入」（`authenticate()`，用 Credential Manager 拿身分證明）與「授權」（`authorizationClient`，拿存取 Google 資料的通行證）。**我們只用授權**：`GoogleSignIn.instance.initialize()` 不帶參數，直接 `authorizationClient.authorizeScopes([drive.appdata, email])`，email 再用通行證呼叫 userinfo 取得（PC 版本來就是這樣取 email）。
- **走「登入」必須另建「網頁應用程式」類型用戶端**，把它的 ID 當 `serverClientId`（Credential Manager 預設 App 背後有伺服器）。實測拿桌面用戶端 ID 去填會得到 `GoogleSignInException unknownError: [28444] Developer console is not set up correctly.`。我們沒有伺服器，用不到身分證明，所以不走登入、也不建網頁用戶端。
- **Android 用戶端的 ID 不放進程式**：Google Play 服務以「套件名稱＋簽章 SHA-1」到專案裡找對應的 Android 用戶端。查證方法：用 `https://oauth2.googleapis.com/tokeninfo?access_token=...` 看通行證的 `azp`／`aud`；前段專案編號與桌面用戶端相同、後段不同，就是 Android 用戶端發的。
- 啟用條件沿用 `CLOUD_SYNC_CLIENT_ID`：沒帶 `secrets/cloud_sync_defines.json` 的建置，手機和 PC 一樣停用雲端同步（程式用不到這個 ID，只當「正式建置」的開關）。

### 30. 授權是整個 Cloud 專案共用一份（通用）

- 同一個 Google 帳號對同一個 Cloud 專案只有**一份授權**，PC（桌面用戶端）和手機（Android 用戶端）共用。實測：手機第一次授權時連授權畫面都沒跳，直接沿用 PC 給過的授權；手機向 Google 撤銷後，**PC 也變成「需要重新連結」**。
- 所以兩個平台的「中斷連結」都改成**只忘記本機**（使用者 2026-11-06 決定）：Windows 只刪本機 refresh token；Android 清掉快取的通行證並 `signOut()`。Windows 原本「取消後遲到的授權」與「授權缺 Drive 權限」兩處的撤銷也一併拿掉，避免波及其他裝置。想徹底取消授權的玩家可到 Google 帳戶設定移除。
- appDataFolder 也是以 Cloud 專案區分：Android 用戶端必須建在桌面用戶端**同一個專案**，否則手機和 PC 會各自看到不同的同步檔。

### 31. Play 服務會快取已失效的通行證（通用）

- 撤銷授權後重新授權，Play 服務把**舊的、已撤銷的通行證**交回來，API 回 401（`Request had invalid authentication credentials`）。必須 `clearAuthorizationToken(accessToken:)` 清掉快取再要一次才會拿到新的。
- 處理：Android 拿到通行證後先用 userinfo 驗證，遇到 401 就清快取、重取一次；靜默還原重取不到就進「需要重新連結」。
- 通行證約 1 小時過期、App 無法自己續期，所以 Android 每輪同步都重新靜默取得通行證，不沿用上一輪的 client。
- **使用者取消不是 `canceled`**（2026-11-06 實測）：在帳號選擇畫面按返回，`google_sign_in_android` 7.2.18 不看 Activity 的 resultCode，回報的是 `GoogleSignInException(unknownError, "SDK reported an exception: 16: [16] Cancelled by user.")`（Play 服務狀態碼 16 = `CANCELED`）。所以判斷取消要同時認 `canceled` 與「`unknownError` 且狀態碼 16」，否則畫面會顯示「授權失敗」。log 會記下完整的 code 與 description，方便分辨是取消還是設定錯誤。
- 「只忘記本機」（清快取＋`signOut()`）之後，靜默授權拿不到通行證；再授權時會跳出帳號選擇，可以換帳號。App 完全關掉再開，靜默授權直接拿得到通行證，不必重新連結。

### 32. 簽章指紋要逐把登記（通用）

- Android 用戶端以「套件名稱＋SHA-1」辨識 App，同一個 App 可能有三把金鑰，每把都要在 Android 用戶端登記一筆：
  - 開發用 debug 金鑰：`F8:09:DC:34:0C:1C:D5:92:C5:0A:44:8E:0B:DB:1C:96:8D:30:08:1B`（`~/.android/debug.keystore`，已登記）。
  - **上傳金鑰、Play 應用程式簽署金鑰：子專案 7 必須回來補登記**（Play 簽署金鑰的 SHA-1 在 Play Console 查）。只登記 debug 金鑰時實機測試一切正常，但從 Play 下載的版本授權會失敗。依套件原始碼推論（未實測），會回報成 `GoogleSignInException(unknownError, "SDK reported an exception: 10: ...")`（Play 服務狀態碼 10 = `DEVELOPER_ERROR`），畫面顯示「授權失敗」。

### 33. 實機驗收結果（2026-11-06）

- **ROG Phone**：連結成功（專案已有授權時不跳任何畫面）。App 強制關閉後重開會自動同步，不必重新連結。手機中斷連結後 PC 照常同步；再連結時會跳出帳號選擇。
- **模擬器（Android 13，Google API 映像）**：在帳號選擇畫面按返回會回到「連結 Google 帳號」按鈕，不顯示「授權失敗」。全新裝置連結後，PC 的 3 個帳號都同步下來，並自動補抓 114 張物品圖片。**同一個 App 程序開 63 分鐘後按「立即同步」仍成功**，通行證過期後由 Play 服務自動換發。
- **Windows**：加入 `google_sign_in` 後仍可建置（套件沒有 Windows 實作，只是不被呼叫）。中斷連結 log 為 `signOut done (local only)`，模擬器照常同步；重新連結（瀏覽器授權）正常。
- 未實測：在 Google 帳戶設定撤銷 App 存取權後的反應。因為授權是整個專案共用，撤銷會讓所有裝置都需要重新連結，所以只用單元測試涵蓋（快取的失效通行證：清掉重取，重取不到就進入「需要重新連結」）。
- **舊版 Play 服務不支援清除快取憑證**：模擬器（Play 服務 23.18）呼叫 `clearAuthorizationToken` 會丟 `PlatformException(clearAuthorizationToken failed, Missing Feature{name=auth_api_credentials_clear_token ...})`，而且要好幾分鐘才回來。所以中斷連結與「失效憑證清掉重取」都把清除當成盡力而為：失敗只記警告，流程照常進行。實機的 Play 服務會自動更新，不受影響。
- **測完記得中斷模擬器的連結**：模擬器登入真實 Google 帳號並連結後，之後在模擬器做清除資料、移除帳號這類測試，刪除會同步到雲端，PC 和手機也會跟著少掉紀錄。2026-11-06 測完已在模擬器 App 中斷連結（只清本機）。另外，模擬器關機會存快照，重開後是從原狀態繼續跑，不是全新啟動。

---

## 十、Play 上架與更新（子專案 7）

上架步驟、商店頁文字、資料安全表單與審查說明不公開，放在本機不進版控的 `private/play-store/`；隱私權政策要給 Play 公開網址，留在 `docs/privacy-policy.md`。這一節只記技術決定與踩雷。

### 34. 版本代碼只給 Android 用（通用）

- Play 的版本代碼必須遞增且不能重複；預覽版也要排在正式版前面。公式：`MAJOR × 1,000,000 ＋ MINOR × 10,000 ＋ PATCH × 100 ＋ 尾碼`，正式版尾碼 99、`-rc.N` 尾碼 N（1–98）。例：`1.9.0-rc.2` → `1090002`，`1.9.0` → `1090099`。
- 換算寫成 `lib/services/android_version_code.dart`，App（反推 Play 回報的版本）與 CI（`tool/android_version_code.dart`）共用同一份規則。
- tag 的每一段數字都不接受前導零（`v01.9.0` 會和 `v1.9.0` 算出同一個代碼），MAJOR 最大 2099（Play 版本代碼上限是 2,100,000,000）；不合法一律失敗。
- **Windows 照舊用 workflow 的執行序號**：Windows 版本資源的每一欄上限是 65535，放不下這個公式的數字。所以版本代碼只在 Android 建置時用 `--build-number` 傳入，不寫回 `pubspec.yaml`。
- `dart run` 的「Running build hooks...」提示走 stderr，CI 解析 stdout 不受影響；保險起見 workflow 仍只擷取 `VERSION_CODE=`／`BUILD_NAME=` 兩行。

### 35. release 簽章與 CI（通用）

- `android/app/build.gradle.kts` 讀 `android/key.properties`（`android/.gitignore` 已排除它與 `*.jks`）；檔案不存在時 release 退回 debug 金鑰，`flutter run --release` 照常能用。
- Gradle Kotlin DSL 裡寫 `java.util.Properties()` 會編不過：`java` 被解析成 Gradle 的 `java` 擴充。要在檔頭 `import java.util.Properties`。
- **Windows 與 Android 在同一份 `release.yml`**：觸發一次、輸入一個 tag，`build-android` 以 `needs: build-windows` 等 Windows 跑完，並 checkout Windows 記下的發版 commit（job output `release_sha`），兩邊一定建置同一份程式碼。原本分成兩份流程，要觸發兩次、順序不能錯，而且 Android 抓的是執行當下的 master，兩次之間有人推 commit 就會建出不同版本。Android 失敗不影響已建好的 Windows 草稿，修好後按「Re-run failed jobs」只重跑 Android。
- Android job：缺任何一個金鑰或服務帳戶 secret 就失敗；建置後再用 `keytool -printcert -jarfile` 檢查 AAB，若是 debug 金鑰簽的就失敗。上傳用 `r0adkll/upload-google-play`，只上 internal 軌道、不填「新功能」。
- **從來沒推出過任何版本的 App，API 只能建立 draft 狀態的版本**（錯誤訊息「Only releases with status draft may be created on draft app」）。第一版本來就要在 Play Console 手動上傳，手動上傳後在 Console 推出（內部測試也算），之後 CI 就固定送 `completed`，不提供 draft 選項：內部測試只有測試名單看得到，直接推出才能在升級正式版前，用手機從 Play 收到經 Play 簽署的版本，先確認 Google 登入等依賴簽章的功能。
- secrets 一覽與每次發版步驟見本機的 `private/play-store/README.md`。
- **首次上架實際走過的流程與坑**（2026-11-09）：
  - 在 Play Console 建立 App 時**不填套件名稱**，第一次上傳 AAB 時才由檔案決定，之後不能改；「Play 應用程式簽署」也在第一次上傳時自動啟用。
  - **預設語言選英文**：沒有翻譯的語言地區會看到預設語言的商店頁，鳴潮玩家遍及全球，英文比繁中合適；每次發版的「新功能」至少要填預設語言那份。之後可在「管理翻譯」更換。
  - 第一版用 `-rc.1`（例如 `1.9.0-rc.1` → `1090001`）：只用掉這一版保留給內測的版本代碼，正式版尾碼 99 一定比所有 rc 大，測試人員之後會自動收到正式版更新。
  - 推出後內部測試狀態是「提供給內部測試人員」「尚未審查」（內部測試本來就不審查）。**剛推出的幾分鐘內安裝會失敗**（logcat：`Delivery received non-OK response 2`、`statusCode:1010`），是伺服器還沒開始提供下載，等一下再裝即可。
  - **`adb install` 會裝進手機上所有使用者空間**（私人空間、廠商的分身空間等）。只在主要空間解除安裝後，Play 會以「其他使用者已經在這裝置安裝不相容版本」拒絕安裝；要用 `adb shell pm uninstall --user <id> <套件>` 逐一清掉（`pm list users` 看有哪些空間）。之後本機測試版一律 `adb install --user 0`。
  - 服務帳戶在 Play Console 只給「查看應用程式資訊（唯讀）」與「將應用程式發布至測試群組」，**不給「發布正式版」**：CI 就算出錯也發不到正式版。Cloud 端不給任何專案角色，只要啟用 Google Play Android Developer API。
  - 2023 年 11 月之後註冊的個人開發者帳號，發正式版前要先跑 12 人、連續 14 天的封閉測試（本專案帳號不受此限）。
- **rc 版手動發、正式版走 CI**：rc 在本機建 AAB 後用 `tool/play_upload_internal.py <服務帳戶 JSON> <aab> <版本名稱>` 上傳並推出到內部測試（只靠 `cryptography` 簽 JWT 換權杖，不需要 Google 的 API 套件；流程是建立編輯 → 上傳 → 設定 internal 版本為 completed → 提交，失敗會刪掉編輯）。手動上傳過的 rc 已用掉版本代碼，CI 的 `release.yml` 只拿來發正式版 tag，不會撞號。第一次用它上傳成功，也順便證明服務帳戶權限正確（CI 用同一個帳戶）。
- 修改 workflow 後用 actionlint 檢查（`go run github.com/rhysd/actionlint/cmd/actionlint@latest .github/workflows/*.yml`）。
- **actionlint 抓到 `ci.yml` 的既有問題**：自動提交 ARB 正規化的步驟把 `${{ github.head_ref }}` 直接拼進 shell，分支名稱裡的 `$(...)` 會被當成指令執行。改成 `env: HEAD_REF: ${{ github.head_ref }}`，指令裡用 `"$HEAD_REF"`。原神版的 `ci.yml` 是同一份底稿，要一起檢查。
- **內部測試不用審核**：推出後通常幾分鐘內測試人員就能更新（第一次發布後的測試連結可能要等幾小時）；升級到正式版才進入審核。2023 年 11 月之後註冊的個人開發者帳號，發正式版前還要先跑 12 人、連續 14 天的封閉測試，本專案的帳號不受此限。

### 36. 簽章指紋：每把金鑰各建一筆 Android 用戶端（通用）

- 接續 #32：Google Cloud 的 Android OAuth 用戶端一筆只能填一個 SHA-1，所以 debug、上傳金鑰、Play 應用程式簽署金鑰各建一筆（套件名稱相同、同一個專案）。
- **玩家從 Play 下載的版本是用 Play 應用程式簽署金鑰簽的**，SHA-1 要到 Play Console「應用程式完整性」頁複製，不是上傳金鑰的。沒登記時，Play 版的雲端同步會顯示授權失敗；登記後本專案幾分鐘內就生效。
- **Play 簽署金鑰不只一張憑證**（2026-11 新建的 App 實測）：Play 版 APK 除了 v2／v3 簽章（API 24 以上），還有一組只給 Android 17（API 37）以上用的混合後量子簽章（v3.2，區塊 ID `0x70e1c89f`），裡面是**另外兩張憑證**。Play Console「應用程式簽署」頁把它列在「先前的應用程式簽署金鑰」並標「支援量子金鑰（Beta 版）」，按「複製所有憑證指紋」會一次給出三個 SHA-1。Android 17 手機回報哪一張還沒實測，三張都各建一筆 Android 用戶端（多登記沒有副作用）。
- **JDK 21 的 `apksigner` 讀不了 Play 版 APK**：遇到 v3.2 會報 `ML-DSA KeyFactory not available`。加 `--min-sdk-version 32 --max-sdk-version 36` 只驗 Android 16 以下的簽章，就能讀出傳統那張。要看全部憑證用 `tool/apk_signer_certs.py`：直接解析 APK Signing Block、取出憑證算 SHA-1，不驗簽所以不需要新演算法；結果和 Play Console 的「複製所有憑證指紋」逐一相符。
- Play Console 的選單位置常改版，找不到「應用程式簽署」頁時，先從手機上已安裝的 Play 版讀（`adb shell pm path --user 0 <套件>` → `adb pull` → `tool/apk_signer_certs.py`），兩邊的值一樣。

### 37. 應用程式內更新（通用）

- Android 的「有沒有新版」以 Play 為準（`in_app_update` 的 `checkForUpdate`），而不是 GitHub：Play 上架有審核與分階段推出，GitHub 有新版不代表玩家已經能從 Play 下載。
- `in_app_update` **不提供版本說明**，所以說明仍取自 GitHub Release，只顯示「目前版本之後、Play 版本以內」的項目。GitHub 查不到（包括 TLS 錯誤這類不是一般網路錯誤的例外）時照樣提示有新版，內容顯示「無法取得更新內容」；Play 的版本在 GitHub 還沒發佈說明時，也會在既有說明上方顯示這句提示。
- 不是從 Play 安裝的版本（`flutter run`、側載），`checkForUpdate` 會丟例外：啟動時的自動檢查安靜略過，手動檢查顯示原因。
- 彈性更新：按「更新」後背景下載，完成時跳出不會自動消失的「重新啟動」提示（`SnackBar.persist`）；提示被滑掉後，再開更新對話框按「更新」會直接安裝。
- **in_app_update 5.0.0 的幾個坑**（讀外掛 Kotlin 原始碼確認）：
  - `startFlexibleUpdate` 只在幾種情況回覆：下載完成、安裝出錯、確認畫面按拒絕。確認畫面按同意不會回覆（要等下載完）；流程根本沒啟動時（已經下載好、不允許彈性更新），以及從通知列取消下載（狀態 CANCELED、錯誤碼 NO_ERROR）時，Future **永遠不會完成**。所以呼叫前要先 `checkForUpdate` 判斷（已下載就直接進入「已下載」，不允許就當失敗），下載期間還要同時監聽安裝狀態串流，收到取消或失敗就自行結束。
  - 安裝狀態的事件串流只有在**這次執行中呼叫過 `startFlexibleUpdate`** 之後才會送事件。重開 App 時若下載還在背景進行，只能等下一次檢查才知道結果。
  - 重開 App 時，之前觸發的更新會回報成 `developerTriggeredUpdateInProgress`（不是 `updateAvailable`），要一併當成有更新，並依 `installStatus` 接續：已下載就直接跳「重新啟動」提示。
  - `completeFlexibleUpdate` 成功時 App 直接重啟、從不回覆，所以只有前置條件錯誤會以例外回來。
- **取消與失敗分開處理**：玩家在確認畫面按拒絕、或從通知列取消下載，都視為玩家的選擇，不顯示任何提示；真正的失敗（外掛錯誤、不允許彈性更新）才顯示「目前無法在 App 內更新，請到 Google Play 更新」並附「前往 Google Play」。
- **測試方式**：Play Console 的「內部應用程式分享」可以上傳任意版本代碼，不會用掉正式的版本號。從舊版的分享連結安裝，再分享一個版本代碼較大的版本，舊版開啟時就會偵測到更新。要特別測：下載完成後滑掉提示再重開 App、下載途中關掉 App 再重開、從通知列取消下載。
- 預覽版只放內部測試、不要升級正式版：App 查 GitHub 更新說明時會略過預覽版。
- **下載中要有進度**（2026-11-09 rc.1 → rc.2 實機發現）：按下 Play 確認視窗的「更新」後回到 App，到「已下載完成」提示出現之前完全沒有畫面回饋（11 MB 約 5 秒，網路慢更久），看起來像沒反應。`in_app_update` 只轉出安裝狀態、沒有位元組數，所以另寫 `PlayUpdateProgressChannel`（EventChannel）自己向 `AppUpdateManager` 註冊 `InstallStateUpdatedListener`，送出 `bytesDownloaded`／`totalBytesToDownload`；app 模組要自己加 `com.google.android.play:app-update` 依賴（外掛的是 `implementation`，不會傳給 app）。進度是以廣播送給整個 App，不必是開始下載的那個 manager 也收得到。畫面是常駐 SnackBar：「正在下載新版本...」＋百分比＋進度條＋「已下載／總大小」，總大小未知時是不確定進度條；下載完成、失敗或拒絕時只關掉這一條（保存 `showSnackBar` 回傳的 controller，不用 `hideCurrentSnackBar`，以免關錯別的提示）。實機（rc.4 → rc.5，10.6 MB）：Play 確認視窗關掉約 0.5 秒後先出現不確定進度條，接著 2% → 20% → 77% → 100%，再換成「重新啟動」。
  - **要看到新的更新畫面得連發兩版**：畫面是由「目前裝著的版本」顯示的，所以先發含修正的版本讓手機更新上去，再發一版才測得到。Play 版本代碼不能往回退，錄影失敗只能再發下一個 rc。

### 38. 自適應圖示（通用）

- 只放傳統 `ic_launcher.png` 的話，新版啟動器會把它縮小放進白底圓形。`tool/generate_app_icons.dart` 另外產生 `mipmap-*/ic_launcher_foreground.png`，`mipmap-anydpi-v26/ic_launcher.xml` 指向前景與 `@color/ic_launcher_background`。
- 主體幾乎佔滿原圖、背景又是漸層，去背不可靠，所以前景層是**整張圖縮進中央 72dp 可見區，外圍用邊緣像素延伸到 108dp**，啟動器做視差位移時也不會露出接縫。比例用圓形與方圓形遮罩的預覽圖決定。
- 配對通知的小圖示沿用 `R.mipmap.ic_launcher`。Android 8.0 把自適應圖示當通知小圖示有已知崩潰，但無線偵錯配對只在 Android 11 以上出現，碰不到。

### 39. 系統自動備份要排除加密儲存（通用）

- manifest 沒設定 `allowBackup` 時預設為開啟，Android 會把 App 資料備份到玩家的 Google 帳號，重裝或換手機時自動還原。喚取紀錄能還原是好事，但 `flutter_secure_storage` 的值是用綁在裝置上的 Keystore 金鑰加密的，還原到另一台裝置後讀不出來。
- 處理：保留備份，但用 `android:fullBackupContent`（Android 11 以下）與 `android:dataExtractionRules`（Android 12 以上，雲端備份與裝置轉移兩段）排除 `flutter_secure_storage` 寫的 SharedPreferences 檔。檔名要看實際使用的套件版本原始碼（10.3.1 是 `FlutterSecureStorage`、`FlutterSecureKeyStorage`、`FlutterSecureStorageConfiguration` 等），不要用猜的。
- 隱私權政策與資料安全表單要寫明系統備份這件事，否則和「資料只存在裝置上」的說法矛盾。

### 40. Windows 解除安裝要清掉根憑證（通用，Windows）

- 這不是 Android 的問題，但在寫隱私權政策時發現：Windows 版的解除安裝程式原本只刪資料資料夾，App 產生的根憑證仍留在「目前使用者」的信任清單，私鑰也留在 `%APPDATA%\wuthering_waves_convene_gacha_analyzer\ca`。拿到這把私鑰就能偽造任何網站的身分。
- 處理：`installer.iss` 的 `RemoveCaArtifacts` 在解除安裝最後**一定**執行（不受「是否刪除資料」影響）：先 `certutil -user -delstore Root "<CN>"`（Windows 會跳出確認視窗，玩家按「是」才會刪），再刪掉 `ca` 資料夾；就算玩家拒絕刪憑證，私鑰也已經不在，留下的憑證無法拿來偽造。
- **呼叫 certutil 不可用 `SW_HIDE`**：確認視窗是 certutil 第一個顯示的視窗，會套用啟動時的隱藏設定，玩家看不到它，解除安裝就會一直等。靜默解除安裝（`/VERYSILENT`）也一樣會停在這個系統視窗。憑證名稱與路徑必須和 `rust/src/ca.rs` 的 `EXPECTED_CN`、`ca_dir()` 一致。原神版的解除安裝程式應該也有同樣的問題。


---

## 十一、流暢度與畫面停住

### 41. 165Hz 手機上的「頓頓的」（通用）

- **先確認不是 debug 版**：debug 版是邊跑邊編譯（JIT），一定會卡，剛打開時尤其明顯。判斷方法：APK 裡有 `assets/flutter_assets/kernel_blob.bin`，就是 debug 版。效能一律用 profile 版看（`fvm flutter build apk --profile`，`adb install -r` 蓋過去，資料會保留）。
- **量法**：`tool/measure_frame_pacing.sh`（`.gitattributes` 讓 `*.sh` 固定用 LF；在加入這條規則之前就 checkout 的工作區，要重新取出 `.sh` 檔才會變成 LF，否則 bash 會因 `
` 報錯） 讀 SurfaceFlinger `--latency` 的實際上屏時間，只統計放手後的慣性滑動。adb 注入的拖曳事件取樣不足，量拖曳期間會讓輕量頁面也出現假的「晚一拍」（設定頁拖曳量到 69%，慣性滑動實為 99%）。想知道每幀時間花在哪，用 logcat 的 `The Dart VM service is listening on ...` 取得位址，`adb forward` 後經 VM Service 的 `setVMTimelineFlags`／`getVMTimeline` 抓 timeline，看 `Animator::BeginFrame` 底下的 `SEMANTICS`、`PAINT`，以及 raster 執行緒的 `Rasterizer::DoDraw`。
- **根因一：無障礙服務會讓 Flutter 每幀都更新語意樹**。只要手機開著任何無障礙服務（這次是 ASUS GlideX；密碼管理器、投放、讀屏也都算），語意樹就會啟用。綜合頁每幀 8.1ms 中，SEMANTICS 佔 4.4ms、PAINT 佔 3.3ms，raster 只有 2.2ms。165Hz 的預算是 6.06ms。
- **根因二：整頁一次建好**。`SingleChildScrollView` + `Column` 每捲一點，整頁（包含畫面外的五星一覽、時間軸）都要重新繪製與更新語意。改成 `ListView`／`CustomScrollView` + `SliverList.list` 後，只處理畫面附近的區塊。橫向時間軸也從 `Row` 改成橫向 `ListView.builder`。帶本地狀態的區塊（紀錄表頁碼、搜尋框、垂直時間軸已載入筆數、橫向時間軸位置）要加 `AutomaticKeepAliveClientMixin`，否則捲出畫面再捲回來會重設。
- **按需建構的副作用：大區塊進場那一幀會卡**。整頁一次建好時，五星一覽（數十個圖示的 `Wrap`）是在開頁時建；改成按需建構後，它變成在滑動途中、捲入畫面那一幀才一次建好，量到 11～27ms 的尖峰（使用者感覺「中途卡一下」）。處理：`SliverFiveStarOverview` 依寬度切成列，每次只多建一列，尖峰降到約 7ms。**`SliverLayoutBuilder` 每次捲動都會重跑**（捲動位置也在 sliver 約束裡），若每次都回傳新的 `SliverList`，畫面上的列會每幀重建，綜合頁準時率從 97% 掉到 80%；要依寬度快取、寬度沒變就回傳同一個 widget。垂直五星時間軸進場仍有約 10ms 的語意樹尖峰（晚 1 拍）。
- **根因三：`AnimationController.repeat()` 無條件在跑**。保底卡呼吸動畫只在「快保底」時才顯示，但計時器從頁面打開就一直在跑，每個 vsync 都排一幀，卡池頁靜止時也以 165fps 重畫（主要是耗電）。改成依階段與「移除動畫」設定啟停。
- **前後對照**（ROG Phone 9，165Hz，開著無障礙服務，慣性滑動準時率；修正後為最終版 0cb1fff 的量測）：

  | 頁面 | 修正前 | 修正後 |
  |---|---|---|
  | 綜合（冷啟動後） | 41～44% | 96.3% |
  | 綜合 | 43.5% | 97.3% |
  | 角色活動 | 92.3% | 98.6% |
  | 武器活動 | 96.9% | 98.2% |
  | 其他有紀錄的卡池頁 | 98.6～99.2% | 98.6～99.2% |
  | 設定、貢獻者 | 98.9%、100% | 99.1%、100% |

  靜止時出幀：修正前，有紀錄的卡池頁全部持續約 165fps；修正後只剩正處於「快保底」的頁面（設計上的動畫），其餘為 0。

### 42. 雲端同步讓畫面停住（通用，桌面也適用）

- **現象**：每次開 App 都會自動同步一輪，資料變動後 5 秒也會檢查一次。同步檔是全部帳號的 JSON，三個帳號約 4 MB。
- **根因**：一輪同步的「解析雲端檔」「把本機資料轉成 JSON」「算內容指紋（解析＋重新轉 JSON＋SHA-256）」都在主 isolate 上一次做完，電腦上分別約 145、30、55 ms，手機更慢。下載、上傳是在等網路，不會卡。
- **處理**：這三步改用 `Isolate.run` 在背景做（`cloud_sync_service.dart` 的 `_importInBackground`、`syncFingerprintInBackground`，`state/cloud_sync.dart` 的 `_exportInBackground`），`runSyncRound` 的 `exportLocal` 改成回傳 `Future<String>`。
  - 送進 `Isolate.run` 的閉包要寫在 top-level 函式裡、只抓參數：在 notifier 的方法裡直接寫閉包，可能把整個 notifier（含 `Timer` 等不能跨 isolate 傳的物件）一起帶過去而出錯。
  - 背景 isolate 裡的 `Logger` 沒有接到 App 的 log 輸出，訊息會不見；需要記錄的錯誤要丟回主 isolate 再記（現有的雲端檔損毀／版本過新本來就在主 isolate 記錄）。
  - 例外會原樣傳回呼叫端，原本的 `on FormatException` 等分支不用改。
- **流量**：原本每輪不管內容有沒有變，都整份下載＋整份上傳（4 MB 的同步檔，手機每開一次 App 約用 8 MB；上傳還被 Base64 放大約三分之一）。現在合併前就比對指紋，相同時整輪跳過合併與上傳（log 寫 `already in sync (merge and upload skipped)`）；合併後才相同則只省上傳（`uploaded=skipped (unchanged)`）。實測電腦版連開兩次：第二次一輪從約 5 秒降到約 2.4 秒。指紋包含「目前選中的帳號」、帳號順序與別名，所以在不同裝置之間切換使用時，第一次還是會上傳。下載仍然每輪都要（想省要改成先比對 Drive 檔案的 `md5Checksum`，這次沒做）。
- **電腦上的初步效果**（真實資料 4 MB，同步期間每 4 ms 排一次計時器量主 isolate 最長停頓）：約 150 ms → 約 8 ms。這個量法漏掉了下載、合併、上傳，實際要以下面的實機量測為準。
- **實機量測（ROG Phone 9，profile 版，開 App 那一輪）**
  - 作法：`am start` 帶 `--ez start-paused true --ez endless-trace-buffer true --ez enable-dart-profiling true`（不加最後一個，VM Service 會回「Profiler is disabled」），從 logcat 取得 VM Service 位址並 `adb forward`，先 `setVMTimelineFlags` 再 `resume`，等同步跑完後抓 `getVMTimeline` 與 `getCpuSamples`，把 ui 執行緒的長事件和同時段的 CPU 取樣對起來看是哪個函式。正式／profile 版的 App log 不在 logcat、私有目錄也讀不到，所以時間點要靠取樣判斷。對照組：不帶 `--dart-define-from-file` 建置（同步停用），確認停頓是不是同步造成的。
  - **坑：`start-paused` 會讓之後 `Isolate.run` 開的背景 isolate 也停在起點**。只放行主 isolate 的話，背景下載永遠不會完成，同步根本沒跑完，量到的「主 isolate 沒有停頓」是假的（本次前幾輪量測就是這樣，設定頁的「上次同步」也一直停在舊時間）。量測期間要持續輪詢 `getVM`，對 `pauseEvent.kind == 'PauseStart'` 的新 isolate 呼叫 `resume`。判斷有沒有真的跑完：時間軸上 `CreateWithinExistingIsolateGroup` 應該出現好幾次（下載、解析、匯出、指紋……），量測結束後 `getVM` 不該再有 `_RemoteRunner._remoteExecute`。
  - 分兩種情境量：A．同一台裝置重開（雲端與本機相同）；B．先在電腦同步、再開手機（紀錄相同，只差「目前選中的帳號」等設定）。
- **實機找到的停頓與處理**（都在主 isolate 上）
  - 下載完把 4 MB 轉成文字的 `utf8.decode`：29.6 ms。
  - Dart 的 HTTP 解析（`_HttpParser`）處理下載的資料：約 11 ms。
  - 匯出時把全部紀錄當訊息送進背景 isolate，複製本身在主 isolate：約 17 ms（時間軸上是一段沒有 Dart 堆疊的原生工作，緊接著背景 isolate 建立）。
  - 合併雲端資料（`mergeWith` 逐筆比對＋`GachaStorage.save` 每個帳號重寫檔案）：約 100 ms，即使一筆都沒新增。
  - **上傳**：googleapis 預設的 multipart 上傳會把整份內容做 Base64，編碼在呼叫端 isolate 上跑，約 387 ms，而且多約三分之一流量。
  - 合併讓 `byUid` 換成新的 Map，觸發「5 秒後的變動檢查」，又多做一次匯出；啟動時若這個檢查在第一輪還沒跑完就到點，因為還沒有上一輪指紋可比，會排一整輪 `rerun`，再下載一次 4 MB。
  - 處理：
    - 下載、上傳都改在背景 isolate 用目前的 access token 直接打 Drive REST（`fetchDriveMedia`、`putDriveMedia`，上傳用 `uploadType=media` 送原始位元組）。查檔案 ID 仍在主 isolate 用 googleapis，順便讓 Windows 的自動續期 token 保持有效。錯誤對應成 googleapis／googleapis_auth 的同款例外（`www-authenticate` → `AccessDeniedException`，其他非 2xx → `DetailedApiRequestError`），既有的「需要重新連結」判斷不用改。第一次建檔仍走 googleapis。
    - 匯出改成只傳記錄檔路徑，由背景 isolate 自己讀檔（每條寫入路徑都是先存檔才更新 state，內容一致）。
    - 合併前先在背景比指紋，相同就整輪跳過合併與上傳；不同時，在背景挑出內容完全相同的帳號，不送進合併；合併後與原本相同的帳號不重寫檔、不換物件，`byUid` 沒變就不替換。
    - 同步自己的合併期間不排變動檢查；變動檢查到點時若同步正在跑，就等該輪結束再比指紋。
- **最終實機結果**（開 App 後主 isolate 最長停頓）：情境 A 約 5 ms，情境 B 約 10 ms（修正前 387 ms＋43 ms＋11 ms 等多段）。


### 43. 轉換語言、匯入匯出、寫檔讓畫面停住（通用，桌面也適用）

- **量法補充：只看時間軸會漏算**。有些主 isolate 上的工作沒有被時間軸事件框住（轉換資料語言就是），時間軸上最長只看到約 9 ms，CPU 取樣卻顯示寫檔佔了約 39 ms。改用「把連續的 CPU 取樣串成忙碌時段」來算停頓（取樣間隔 0.5 ms，間隔小於 1.5 ms 視為連續），用同一方法重查 #42 的同步量測，結論不變。量測不必重開 App：以 `--ez enable-dart-profiling true` 正常啟動，等開 App 同步跑完再連 VM Service 開始錄，同時用 `adb shell input tap`／`settings put system user_rotation` 操作畫面。手機的自動旋轉設定量完要還原。
- **量測工具 `tool/measure_ui_stalls.py`**（需 `pip install websockets`；手機和模擬器同時連著時先設 `ANDROID_SERIAL`）：`record` 清空緩衝區、依動作檔操作畫面後抓回資料（`--fresh` 先以分析模式重開 App），`dump` 不清緩衝區直接抓回目前資料，`bursts` 列出最長的連續忙碌時段與當時的 App 函式。`vmTag=VM` 佔絕大多數的時段會標註出來：那通常是 VM 在處理量測請求本身（例如 `dump` 錄到前一次抓取的序列化），不是 App 的停頓。
- **實測（ROG Phone 9，profile 版）**

  | 操作 | 主 isolate 連續忙碌 | 主因 |
  |---|---|---|
  | 轉換資料語言（0 筆要轉） | 76、63、33、30、20 ms⋯ | 每個帳號整份重寫（`GachaStorage.save` 的 `jsonEncode`） |
  | 轉向 | 約 21～28 ms | 整頁重新排版（LAYOUT 7～15 ms、BUILD 5～8 ms） |
  | 切換帳號 | 約 14～17 ms | 重建卡池頁 |
  | 開啟設定頁 | 約 52、39、28 ms | 設定頁本身建構，取樣裡沒有 App 函式（未處理） |

- **處理**
  - `GachaStorage.save` 的 JSON 編碼改在背景 isolate（送過去的物件複製仍在主 isolate，但比整份編碼便宜得多）。更新紀錄、匯入、轉換語言、同步合併都經過這裡。
  - 轉換資料語言：轉換後內容與原本相同（`BannerStorage.sameContentAs`）就不寫檔、沿用原物件，全部沒變就不替換 `byUid`。改完實測最長約 18 ms，剩重讀語言對照表（`LangCatalogStorage.load`）。
  - 設定頁匯出：改用與雲端同步共用的 `exportAccountsBytesInBackground`（背景讀記錄檔、編 JSON 與 UTF-8）。匯入：`importAccountsInBackground` 在背景解析；背景 isolate 的 log 會不見，失敗的 log 改由設定頁的錯誤分支記錄。
  - **不做頁面統計快取**：轉向時 `computeGachaStats` 只出現在約 1 個取樣（約 0.5 ms），主要成本是排版，而且發生在系統轉向動畫期間。
- **坑：流程太快結束，進度對話框留下空白框**。外層在進度出現時 `showDialog`，對話框要到下一幀才建構、才開始 `listen` 進度；流程若在那之前就把進度清空（轉換語言改成免寫檔後就會），對話框收不到清空事件，留下一個只有資訊圖示、沒有文字、關不掉的空白框。修法：對話框第一次建構後檢查一次，進度已是 null 就自己關。**只能檢查第一次**：若每次重建都檢查，Android 記錄存取流程（取消更新後推設定頁）會在設定頁推上來後被誤關，`android_log_wait_test` 有鎖。
- **測試裡等非同步結果，要等到條件成立，不要賭時間或圈數**（共用 `test/helpers/wait_until.dart`）：
  - widget 測試：背景 isolate 的結果要真實時間才回來，假時間的 `pumpAndSettle` 等不到。用 `pumpUntil(tester, cond)`：每輪 `runAsync` 讓背景跑一下再 `pump`，條件成立或 5 秒為止。
  - 一般非同步測試：用 `waitUntil(cond)`，以實際時間（5 秒）為上限。原本是「空轉 1000 輪」，被測程式有真正的檔案 I/O 時，整套測試平行跑、機器忙，1000 輪可能在 I/O 回來前就跑完，偶發失敗（`fallback recapture also races the client log`）。
  - 等 repository 從磁碟載入帳號：用 `waitForBootstrap()`，不要 `Future.delayed(50ms)`。固定延遲在快的機器上永遠會過，CI 忙時才偶爾失敗，最難查。部分純 state 測試仍有 `delay(50ms)`，CI 偶發失敗時先往這裡查。
- **提交前的檢查要真的擋住失敗**：`flutter test | tail -1` 的結束碼永遠是 0，串在 `&&` 後面擋不住失敗的測試。要檢查輸出含 `All tests passed` 才提交（這次就因此誤提交過一次）。

### 44. 更新紀錄（等待擷取、下載卡池）讓畫面停住（通用，桌面也適用）

- **量法**：要人開遊戲，無法用 `adb` 腳本操作。先以分析模式開 App、清空緩衝區開始錄，由使用者按「更新紀錄」、開遊戲進喚取記錄頁；完成後**不必等固定錄製時間結束**，用 `tool/measure_ui_stalls.py dump` 不清緩衝區直接抓即可。
- **實測（ROG Phone 9，profile 版，新增 0 筆）**：修正前，主 isolate 超過 8 ms 的停頓 99 段，最長 72.8 ms；修正後剩 3 段，最長 14.2 ms（更新後重讀語言對照表 `LangCatalogStorage.load`，未處理）。
  - **等待擷取**：每秒輪詢 Client.log 增量，解碼都在主 isolate。約六成時間花在 `Uint8List.fromList([...carry, ...decode])`：spread 逐位元組裝進可成長的 `List<int>`，非常慢。其餘是 XOR 解碼、UTF-8 解碼與網址比對。
  - **下載卡池**：總覽頁、卡池頁 `ref.watch(gachaRepositoryProvider)` 訂閱整個狀態，每換一池更新一次 `progress`，就整頁重算統計與時間軸，約每秒一次、每次 10～25 ms。
- **處理**
  - `PollingClientLogWatch` 把「接上 carry、解碼、找最新憑證」整段移到背景 isolate（`_scanInBackground`），串接改用 `BytesBuilder`。背景 isolate 的 log 不會進 App log，被拒網址的原因由背景交回，在主 isolate 寫 warning。
  - 兩頁改用 `select` 只訂閱 `activeData` 與 `isBootstrapping`。紀錄在全部卡池抓完才一次替換 `byUid`，所以整個更新只重算一次。**其他頁面要讀 repository 狀態時，也要用 `select`，不要訂閱整個狀態**。
  - `phone_layout_pages_test` 鎖住：只改進度（`clearProgress()` 產生新狀態物件）時，兩頁不會重建（以 `debugOnRebuildDirtyWidget` 計數）。
  - 剩下的 14.2 ms 是開 App 後第一次讀語言對照表（之後走 `LangCatalogService` 的 memo）：`LangCatalogStorage.load` 改在背景 isolate 讀檔並解析 JSON。
- **未量**：沒有實測新增大量紀錄的情況（需要實際抽卡）。抓完那一次的重算成本會隨紀錄數增加。

### 45. 打開設定頁卡一下（通用，桌面也適用）

- **實測（ROG Phone 9，profile 版，開 App 後第一次打開）**：主 isolate 連續忙碌 53 ms，其中 LAYOUT 28 ms，大多是引擎原生的文字排版，Dart 堆疊只看到 `_LocaleDropdown`。
- **原因**：`DropdownButton` 即使 `isExpanded: true`，也會把所有選項放進 `IndexedStack`，而 `IndexedStack` 會排版每個子項。介面語言選單有 32 個選項，各用自己的文字書寫，資料語言選單也有日、韓、泰文；每次打開設定頁都要全部排版，第一次還要載入多種文字的系統字型。
- **處理**：`selectedItemBuilder` 改用 `_onlySelectedLabel`，只有已選項目放文字，其餘放 `SizedBox.shrink()`；展開後的清單仍由 `items` 顯示全部名稱。兩個 setter 都先同步改狀態再存檔，選完後外層與表單在同一幀重建，按鈕不會閃空白。`settings_locale_dropdown_test` 鎖住收合時不建構其他語言名稱。
- **結果**：最長 53 → 43 ms（LAYOUT 28 → 17 ms），其餘幾段 15～22 → 約 9 ms。
- **沒做**：剩下的是整頁一次建構與排版（`SingleChildScrollView`），取樣大多是原生文字排版，對不到特定區塊。改成按需建構的清單，捲出畫面的區塊會被銷毀；有進行中狀態的區塊（同步、匯入、轉換的忙碌狀態等）要逐一加 `AutomaticKeepAliveClientMixin`（第 41 條的做法），改動面大，收益又不確定。
- **量測坑：腳本盲點座標會點到別的 App**。第一次量測時，選單沒打開；腳本接著按「返回」，直接退出 App，後續點擊落在桌面，打開了別的 App。`tool/measure_ui_stalls.py` 在每次 `input` 前都檢查前景是不是本 App（`dumpsys activity activities` 的 `topResumedActivity`），不是就中止。開選單這類前置步驟先手動執行、截圖確認，再開始錄。
---

## 十二、手機版 UI/UX 調整

### 46. 手機直向、橫向與電腦版的版面規則（通用）

- **參考資料**：已確認的示意圖（12 個畫面，含直向、橫向、電腦版）在 https://claude.ai/artifact/TeMxuPicwtkHjezNCM7nsL ；設計文件是 `docs/superpowers/specs/2026-11-07-mobile-ui-ux-adjustments-design.md`，實作計畫是 `docs/superpowers/plans/2026-11-07-mobile-ui-ux-adjustments.md`。以下全部屬於通用，原神版可以直接照做。
- **先分清楚三種版面**：`isCompactLayout` 在手機作業系統看短邊 < 600，在電腦看寬度 < 600。手機專屬的外殼規則（底部列、標題列收起、側欄社群連結、橫向卡片式紀錄）另外用 `phoneOrientationOf(context)` 判斷，只在 Android／iOS 回傳直向或橫向。電腦把視窗拉窄時仍是 compact，但外殼維持電腦版，不受這些規則影響。數字卡、圓餅則照寬度分支。
- **外殼**：
  - 手機直向的底部列只留「最後更新」，社群連結移到側欄最下方。側欄的社群連結不論直向或橫向都置中，外面包 `FittedBox`，窄的時候縮小、不會溢出。**踩雷：** 圖示按鈕寬 40、圖示 16，圖示兩側各自帶 12dp 空白，最右邊的團隊名稱是純文字沒有。整列置中時看起來左寬右窄，要在文字那端補同寬（`TeamLinksBar.iconInset`），只補在側欄，電腦版底部列靠右對齊不用補。測試要量「第一個圖示左緣到文字右緣」的中點，量整列抓不到。
  - 手機橫向不建底部列，「最後更新」改放在綜合頁與卡池頁的標題後面；沒有資料時，同一位置顯示「尚未同步」。
  - 頁首標題列要用「標題＋標籤」包成一組再撐開，分享按鈕才會留在最右邊。若標題用 `Expanded`、標籤用 `Flexible` 並排，兩者會各分一半寬度，標籤浮在中間，分享按鈕也被擠離右緣。
- **橫向標題列往下捲收起**：
  - 做法：外殼用 `NotificationListener` 監聽頁面主要的垂直捲動（`depth == 0`），以動畫縮小 `PreferredSize` 的高度。
  - 這些時候一律展開：回到頂端、換頁（路由變了）、內容已不需捲動、轉成直向、鍵盤打開或收起。
  - 收起時，狀態列那一條仍維持標題列的底色，內容不會跑到狀態列底下。
  - **踩雷：不能只看捲動方向。** 手指離開螢幕時會多一筆 0.5～2.5dp 的反向拖曳，`UserScrollNotification` 的方向會跟著翻回來，標題列收起約半秒後又自己展開。改成同一方向累積拖曳超過 `kTouchSlop`（18dp）才切換。
  - 單元測試用的是直線拖曳，重現不了這個現象，是在模擬器上加暫時 log 才找到。
- **紀錄列表**：
  - 篩選、排序同一個 `Wrap`。
  - 換頁或跳頁後，用 `Scrollable.ensureVisible` 把「紀錄列表」標題捲到頂端。
  - **踩雷：** 頁面是按需建構的 sliver，標題捲出畫面後會被回收，`GlobalKey` 拿不到 context，捲動就不會發生。要讓標題保持存活（keep-alive）。
  - 換頁的通知要從表格唯一設定頁碼的地方發出，跳頁對話框才會共用同一條路徑。
  - 頁碼按鈕取代原本 367 項的下拉選單，改成開啟 `AppDialog` 輸入頁碼：只收數字，按 Enter 等同「前往」，超出範圍時「前往」不能按。
- **空資料提示嵌入按鈕圖案**：ARB 用 `{icon}` 佔位符。程式先傳入一個標記字元（U+FFFC），再依標記把字串切開，中間放 `WidgetSpan`。
  - 手機排版放圓形更新圖示。
  - 電腦版放縮小的「更新資料」按鈕樣子。
  - 找不到標記時退回純文字。
  - 只改核心四份 ARB 即可：其他語系沒有這個 key，會退回範本語言（zh），一樣看得到圖示。
- **精簡圓餅**：fl_chart 的半徑是絕對值，圓餅要縮成 112（直向）或 96（橫向、標題在旁）時，必須讓半徑跟著直徑等比例縮放，否則圓餅會超出框。圖例欄一律靠上對齊，3 列和 2 列的兩張卡標題才會在同一水平線。兩張精簡圓餅卡同一列時要包 `IntrinsicHeight`＋`CrossAxisAlignment.stretch`，否則高度跟著圖例列數走，3 列那張會比 2 列那張高（卡池頁原本用 `Wrap` 各自排就踩到）。手機橫向時卡池頁的保底卡列是 6:3:3，下面兩張圓餅卡若平分寬度，中間的縫會差半個間距；第一張要固定寬 `(maxWidth - 2 × 間距) / 2`，等於主保底卡的寬度（總覽頁電腦版早就這樣做）。`phone_layout_pages_test` 檢查稀有度卡右緣要對齊上面某張數值卡的右緣。電腦版卡池頁上面 6:3:3、下面三等分是刻意的不同格線，維持不動。
- **物品詳情**：
  - 圖片區用 `GestureDetector` 的水平拖曳，放手後換圖（距離 ≥ 48 或速度 ≥ 300）。觸控、滑鼠拖曳、觸控板橫向滑動（PanZoom 事件）都會被同一個辨識器接到。不做跟手輪播，到頭不循環。
  - 有多張圖時顯示頁點；分頁列箭頭的點擊範圍至少 48dp。
  - 右上角的 ✕：單欄時放在標題列，和名稱第一行對齊；雙欄時沒有標題列，接在右欄頁籤列的「›」後面（示意圖 ⑬–⑲ 的方案 A）。
  - 雙欄版面：手機橫向，或電腦寬度 ≥ 1000 時使用，電腦版對話框寬 960。
    - 左欄是單一捲動區，按鈕固定在底部。
    - **踩雷（「千咲」回報）**：單欄時，簡介（120dp 上限）與造型說明（96dp 上限）各有一層內層捲動。手指剛好放在簡介上，只會捲到簡介本身。雙欄時要拿掉這兩層內層捲動。
  - **捲動提示**：雙欄的左欄，以及單欄限高的簡介、造型說明，都共用 `_ScrollHintBox`。它常駐顯示捲軸；下方還有內容時，疊上底部漸層和「▾」（點一下捲 0.8 個可視高度），捲到底就收起來。高度跟著內容走，短內容不會被撐到上限。直向限高區塊放不下時，使用者原本看不出可以捲。
  - **踩雷：** 捲動邊緣的漸層在對話框裡要漸變到對話框的背景色，不能用卡片色，否則會出現一塊白框。
- **對話框右上角的 ✕**：
  - `AppDialog` 預設 `showCloseButton: true`，共用 `AppDialogCloseButton`：44×44，tooltip 是「關閉」，點了呼叫 `Navigator.maybePop`、回傳 `null`，呼叫端要把 `null` 當成取消。底部原本的按鈕保留。
  - 進行中、不能中途關閉的視窗（更新下載、分享圖產生中）要設 `showCloseButton: false`，並搭配 `PopScope(canPop: false)`。
  - ✕ 要和標題第一行垂直置中：標題上方補 `max(0, (44 − 第一行高度) / 2)` 的間距，並把 M3 的預設內距明確寫出來。**踩雷：** 不要用 `OverflowBox` 把按鈕壓小來對齊，點擊範圍會只剩約 29dp。
- **水平五星時間軸**：和左右的卡片在同一列時，高度跟卡片一樣（`kChartCardHeight` 380）；自己獨立一行時（例如手機橫向），寬度填滿，高度跟著內容。做法是用一個不含尾端留白的隱藏欄量出內容高度，軸線、列表、箭頭都以 `bottom: -overflow` 定位後再裁切，日期下方就不會多出空白。
- **用詞**：繁中跟除錯 log 有關的動作一律用「logs」，原本「分享日誌」和「匯出 logs」「清除所有 logs」不一致。英文說明文字也改成複數 "the logs"。簡中（日志）和日文（ログ）本來就一致。
- **帳號管理**：每個帳號收成一列（把手、UID＋「活躍」標籤、別名或「未設定別名」、最後更新），加上 ⋮ 選單（編輯別名、設為活躍、移除）。編輯別名改開 `AppDialog`，不再常駐輸入框。
- **驗收方式**：
  - 模擬器要轉橫向，用 `adb shell wm user-rotation lock 1`（改回直向用 `lock 0`）。`settings put system user_rotation` 不一定生效。
  - Windows 版的 Flutter 視窗不提供 UI Automation 樹，自動化點擊只能真的移動滑鼠。
  - 手機和模擬器同時連著時，`tool/measure_frame_pacing.sh` 裡的 `adb` 沒有指定裝置，要先 `export ANDROID_SERIAL=<手機序號>`。
- **審查與實機抓到的效能雷**（都用「數重建次數」的測試鎖住）：
  - 外殼的捲動監聽若在所有平台都掛著，直向或電腦版往下拖時，會一直把「收起」設成 true，build 又把它改回 false，於是每一幀都重建外殼（拖 20 步就重建 20 次）。監聽只在手機橫向、且鍵盤關著時掛上。
  - 卡池頁最外層若包一個 `LayoutBuilder` 只為了取寬度，標題列收合或鍵盤彈出時，高度每幀變動，整頁都會跟著重建。只在需要寬度的那個元件外面包 `LayoutBuilder`：放在 `SliverList` 裡面，它只拿到寬度限制，高度變動不會觸發重建。
  - 外殼動畫用 `TweenAnimationBuilder` 時，側欄、標題列、內容區要在 builder 外先建好再傳進去，動畫期間只重建高度。
- **排版雷**：
  - 精簡圖例的件數欄、百分比欄若照字寬抓得太剛好，「100.00%」在預設字級就會斷成兩行（Roboto 14px 寬 55dp，欄寬 54）。只有一種稀有度或類型的小卡池最常遇到。現在件數欄 44、百分比欄 58，並隨字級縮放。
  - 精簡圖例空間不夠時，件數和百分比移到第二行並靠右。Flutter 現成元件做不到「名稱靠左、數字靠右」：`OverflowBar` 會整列一起對齊；`LayoutBuilder` 放在 `IntrinsicHeight` 裡會丟例外。所以另寫一個兩個子元件的 `RenderBox`，固有尺寸、乾排版、實際排版共用同一條「放不放得下」的規則，並支援由右至左。
  - 「各卡池最高稀有度件數」的上下兩行版面若用 `Row[Flexible(名稱), Expanded(件數)]`，兩者各分一半寬度。名稱短時，用不完的那一半不會讓給件數，而是留在最右邊，於是右緣參差不齊。改用 `MainAxisAlignment.spaceBetween` 搭配兩個 `Flexible`。寬版的件數欄也改成靠右。
  - **整頁的空狀態要填滿剩下的高度再置中**（2026-11-09）：卡池頁的「此卡池無紀錄」原本放在標題下的 `SizedBox(height: 320)` 裡，只在那 320 裡置中，下方空一大塊，手機橫向（800×360）還溢出 29 像素。改成 `Expanded(child: EmptyState.noRecords(...))`，和「尚未同步」的 `noSyncPageBody` 同一種寫法；`phone_layout_pages_test` 在直向、橫向、電腦三種尺寸檢查內容中心落在標題以下區域的正中央。卡片裡的空訊息（篩選無結果、時間軸無某稀有度、圓餅無資料）本來就各自包 `Center`，總覽頁的區塊空狀態是跟著捲動的小框，都不用改。
- **滑動流暢度**（ROG Phone 9，165Hz，profile 版，慣性滑動準時率，量測時同時開著無障礙服務）：

  | 頁面 | 第 41 條優化後（直向） | 本次改版後（直向） | 本次改版後（橫向） | 追加項目後（直向） | 追加項目後（橫向） |
  |---|---|---|---|---|---|
  | 綜合（冷啟動後） | 96.3% | 97.7% | － | 96.2% | － |
  | 綜合 | 97.3% | 98.8%、98.0% | 97.2%、97.6% | 97.1%、98.1% | 97.3%、97.2% |
  | 角色活動 | 98.6% | 98.2%、97.9% | 99.0%、99.0% | 98.2%、98.2% | 98.6%、98.8% |
  | 武器活動 | 98.2% | 98.4%、98.1% | 98.3%、99.0% | 98.2%、98.8% | 98.4%、99.1% |

  「本次改版後」量於 7c0dd43；「追加項目後」量於 ce78d54，包含時間軸填滿寬度、捲動提示、對話框 ✕。靜止時出幀皆為 0。驗收標準 ≥ 95%，沒有退步。橫向量測時，慣性滑動有上有下，標題列的收起與展開動畫都包含在內。量測腳本的滑動座標是照直向寫的，量橫向時要把滑動改成 `input swipe 1200 900 1200 300`（往下捲）與 `1200 300 1200 900`（往上捲），並先 `wm user-rotation lock 1` 鎖定橫向，量完再 `wm user-rotation free` 並把 `accelerometer_rotation` 還原。ROG Phone 9 橫向時左側有瀏海避讓，選單按鈕在 (178, 137)。

### 47. 啟動畫面與 App 內主題同步（通用，Android）

- **Android 12 以上的限制**：啟動畫面一律由系統畫，只能設背景色（單一顏色）、中央圓形圖示（可加底色）、底部品牌圖（800×320px，以 4x 顯示為 200×80dp）。不能放全螢幕背景圖，品牌圖也不能依 App 語言切換。
- **做法**：`flutter_native_splash`（只放 dev_dependencies，不進 App）讀根目錄的 `flutter_native_splash.yaml`，執行 `dart run flutter_native_splash:create` 產生 `res/` 下的 styles 與圖檔。只開 Android（`ios: false`、`web: false`）。
  - 背景色對應主題的 `surfaceBackground`：淺色 #FAFBFD、深色 #0C1220。Flutter 範本預設是白／黑，跟 App 的深藍底不搭。
  - Android 12 以上中央沿用啟動器的自適應圖示；Android 11 以下讀 `assets/splash/icon.png`，由 `tool/generate_app_icons.dart` 從同一張原圖裁成圓形（640px＝160dp），兩邊看起來一致。
  - 品牌圖是英文 App 名稱（兩行），由 `tool/generate_splash_branding.py` 用 Flutter SDK 內附的 Roboto（Apache 2.0）畫成透明 PNG，淺色／深色各一張，顏色對應 `textSecondary`／`textMuted`。Dart 的 `image` 套件只能畫點陣字，所以改用 Python（PIL）。
- **踩雷：啟動畫面讀不到 App 內的「深色／淺色」**。系統在 App 執行前就畫好，只看手機的深淺色。手機淺色、App 選深色的人，會先看到白底再跳成深藍（反之亦然），等於閃一下。
  - 修法：Android 12（API 31）起用 `UiModeManager.setApplicationNightMode` 告訴系統這個 App 的深淺色，系統會記住，下次畫啟動畫面時就用對的顏色。Kotlin `AppPrefsChannel` ＋ Dart `AppPrefsPlatform`（與 #48 的語言同步共用同一個 channel）；「跟隨系統」送 `MODE_NIGHT_AUTO`，對 App 層級來說就是不覆寫。Android 11 以下不支援，仍跟手機。
  - **要等設定載入完才送**：設定是非同步載入的，載入前是預設的「跟隨系統」。一開機就送的話，選了深色／淺色的人會先被送一次「跟隨系統」再送正確值，多一次設定變更。`AndroidAppPrefsSync.start()`（由 `MainApp` 在 Android 上呼叫）先 `await waitForLoad()`，再用 `listen(..., fireImmediately: true)` 同步並監聽之後的切換。
  - 這個 API 會觸發 `uiMode` 設定變更；`AndroidManifest.xml` 的 `configChanges` 已含 `uiMode`，Activity 不會重建。
  - 驗證方式：手機設深色、App 選淺色，`am force-stop` 後用 `screenrecord` 錄冷啟動，再用 ffmpeg 拆格看。

### 48. 系統設定「應用程式語言」與 App 內語言雙向同步（通用，Android 13+）

- **為什麼系統清單裡沒有這個 App**：Android 13 起，系統設定的「應用程式語言」只列出在 `<application>` 宣告 `android:localeConfig` 的 App。Flutter 範本沒有這個宣告。
- **清單只列 App 已開放的語言**：`res/xml/locales_config.xml` 是寫死的，App 內則是翻譯釋出後才開放（`releasedLocalesProvider`）。全部 ARB 都列進去的話，系統清單會出現 App 自己不開放的語言。`test/l10n/android_locales_config_test.dart` 比對兩邊，新語言釋出時會失敗並印出該貼進 XML 的內容，CI 會擋下來。Android 14 起另有 `LocaleManager.setOverrideLocaleConfig` 可在執行時更新清單，目前沒用。
- **繁中標籤要寫 `zh-Hant`**：App 內繁中是不帶字集的 `zh`（ARB 範本），但 XML 和送給 `LocaleManager.setApplicationLocales` 的都要用 `zh-Hant`，系統清單才會標成繁體、也才對得上目前選中的項目。反向對應（`zh-Hant-TW`、`zh-TW` → 繁中，`zh-Hans-*`、`zh-CN` → 簡中）沿用 `localeListResolution`，不另寫一張表。系統建議區會出現「繁體中文（台灣）」「English (United States)」這類地區版本，回到 App 一樣對得到。
- **雙向同步**（`AndroidAppPrefsSync`）：
  - App → 系統：監聽設定的語言，寫回 `LocaleManager`；「跟隨系統」送空清單。
  - 系統 → App：`configChanges` 已含 `locale`，Activity 不會重建，要靠 `WidgetsBindingObserver.didChangeLocales` 重新讀 `getApplicationLocales()` 再更新 App 設定。漏了這步的話，App 內已指定語言時，在系統設定改了不會有反應。
  - 防來回觸發：寫入前都先比對對方是否已是同一個語言。
- **踩雷：開機時系統端是「預設」要分兩種情況**。可能是剛升級、App 內已指定語言的舊使用者（要把 App 的選擇推給系統），也可能是使用者在 App 關著時把系統設定改回預設（要跟著改成「跟隨系統」）。用一個只寫一次的旗標 `pref.localeSyncedToSystem` 區分：只有第一次才推給系統。系統端有值時一律以系統為準。
- 驗證：`adb shell cmd locale get-app-locales <package>` 看系統端的值；`am start -a android.settings.APP_LOCALE_SETTINGS -d package:<package>` 直接開系統的語言頁。

## 十三、多國語言

### 49. 一次補齊 27 種語言與由右往左的版面（通用）

- **翻譯流程**：子代理平行翻譯（每個負責 3 種語言），共用一份說明（英文為來源、繁中 ARB 的 `@` 說明當語境、`docs/術語表.md`），每個檔用檢查腳本確認：key 齊全、佔位符與 ICU 參數名稱不變、沒有殘留中日文、翻譯者欄位固定為 `<a href="https://claude.com/claude-code">Claude Code</a>`。全部回來後再跑 gen-l10n、analyze、完整測試。繁中、簡中是原始語言，翻譯者欄位保持空白（`locale_metadata_test` 鎖住），不要加 Claude Code。
- **遊戲用語要照官方**：AI 翻譯在遊戲有官方版本的語言會自己猜卡池名稱（法文、西文、葡文、泰文一開始 12 個全錯）。卡池名稱逐字照抄（只修明顯錯字），全檔的「喚取」「共鳴者」「喚取記錄」、表格的「喚取時間」也統一成官方說法，並整理進 `docs/術語表.md`。
- **怎麼找官方翻譯**：遊戲內的喚取記錄頁其實是官方網頁（遊戲用內嵌瀏覽器開），網頁上的文字不寫死在遊戲裡，而是依語言另外載入語系檔，所以抓語系檔就有每種語言的官方用語，不必自動操作遊戲切語言（有防作弊誤判風險）。
  1. 用擷取到的喚取記錄網址在一般瀏覽器開，開發者工具「網路」分頁找 `.json` 請求，或在頁面的 JS bundle 裡搜 `locales`。
  2. 鳴潮的位置是 `https://aki-gm-resources-oversea.aki-game.net/aki/gacha/locales/<語言>.json`，有 `en`、`ja`、`ko`、`de`、`fr`、`es`、`pt`、`th`、`zh-hans`、`zh-hant`（全小寫，`zh-Hant` 會 404）；其他語言遊戲本身沒出，就沒有官方版。
  3. 對照鍵名：`selectList.*` 是 12 個卡池名稱，`title` 是喚取記錄，`character`／`weapon`／`item` 是類型。拿英文檔對照，就知道每個值對應哪個詞。
  4. 遊戲沒出的語言，提到遊戲畫面時用英文官方名稱（例如「Convene Records」），玩家在遊戲裡對得上。
  - **原神**：祈願紀錄同樣是遊戲內開的官方網頁，應該也是網頁載入語系檔的架構，用同樣方法（開發者工具看請求、搜 bundle）找它的語系檔，就能拿到祈願、角色活動祈願等各語言官方名稱。
- **Crowdin**：這 27 種語言由 Crowdin 管理，只寫進 repo 的話，下次 Crowdin 同步可能把 ARB 蓋回空白，要另外把翻譯匯入 Crowdin。
- **不支援的語言會掉到南非語**：系統語言清單完全對不上 App 的語言時，Flutter 預設取 `supportedLocales` 的第一個；gen-l10n 依字母排序，加了 27 種語言後第一個變成 `af`（南非語），印尼文、印地文等使用者會看到整個 App 是南非語。`localeListResolution` 在整份清單都對不上（或清單為空）時改回傳英文，`locale_metadata_test` 用實際語言清單鎖住。原神版加語言時一樣會中，要一起改。模擬器上不容易重現：Android 會把系統語言接在 App 語言後面，只切 App 語言時 Flutter 還是會拿到系統的英文。
- **Android 原生字串也要翻**：啟動器上的 App 名稱與無線偵錯配對通知走 `res/values-*/strings.xml`，不在 ARB 裡；補 ARB 時漏了這邊，選其他語言時這 16 個字串會顯示英文。補齊時 App 名稱沿用各語言 ARB 的 `appName`；「無線偵錯」「使用配對碼配對裝置」等系統用語沿用 ARB 引導頁已對過的 Android 官方譯名與引號樣式；單、雙引號要加反斜線跳脫。`android_locales_config_test` 檢查 `locales_config.xml` 列出的每種語言都有字串檔，且字串名稱與英文版一致。
  - **資料夾代碼**：希伯來文要用 `values-iw`，不能用 `values-he`（Android 比對資源時會把語言代碼轉成舊式寫法 `he` → `iw`，aapt2 卻照原樣編成 `he`，結果對不到）。挪威文 `values-nb`（見下）、巴西葡文 `values-pt-rBR`、繁中 `values-zh-rTW`、簡中 `values-zh-rCN`，英文寫在預設的 `values/`。
  - **Crowdin**：`crowdin.yml` 加一組，與 ARB 一樣以繁中 `values-zh-rTW/strings.xml` 為原文，輸出到 `values-%two_letters_code%`；用 `languages_mapping` 改 zh-CN／pt-BR／he，用 `translation_replace` 把 `values-en/` 換成 `values/`。不要用 `%android_code%`：它一律帶地區（例如 `de-rDE`），奧地利、瑞士等其他地區的德文使用者會對不到。同上一條，第一次同步若沒把現有翻譯匯入 Crowdin，可能被蓋掉，要回頭處理。
  - **挪威文**：ARB 是 `no`，但 Android、Windows 回報的系統語言是書面挪威語 `nb`（或新挪威語 `nn`），原本對不上，系統語言是挪威文的使用者整個 App 都落到英文。處理：`localeListResolution` 把 `nb`／`nn` 對到 `no`；送給系統的代碼（`systemLocaleTagOf`）、`locales_config.xml` 與原生字串資料夾都改用 `nb`（`values-nb`），Crowdin 對應 `"no": nb`（YAML 的 `no` 不加引號會被當成布林值 false）；從系統讀回時 `nb` 與舊版送出的 `no` 都認。模擬器以 `cmd locale set-app-locales tw.reh.wuwa.gacha --locales nb` 驗證介面為挪威文。
- **複數**：範本（繁中）沒有複數，但只要範本把佔位符宣告成 `int`／`num`，其他語言檔可以自己寫 ICU plural，gen-l10n 會接受。英文原本的「1 pulls」「1 seconds ago」也一併改成 plural。斯拉夫語系、阿拉伯文需要 few／many 等類別；`pt` 的 `one` 包含 0，用 `=1{}` 才不會出現「0 registo」。型別是 `String` 的佔位符（例如平均間隔）不能用 plural。
  - **後來逐語言補查**（挪威文出現「For 1 dager siden」）：丹麥、希臘、芬蘭、荷蘭、挪威、瑞典文整批沒做（相對時間、抽數、紀錄數等 15 個字串）；其他語言則漏在「數量後面接名詞、形容詞或動詞」的句子，例如英文匯入確認「1 accounts (1 records total)」、法文「1 nouveaux」、西文「quedan 1」、德文「1 IDs」。共修 16 個檔案、127 個字串。
  - 判斷要不要改：數字後面的字會不會因為 1 而變。標籤寫法（「紀錄：3」）、單複數同形（挪威文 trekk、法文 mois、義大利文 record）不用改；分頁「共 N 筆」只在多於一頁時顯示，總數不會是 1。
  - 一句話可以放兩組 plural（例如帳號數與紀錄數），gen-l10n 接受。`=1{}` 與 `one{}` 的選擇照上面：法文用 `one`（0 和 1 都算單數），其他用 `=1`。
  - `test/l10n/plural_forms_test.dart` 抽查幾種語言在 1 與 2 時的實際輸出。用寬鬆的腳本列出「數字佔位符不在 plural 裡」的字串再逐筆判斷，比逐檔閱讀快。
- **長字串溢出**：`phone_layout_pages_test` 的「1.3 倍字級不溢出」改成跑全部語言，並加上設定頁。一跑就抓到德文、加泰隆尼亞文、羅馬尼亞文的圖片快取「計算中」把列擠爆，以及貢獻者頁「Português (Portugal) — 翻譯者」整列過寬。前者改用 `CompactLegendRow`（數值放不下時換行靠右），後者改 `Wrap`。
- **由右往左（阿拉伯文、希伯來文）**：Flutter 會自動鏡像 `Row`、`ListView`、`Scrollbar`、可鏡像的圖示，但寫死的 `left`／`right` 不會跟著翻。這次修掉的：
  - 卡片的彩色邊條 `Border(left:)` → `BorderDirectional(start:)`；進度條 `Alignment.centerLeft` → `AlignmentDirectional.centerStart`，漸層 `begin`／`end` 也要用 directional。
  - 垂直時間軸的軸線 `Positioned(left:)` → `PositionedDirectional(start:)`，否則軸線留在左邊、圓點跑到右邊。
  - 水平捲動區的邊緣漸層和箭頭：捲動起點在由右往左時是右邊，`ScrollSide` 改成 `start`／`end`，配 `PositionedDirectional`。
  - **數字比例會被倒過來**：「5 / 80」「1 / 81」兩邊有空格時，雙向演算法會排成「80 / 5」；遮罩後的 UID「701••••••」會排成「••••••701」。這些文字固定 `textDirection: TextDirection.ltr`。
  - 遊戲資料文字（encore 的簡介、造型說明，只有由左往右的語言）在由右往左的介面裡，句末標點會跑到行首，固定用 `Directionality(ltr)` 包住。
  - `test/widgets/rtl_layout_test.dart` 以阿拉伯文鎖住以上行為。
- **驗收**：手機用模擬器 `adb shell cmd locale set-app-locales <package> --locales ar` 切語言；Windows 不必操作滑鼠，直接把 `%APPDATA%\tw.reh\<app>\shared_preferences.json` 的 `flutter.pref.locale` 改成 `ar` 再啟動（改之前先備份，驗完還原）。值是 BCP-47 代號，繁中是 `zh`、簡中是 `zh-Hans`；寫成 `zh_Hant` 之類無效的值會被當成不支援的語言。
