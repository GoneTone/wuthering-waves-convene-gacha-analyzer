# Android 平台基礎 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓 App 能在 Android 上建置、安裝、啟動，並正常使用不依賴 Windows 的功能，Windows 版完全不受影響。

**Architecture:** 用 `flutter create` 加入 `android/` 平台，套件名稱改為 `tw.reh.wuwa.gacha`。Android 上不編譯也不載入 Rust：`main.dart` 只在 Windows 初始化 Rust bridge 和 Rust log 串流。App 名稱用 Android 的 `strings.xml` 提供核心四語，App 圖示擴充既有的圖示產生工具輸出。

**Tech Stack:** Flutter 3.47.5（FVM）、Kotlin（Flutter 產生的 Gradle Kotlin DSL）、`image` 套件（既有工具）

**Spec:** `docs/superpowers/specs/2026-11-05-android-platform-foundation-design.md`（上層：`docs/superpowers/specs/2026-11-05-android-support-roadmap-design.md`）

## Global Constraints

- applicationId 和 namespace：`tw.reh.wuwa.gacha`（上架後不能改，必須逐字一致）。
- minSdk：維持 `flutter.minSdkVersion`，不要寫死數字。
- 主 manifest 只宣告 `android.permission.INTERNET`，不加其他權限。
- 不把 `rust_builder` 接進 Android Gradle，不安裝也不要求 NDK 或 Rust 的 Android 編譯目標，不改 `rust/`。
- 不改 `rust_builder/`（CLAUDE.md 規則）。
- Windows 的行為不能有任何改變：所有新條件都以 `Platform.isWindows` 為真時維持原本的路徑。
- 所有 Flutter／Dart 指令透過 `fvm` 執行。每次 commit 前依序跑 `fvm dart format lib/ test/`、`fvm flutter analyze`（No issues found!）、`fvm flutter test`（All tests passed!）。
- Commit message 用英文 conventional commits，結尾加上 session 要求的 `Co-Authored-By` 和 `Claude-Session` 兩行。不要 push。
- 程式碼註解和 dartdoc 用中文全形標點，log 訊息用英文；所有新宣告都要有一行 `///` dartdoc（Flutter override 除外）。
- 測試機：USB 連接的 ASUS AI2501（Android 16），序號 `SBAIOC583904X7L`。手機同時開著無線偵錯時，`adb` 會看到兩個裝置，一律用 `adb -d` 指定 USB 那台。

## Review Focus

1. **在 Android 上按「更新」**：Rust 沒有初始化，`startCapture` 會丟例外。預期走既有的失敗處理流程（顯示錯誤、寫 log），不能卡住或讓 App 崩潰 → Task 3 Step 4。
2. **Android 匯入檔案時的副檔名過濾**：`file_selector` 在 Android 上把 `.json` 對應成 MIME 類型的方式不確定，檔案可能在選擇器裡變灰、選不到。預期能選到 `.json` 備份檔 → Task 3 Step 3。
3. **第一次啟動、沒有任何資料**：預期顯示空的總覽頁，不崩潰；喚取立繪的宿主元件找不到外掛時只記 warning → Task 1 Step 6。
4. **裝置語言**：系統語言是繁中、簡中、日文、英文時，桌面上的 App 名稱要分別顯示各自 ARB 裡的 `appName` → Task 3 Step 5。
5. **Windows 不受影響**：Windows 上 Rust 的 log 串流要照常連上（log 裡有 `rust log stream connected`），「更新」照常運作 → Task 3 Step 6。

---

### Task 1: 加入 Android 平台，並讓 App 在 Android 上能啟動

**Files:**
- Create: `android/**`（由 `flutter create` 產生）
- Modify: `android/app/build.gradle.kts`（`namespace`、`applicationId`）
- Move: `android/app/src/main/kotlin/tw/reh/wuthering_waves_convene_gacha_analyzer/MainActivity.kt` → `android/app/src/main/kotlin/tw/reh/wuwa/gacha/MainActivity.kt`（`package tw.reh.wuwa.gacha`）
- Modify: `android/app/src/main/AndroidManifest.xml`（加上 `INTERNET`；`android:label="@string/app_name"`）
- Create: `android/app/src/main/res/values/strings.xml`、`values-zh-rTW/strings.xml`、`values-zh-rCN/strings.xml`、`values-ja/strings.xml`
- Modify: `lib/main.dart:32-37,67`

