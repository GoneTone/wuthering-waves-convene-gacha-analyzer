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
| 手動輸入 | 都不行的時候 | 兩個平台共用：貼上網址（可整段貼上，例如飛行模式複製的錯誤訊息）或選擇 `Client.log` 檔案（見第 19 節） |

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

**飛行模式取得網址（鳴潮限定，原神要另外驗證）**
- 這是 WuWa Tracker 教學提供的 Android 手動方式。開飛行模式後進「喚取記錄」，頁面只顯示載入失敗，但長按可以全選複製出看不見的文字，內容是整段錯誤訊息（「網頁無法使用...無法載入位於 <網址> 的網頁...」），裡面有完整網址。
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
- **輸入法的自動校正會改網址**：手動輸入欄位要設 `keyboardType: TextInputType.url`、`autocorrect: false`、`enableSuggestions: false`，否則 `&lang=` 會被改成 `&Lang=`，網址就失效了。

**版面**
- 手機橫向時對話框高度只剩約 390，等待畫面放不下，`AppDialog` 要開 `scrollable: true`。
- 英文標題很長（「Can't read convene history automatically」），標題列 `Row` 裡的文字要包 `Flexible` 才會換行。

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

- **導覽**：側欄改成抽屜（漢堡選單），項目高 48 dp。標題列只留圖示、可縮到看不見的 App 名稱、帳號選單和更新鈕（改成圓形圖示鈕）。底部狀態列直向橫向都顯示，只隱藏團隊名稱和分隔線，按鈕 48 dp。
- **紀錄表格**：窄寬度改成卡片列表，每張卡顯示名稱、類型、稀有度、時間（相對時間）、總抽數、保底內；排序改成「排序：xxx」按鈕叫出底部面板。
- **對話框**：`AppDialog` 在手機上邊距 12 dp。物品詳情在手機橫向改成左右兩欄（左：說明與造型說明，右：立繪），避免立繪被壓扁。
- **看圖**：觸控單擊不做事（避免誤觸），雙擊放大／還原，雙指縮放，長按叫出選單（取代右鍵），未放大時往下滑關閉。滑鼠行為維持桌面版（單擊縮放、右鍵選單）。
- **觸控目標**：所有可點的東西至少 48 dp（捲動箭頭、拖曳把手、底部狀態列按鈕等），畫面上可以畫得比較小，但點擊範圍要夠。
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
