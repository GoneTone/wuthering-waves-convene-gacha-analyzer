# Android 平台基礎（子專案 1）— 設計 spec

- 狀態：待核准
- 日期：2026-11-05
- 上層文件：`2026-11-05-android-support-roadmap-design.md`

---

## 一、目的

讓 App 能在 Android 上建置、安裝、啟動，作為後續所有 Android 子專案的地基。現況是連啟動都做不到：`main.dart` 無條件執行 `RustLib.init()`，但 Android 上沒有 `libgacha_capture_core.so`，初始化失敗會被 `runZonedGuarded` 吞掉，結果 `runApp` 永遠不會執行，畫面停在空白。

## 二、目標／非目標／反目標

**目標**

- 新增 `android/` 平台，applicationId 是 `tw.reh.wuwa.gacha`（使用者選定）。minSdk 沿用 Flutter 預設的 `flutter.minSdkVersion`（目前是 24，也就是 Android 7）。使用者決定不因為無線偵錯而把舊版 Android 排除：沒有無線偵錯的版本，還能用 root 或手動輸入網址。
- 在 Android 上能啟動 App，不依賴 Windows 的功能都能正常使用：第三方匯入、總覽、各卡池頁、設定。
- 啟動時的 log 會寫進 Android 上的 log 檔。

**非目標（留給後續子專案）**

- 在手機上取得紀錄（子專案 2）。在那之前，Android 上的「更新」按鈕會失敗，這是預期內的。
- 手機版面（3）、另存新檔／分享（4）、雲端同步登入（5）、喚取立繪（6）、正式簽章與上架（7）。

**反目標**

- Windows 版的行為、建置或測試有任何改變。
- 為了這個子專案把 NDK 和 Rust 的 Android 工具鏈加進建置需求。

## 三、做法

### 3.1 考慮過的做法

| 做法 | 取捨 | 結論 |
|---|---|---|
| **Android 不編譯 Rust，啟動時依平台略過** | Rust 在 Android 上沒有任何功能會用到：攔截只能在 Windows 跑，log 串流只是轉送攔截模組的 log。改動只在 `main.dart`，建置機不需要 NDK 和 Rust 的 Android 編譯目標 | ✅ 採用 |
| 用 cargokit 的 Gradle 外掛把 Rust 編進 Android | 要先在 Rust 端把 `helper.rs`／`cert_store.rs` 用 `cfg(windows)` 隔開，`ca.rs` 的 `APPDATA` 也要改，還要把 `rust_builder` 接進 Gradle、在 CI 裝 NDK。這些都只是為了一個手機上用不到的模組 | ❌ |

子專案 2 的 root 和無線偵錯是用 Dart（`Process.run`、`flutter_adb`）加少量 Kotlin 實作，同樣不需要 Rust。

### 3.2 改動

1. **建立 Android 平台**：用 `fvm flutter create --platforms=android --org tw.reh` 產生 `android/`，再把 `applicationId` 和 `namespace` 改成 `tw.reh.wuwa.gacha`。`minSdk` 維持產生時的 `flutter.minSdkVersion`。
2. **`lib/main.dart`**：`RustLib.init()` 和 `_connectRustLogStream()` 只在 `Platform.isWindows` 時執行。dartdoc 跟著更新，註明 Rust 只提供 Windows 的攔截功能。
3. **App 名稱**：Android 的 `android:label` 無法讀 ARB，所以用 `res/values*/strings.xml` 提供核心四語，內容沿用各 ARB 的 `appName`：預設（英文）、`values-zh-rTW`、`values-zh-rCN`、`values-ja`。
4. **App 圖示**：擴充既有的 `tool/generate_app_icons.dart`，從同一張主檔再輸出 Android 各密度的 `mipmap-*/ic_launcher.png`（48／72／96／144／192）。不另外引入圖示產生套件。
5. **權限**：主 manifest 只宣告 `INTERNET`。其他權限等到用到的子專案再加。

### 3.3 不改的部分（以及原因）

這次不刻意隱藏只能在 Windows 用的介面。正式發布要等子專案 7，在那之前只有開發用的測試版。如果現在先隱藏，之後子專案 2～5 又要一一改回來，是白做工。目前已知在 Android 上不能用、但也不會讓 App 崩潰的項目：

- 「更新」（攔截需要 Rust，`Client.log` 的路徑也是 Windows 的）→ 子專案 2
- 設定頁的遊戲資料夾區塊（會讀登錄檔，失敗時回傳空清單）→ 子專案 2
- 匯出、另存 log、存分享圖、存物品圖：`file_selector` 在 Android 上沒有實作 `getSaveLocation`，會丟 `UnimplementedError` → 子專案 4
- 「開啟 log 資料夾」：Android 不能打開 `file://` → 子專案 4
- 雲端同步登入 → 子專案 5
- 喚取立繪：`webview_windows` 找不到外掛實作，已經會靜默略過 → 子專案 6
- 視窗相關（`window_manager`）：大多已經有 `Platform.isWindows` 防護；`windowForegroundProvider` 沒有防護，但例外會被接住並記一筆 log → 不處理

## 四、驗收條件

1. `fvm flutter build apk --debug` 成功。
2. 在測試機（Android 16）上安裝並啟動，能看到總覽頁，log 裡有 `app start ... on android`。log 檔放在 App 的私有目錄，debug 版可以用 `adb shell run-as tw.reh.wuwa.gacha ls files/...` 讀取。
3. 在 Android 上用第三方匯入功能匯入一份紀錄後，總覽和卡池頁都能正確顯示。
4. 切換主題和語言正常；App 名稱和圖示正確。
5. Windows：`fvm flutter build windows` 成功，Windows 上的「更新」照常運作。
6. `fvm dart format lib/ test/`、`fvm flutter analyze`（No issues found!）、`fvm flutter test`（All tests passed!）全部通過。

## 五、風險與留給實作的部分

- **`super_clipboard` 的 Android 原生層**：它依賴的 `super_native_extensions` 也是用 cargokit 編譯的 Rust。已確認 `super_native_extensions-0.9.1/rust/cargokit.yaml` 有設定 `precompiled_binaries`（從 GitHub releases 下載），所以照理說不需要 Rust 工具鏈。但維護者的電腦本來就裝了 Rust，在這台電腦上建置成功，不代表沒有 Rust 的環境（例如之後的 CI）也能成功。到子專案 7 建 Android CI 時要驗證這一點。
- **圖示**：用一般的 mipmap PNG，不做 adaptive icon（主檔是白底滿版的方圖，系統套遮罩後就能用）。要不要改成 adaptive icon，留到子專案 7 準備上架素材時再決定。
- **簽章**：這個子專案只用 debug 簽章，正式的 keystore 在子專案 7 處理。