**Interfaces:**
- Produces: Android 套件 `tw.reh.wuwa.gacha`；字串資源 `@string/app_name`（Task 3 會驗證它）。

- [ ] **Step 1: 產生 Android 平台**

Run: `fvm flutter create --platforms=android --org tw.reh .`
Expected: 新增 `android/`。接著跑 `git status --short`：除了 `android/` 和 `.metadata`，**不能有其他既有檔案被改到**。如果有（例如 `test/widget_test.dart`、`README.md`），刪除新增的檔案、還原被改的檔案。

- [ ] **Step 2: 改套件名稱**

在 `android/app/build.gradle.kts` 中，把 `namespace` 和 `defaultConfig.applicationId` 都改成 `"tw.reh.wuwa.gacha"`，`minSdk = flutter.minSdkVersion` 保持不變。把 `MainActivity.kt` 移到 `kotlin/tw/reh/wuwa/gacha/`，package 宣告改成 `tw.reh.wuwa.gacha`，並刪掉舊的空資料夾。

- [ ] **Step 3: manifest 和 App 名稱**

主 `AndroidManifest.xml` 在 `<application>` 前加 `<uses-permission android:name="android.permission.INTERNET"/>`，`android:label` 改成 `@string/app_name`。四份 `strings.xml` 的 `app_name` 逐字取自各 ARB 的 `appName`：

| 檔案 | 值 |
|---|---|
| `values/strings.xml` | `Wuthering Waves Convene Gacha Analyzer`（`app_en.arb`） |
| `values-zh-rTW/strings.xml` | `鳴潮喚取卡池分析`（`app_zh.arb`） |
| `values-zh-rCN/strings.xml` | `鸣潮唤取卡池分析`（`app_zh_Hans.arb`） |
| `values-ja/strings.xml` | `鳴潮集音分析ツール`（`app_ja.arb`） |

- [ ] **Step 4: `main.dart` 只在 Windows 初始化 Rust**

`await RustLib.init();`（第 37 行）和 `unawaited(_connectRustLogStream());`（第 67 行）都包進 `if (Platform.isWindows)`。`main()` 的 dartdoc 改成註明 Rust bridge 只在 Windows 初始化（Rust 只提供 Windows 的攔截功能）；`_connectRustLogStream` 的 dartdoc 補一句「只在 Windows 呼叫」。不改其他行。

- [ ] **Step 5: 建置 APK**

Run: `fvm flutter build apk --debug`
Expected: `✓ Built build\app\outputs\flutter-apk\app-debug.apk`。如果因為 `super_native_extensions` 要求 Rust 或 NDK 而失敗，**停下來回報**，不要自行在 Gradle 加 NDK 設定（這違反 spec 的前提）。

- [ ] **Step 6: 在實機上安裝並啟動（Review Focus 3）**

Run: `adb -d install -r build/app/outputs/flutter-apk/app-debug.apk`，然後執行 `adb -d shell am start -n tw.reh.wuwa.gacha/.MainActivity`，等 5 秒。
Expected:
- 畫面顯示總覽頁，而不是空白。可以用 `adb -d exec-out screencap -p > <scratchpad>/android_start.png` 截圖確認。
- `adb -d shell run-as tw.reh.wuwa.gacha sh -c 'cat files/logs/*.log' | grep "app start"` 有一行包含 `on android`。log 檔的實際路徑以 `log_service.dart` 為準。
- `adb -d logcat -d | grep -E "FATAL|flutter.*(Unhandled|Exception)"` 沒有和本 App 有關的致命錯誤。

- [ ] **Step 7: 品質檢查並 commit**

依 Global Constraints 跑 format、analyze、test，全部通過後再 commit：

```bash
git add android/ .metadata lib/main.dart
git commit -m "feat(android): add Android platform and skip Rust bridge on non-Windows"
```

---

### Task 2: Android 啟動器圖示

**Files:**
- Modify: `tool/generate_app_icons.dart`
- Create（工具輸出）: `android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png`（覆蓋 Flutter 預設圖示）

**Interfaces:**
- Consumes: 既有的 `_resize(img.Image source, int size)`、`tool/app_icon_source.png`。

- [ ] **Step 1: 擴充工具**

在 `.ico` 輸出之後，加一段 Android 輸出。用一個 `const androidMipmaps = <String, int>{...}` 對應：`mdpi` 48、`hdpi` 72、`xhdpi` 96、`xxhdpi` 144、`xxxhdpi` 192，路徑是 `android/app/src/main/res/mipmap-<密度>/ic_launcher.png`，沿用 `_resize` 和 `img.encodePng`，每輸出一個檔案就印一行 `✓ <路徑>  <size>x<size>`，格式跟既有的一樣。同時更新檔頭 dartdoc，把 Android 加進輸出清單。

- [ ] **Step 2: 執行工具並確認**

Run: `fvm dart run tool/generate_app_icons.dart`
Expected: 印出 5 行 `✓ android/...`。`git status` 顯示五個 `ic_launcher.png` 有變動；`assets/icons` 和 `.ico` **沒有**變動（主檔沒換，所以內容應該相同；如果有 diff，確認只是編碼上的差異）。

- [ ] **Step 3: 實機確認**

重新建置並安裝 APK（同 Task 1 的 Step 5～6），在手機桌面上確認圖示是本 App 的圖示，不是 Flutter 預設的藍色圖示。

- [ ] **Step 4: 品質檢查並 commit**

```bash
git add tool/generate_app_icons.dart android/app/src/main/res/
git commit -m "feat(android): generate Android launcher icons from the shared icon source"
```

---

### Task 3: 驗收

這個 Task 沒有新程式碼，只逐條驗證 spec 的驗收條件和 Review Focus。任何一項失敗，就回到負責的 Task 修正。

- [ ] **Step 1: 建置**

Run: `fvm flutter build apk --debug`，Expected: 成功。

- [ ] **Step 2: Windows 建置**

Run: `fvm flutter build windows`，Expected: 成功。

- [ ] **Step 3: 在 Android 上匯入（Review Focus 2）**

在 Windows 版用「匯出帳號備份」產生 `.json`，然後執行 `adb -d push <檔案> /sdcard/Download/`。在手機上用設定頁的匯入功能選這個檔案。
Expected: 選擇器裡可以選到 `.json`；匯入後，總覽和各卡池頁顯示正確的筆數。如果檔案在選擇器裡變灰、選不到，記錄下來，回報給使用者決定要在這個子專案修，還是留給子專案 4。

- [ ] **Step 4: 在 Android 上按「更新」（Review Focus 1）**

Expected: 出現既有的失敗提示，App 沒有崩潰也沒有一直轉圈；log 裡有對應的 warning 或 severe 紀錄。

- [ ] **Step 5: 主題、語言、App 名稱（Review Focus 4）**

在 App 內切換深色和淺色主題、切換語言，畫面都正常。桌面上的 App 名稱跟的是**系統語言**，不是 App 內的語言設定。請使用者在系統設定把裝置語言切到繁中、簡中、日文、英文，桌面上的 App 名稱要分別顯示 Task 1 Step 3 表格裡的值。測完把語言設定還原。

- [ ] **Step 6: Windows 不受影響（Review Focus 5）**

在 Windows 上 `fvm flutter run -d windows`，log 裡要有 `rust log stream connected`。「更新」的實際攔截流程需要開遊戲，**請使用者手動確認**，不要自動略過這一項。

- [ ] **Step 7: 品質檢查**

`fvm dart format lib/ test/`、`fvm flutter analyze`、`fvm flutter test` 全部通過。有修正的話就 commit；沒有修正就不用 commit。
