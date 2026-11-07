# Play 上架與更新 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Android 版能以正式金鑰簽章、由 CI 上傳到 Play 內部測試軌道；App 內的「有新版」在 Android 改由 Play 判斷並用彈性更新；全平台換上新圖示，並備齊上架文件。

**Architecture:**
- 版本代碼換算是一個 Dart 純函式，App 與 CI 共用。
- Android 的更新檢查經由一層可替換的 `PlayUpdateGateway` 呼叫 `in_app_update`，`AppReleaseNotifier` 依平台分流；Windows 路徑完全不動。
- 簽章由 `android/key.properties`（git-ignored）提供，CI 由 secrets 還原。

**Tech Stack:** Flutter（FVM 3.47.5）、Riverpod 3、`in_app_update`（實作時查最新穩定版，目前 5.0.0）、GitHub Actions、`image` 套件（既有圖示產生腳本）。

**Spec:** `docs/superpowers/specs/2026-11-06-play-release-design.md`

## Global Constraints

- 一律用 `fvm flutter` / `fvm dart`。commit 前依序：`fvm dart format lib/ test/` → `fvm flutter analyze`（`No issues found!`）→ `fvm flutter test`（`All tests passed!`）。
- 版本代碼只用在 Android，建置時以 `--build-number` 傳入；**不改 `pubspec.yaml`、不改 `release-windows.yml`**。
- 版本代碼公式：`MAJOR × 1,000,000 ＋ MINOR × 10,000 ＋ PATCH × 100 ＋ 尾碼`。
  - 正式版尾碼 `99`；`-rc.N` 尾碼 `N`（1 ≤ N ≤ 98）。
  - 例：`1.8.1` → `1080199`；`1.9.0-rc.2` → `1090002`；`1.9.0` → `1090099`。
  - 不符合 `vX.Y.Z` 或 `vX.Y.Z-rc.N` 的 tag 一律失敗；MINOR、PATCH 必須 ≤ 99。
- Android 的「有沒有新版」一律以 Play 為準；更新內容沿用既有 GitHub 查詢，**不裁掉頁尾**。
- CI 上傳到 **internal** 軌道，**不填 Play 的「新功能」**。
- 預覽版（rc）只放內部測試，不升級正式版（寫進文件即可，不需程式強制）。
- 金鑰、密碼、服務帳戶 JSON 不進 repo、不印到 log。
- log 英文；更新檢查的 Logger 沿用 `release`。
- 每個宣告一行 `///` dartdoc（含 private）；註解只寫 WHY；CJK 全形標點；省略號用 ASCII `...`。
- 新字串只改四份核心 ARB：`app_en.arb`、`app_ja.arb`、`app_zh.arb`、`app_zh_Hans.arb`。
- 平台測試用 provider override（`isAndroidProvider`）或 `TargetPlatformVariant.only(...)`，不在測試本體直接設 `debugDefaultTargetPlatformOverride`。
- commit 用英文 conventional commits，結尾附：
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01WreXjnEijW2movWG3V3c7c
  ```
- 不要 push。

## Review Focus

1. **Play 說有新版，但 GitHub 查不到說明**（斷網、API 配額用盡、說明還沒發佈）：仍要提示有新版，只是不顯示更新內容。（Task 2 測試 `play update + github failure → available without notes`）
2. **不是從 Play 安裝的版本**（開發者 `flutter run`、側載 APK）：啟動時的檢查要安靜略過；手動按「檢查更新」要顯示失敗並說明原因。（Task 2 測試 `non-play install: silent on auto, failure on manual`）
3. **玩家略過某版後**，自動檢查不再提示同一版；但手動檢查仍要顯示。（Task 2 測試 `skipped play version is not prompted on auto check`）
4. **Play 回報的版本代碼無法換算回版本號**：不提示，並記一筆 warning，不可當機。（Task 2 測試 `undecodable play version code → no prompt`）
5. **玩家在 Play 的確認畫面按取消，或下載失敗**：不顯示「重新啟動」提示，狀態回到閒置，記 log。（Task 3 測試 `flexible update denied or failed → no restart prompt`）

---

## File Structure

| 檔案 | 動作 | 責任 |
|---|---|---|
| `lib/services/android_version_code.dart` | 新增 | tag ↔ 版本代碼換算（純函式） |
| `tool/android_version_code.dart` | 新增 | CI 用的 CLI：輸入 tag，輸出版本代碼與 semver |
| `lib/services/play_update.dart` | 新增 | `PlayUpdateGateway` 介面、`InAppUpdatePlayGateway`、資料型別 |
| `lib/state/app_release.dart` | 修改 | Android 分流、`ReleaseAvailable` 擴充 |
| `lib/state/play_update_download.dart` | 新增 | 彈性更新下載狀態 |
| `lib/widgets/dialogs/new_version_dialog.dart` | 修改 | Android 的「更新」按鈕、沒有說明時的顯示 |
| `lib/pages/app_shell.dart` | 修改 | 下載完成後的「重新啟動」提示 |
| `lib/pages/settings_page.dart` | 修改 | 新失敗原因的翻譯 |
| 四份核心 ARB | 修改 | 新字串 |
| `android/app/build.gradle.kts`、`.gitignore` | 修改 | release 簽章 |
| `.github/workflows/release-android.yml` | 新增 | Android 發佈流程 |
| `.github/release-footer.md` | 修改 | 防毒說明限定 Windows |
| `tool/app_icon_source.png` | 取代 | 新圖示主檔 |
| `tool/generate_app_icons.dart` | 修改 | 加 Android 自適應圖示與 Play 512 圖示 |
| `docs/play-store/*`、`docs/Android移植筆記.md` | 新增／修改 | 上架文件、移植筆記第十節 |

---

### Task 1: 版本代碼換算

**Files:**
- Create: `lib/services/android_version_code.dart`、`tool/android_version_code.dart`
- Test: `test/services/android_version_code_test.dart`

**Interfaces:**
- Produces:
  - `int androidVersionCodeForTag(String tag)`：tag 必須是 `vX.Y.Z` 或 `vX.Y.Z-rc.N`（含 `v`），不合法拋 `FormatException`。
  - `String? tagForAndroidVersionCode(int code)`：反推 `vX.Y.Z` 或 `vX.Y.Z-rc.N`；換算不出來時回 `null`。
  - CLI：`dart run tool/android_version_code.dart v1.9.0-rc.2` 印出兩行：`VERSION_CODE=1090002` 與 `BUILD_NAME=1.9.0-rc.2`；tag 不合法時以非 0 結束碼離開。

- [ ] **Step 1: 寫失敗的測試**

```dart
test('release tags', () {
  expect(androidVersionCodeForTag('v1.8.1'), 1080199);
  expect(androidVersionCodeForTag('v1.9.0'), 1090099);
});
test('rc tags sort below the release', () {
  expect(androidVersionCodeForTag('v1.9.0-rc.2'), 1090002);
  expect(androidVersionCodeForTag('v1.9.0-rc.2'), lessThan(androidVersionCodeForTag('v1.9.0')));
});
test('invalid tags throw', () {
  for (final t in ['1.9.0', 'v1.9', 'v1.9.0-beta.1', 'v1.9.0-rc.0', 'v1.9.0-rc.99', 'v1.100.0', 'v1.0.100']) {
    expect(() => androidVersionCodeForTag(t), throwsFormatException, reason: t);
  }
});
test('reverse mapping', () {
  expect(tagForAndroidVersionCode(1080199), 'v1.8.1');
  expect(tagForAndroidVersionCode(1090002), 'v1.9.0-rc.2');
  expect(tagForAndroidVersionCode(17), isNull);        // 舊的執行序號
  expect(tagForAndroidVersionCode(1080100), isNull);   // 尾碼 00 不合法
});
```

- [ ] **Step 2: 執行，確認失敗**

Run: `fvm flutter test test/services/android_version_code_test.dart`
Expected: FAIL（函式未定義）

- [ ] **Step 3: 實作兩個函式與 CLI**（CLI 直接 import `lib/services/android_version_code.dart`，確保 App 與 CI 用同一份規則）

- [ ] **Step 4: 執行，確認通過；並手動跑 CLI**

Run: `fvm flutter test test/services/android_version_code_test.dart` → PASS
Run: `fvm dart run tool/android_version_code.dart v1.9.0-rc.2` → 印出 `VERSION_CODE=1090002` 與 `BUILD_NAME=1.9.0-rc.2`
Run: `fvm dart run tool/android_version_code.dart 1.9` → 結束碼非 0

- [ ] **Step 5: 品質檢查並 commit**

`feat(android): map release tags to Play version codes`

---

### Task 2: Android 由 Play 判斷新版

**Files:**
- Create: `lib/services/play_update.dart`
- Modify: `lib/state/app_release.dart`、`lib/pages/settings_page.dart`（`_resolveReason` 加新 token）、四份核心 ARB、`pubspec.yaml`（`fvm flutter pub add in_app_update`）
- Test: `test/state/app_release_test.dart`（新增 group `android (Play)`）

**Interfaces:**
- Consumes: Task 1 的 `tagForAndroidVersionCode`；既有的 `fetchNewerReleases`、`AppRelease`、`isAndroidProvider`、`settingsProvider.skippedReleaseTag`。
- Produces（`lib/services/play_update.dart`）：
  ```dart
  /// Play 回報的更新資訊。
  class PlayUpdateInfo {
    const PlayUpdateInfo({required this.available, required this.availableVersionCode, required this.flexibleAllowed});
    final bool available; final int? availableVersionCode; final bool flexibleAllowed;
  }
  /// 彈性更新下載的結果。
  enum PlayDownloadResult { downloaded, denied, failed }
  /// in_app_update 的最小介面（測試替換用）。
  abstract class PlayUpdateGateway {
    /// 不是從 Play 安裝等狀況會拋例外。
    Future<PlayUpdateInfo> check();
    /// 開始彈性更新，下載完成才回傳。
    Future<PlayDownloadResult> downloadFlexible();
    /// 安裝已下載的更新（App 會重新啟動）。
    Future<void> completeFlexible();
  }
  class InAppUpdatePlayGateway implements PlayUpdateGateway { ... }
  final playUpdateGatewayProvider = Provider<PlayUpdateGateway>((ref) => InAppUpdatePlayGateway());
  ```
  `InAppUpdatePlayGateway.downloadFlexible` 的對應：`AppUpdateResult.success` → `downloaded`、`userDeniedUpdate` → `denied`；`inAppUpdateFailed` 或 `PlatformException` → `failed`。
- Produces（`lib/state/app_release.dart`）：`ReleaseAvailable` 新增 `final String? playTag;`（Android 時為 Play 版本換算出的 tag，Windows 為 null），`releases` 可以是空 list。
- Android 檢查流程（`check(manual:)` 在 `ref.read(isAndroidProvider)` 為 true 時）：
  1. `gateway.check()` 拋例外：自動檢查回到 `ReleaseIdle`；手動檢查改為 `ReleaseCheckFailed('play')`，log warning。
  2. 沒有可用更新：與 Windows 相同（手動 → `ReleaseUpToDate`，自動 → `ReleaseIdle`）。
  3. 版本代碼換算不出 tag：log warning，視同沒有新版。
  4. 自動檢查且 tag 等於 `skippedReleaseTag`：回到 `ReleaseIdle`。
  5. 用 `fetchNewerReleases` 取說明，只保留版本 ≤ Play 版本的項目。GitHub 失敗時改用空 list 並 log info，**仍然提示**。
  6. 狀態設為 `ReleaseAvailable(releases, playTag: tag)`。
- 新 ARB key：`updateErrorPlay`。
  - zh：`無法連線到 Google Play，或此版本不是從 Google Play 安裝`
  - en：`Couldn't reach Google Play, or this copy wasn't installed from Google Play`
  - ja：`Google Play に接続できないか、このアプリは Google Play からインストールされていません`
  - zh_Hans：`无法连接到 Google Play，或此版本不是从 Google Play 安装`

- [ ] **Step 1: 寫失敗的測試**（fake gateway 透過 `playUpdateGatewayProvider.overrideWithValue`；`isAndroidProvider` 覆寫為 true；GitHub 用既有測試的 `MockClient` 模式）

```dart
test('play update + github notes → available with notes up to the play version', ...);
  // play: available, code 1090099；github: v1.10.0、v1.9.0、v1.8.2
  // → playTag 'v1.9.0'，releases 為 [v1.9.0, v1.8.2]（不含 v1.10.0）
test('play update + github failure → available without notes', ...);
  // github 回 500 → ReleaseAvailable，releases 為空、playTag 'v1.9.0'
test('play reports no update but github has one → no prompt', ...);
  // play: available=false；github 有 v1.9.0 → 手動 ReleaseUpToDate，自動 ReleaseIdle
test('non-play install: silent on auto, failure on manual', ...);
  // gateway.check() 拋例外 → 自動 ReleaseIdle；手動 ReleaseCheckFailed('play')
test('skipped play version is not prompted on auto check', ...);
  // skippedReleaseTag 'v1.9.0' → 自動 ReleaseIdle；手動仍為 ReleaseAvailable
test('undecodable play version code → no prompt', ...);
  // code 17 → 手動 ReleaseUpToDate
```

既有的 Windows 測試不改且要繼續通過。

- [ ] **Step 2: 執行，確認失敗**

Run: `fvm flutter test test/state/app_release_test.dart`
Expected: FAIL（`playUpdateGatewayProvider`、`playTag` 未定義）

- [ ] **Step 3: 加入套件並實作**（`fvm flutter pub add in_app_update`；`_resolveReason` 把 `'play'` 對應到 `l.updateErrorPlay`；log：`play update check: available=... code=... tag=...`、`play update check failed: $e`、`play version code $code has no tag mapping`）

- [ ] **Step 4: 執行，確認通過**

Run: `fvm flutter test test/state/app_release_test.dart test/services/android_version_code_test.dart` → PASS

- [ ] **Step 5: Android 建置確認並 commit**

Run: `fvm flutter build apk --debug` → `✓ Built`
Commit：`feat(update): check Google Play for updates on Android`

---

### Task 3: 彈性更新的介面

**Files:**
- Create: `lib/state/play_update_download.dart`
- Modify: `lib/widgets/dialogs/new_version_dialog.dart`、`lib/pages/app_shell.dart`、四份核心 ARB
- Test: `test/state/play_update_download_test.dart`、`test/widgets/dialogs/new_version_dialog_test.dart`（沒有就新增）

**Interfaces:**
- Consumes: Task 2 的 `PlayUpdateGateway`、`PlayDownloadResult`、`playUpdateGatewayProvider`、`ReleaseAvailable.playTag`。
- Produces:
  ```dart
  /// 彈性更新下載狀態。
  enum PlayDownloadPhase { idle, downloading, downloaded }
  final playUpdateDownloadProvider = NotifierProvider<PlayUpdateDownloadNotifier, PlayDownloadPhase>(...);
  class PlayUpdateDownloadNotifier extends Notifier<PlayDownloadPhase> {
    /// 開始下載；已在下載或已下載完時不重複觸發。
    Future<void> start();
    /// 安裝已下載的更新。
    Future<void> install();
  }
  ```
- `NewVersionDialog`：
  - Android（`isAndroidProvider` 為 true）時，主要按鈕改成「更新」（`updateButtonUpdate`），按下呼叫 `start()` 並關閉對話框；Windows 照舊開 GitHub 頁。
  - 標題的版本號優先用 `playTag`，否則用 `releases.first.tagName`。
  - `releases` 為空時，內容顯示 `updateNotesUnavailable`。
  - 「略過此版本」用同一個 tag。
- `AppShell`：監聽 `playUpdateDownloadProvider`，變成 `downloaded` 時顯示 SnackBar（`updateDownloadedMessage`＋動作 `updateRestartAction`，按下呼叫 `install()`），SnackBar 不自動消失。
- 新 ARB key：

| key | zh | en | ja | zh_Hans |
|---|---|---|---|---|
| `updateButtonUpdate` | 更新 | Update | アップデート | 更新 |
| `updateNotesUnavailable` | 目前無法取得更新內容，詳情請見 Google Play。 | Release notes are unavailable right now. See Google Play for details. | 現在アップデート内容を取得できません。詳しくは Google Play をご覧ください。 | 目前无法获取更新内容，详情请见 Google Play。 |
| `updateDownloadedMessage` | 新版本已下載完成 | The update has been downloaded | アップデートのダウンロードが完了しました | 新版本已下载完成 |
| `updateRestartAction` | 重新啟動 | Restart | 再起動 | 重新启动 |

- [ ] **Step 1: 寫失敗的測試**

```dart
// play_update_download_test.dart（fake gateway）
test('download success → downloaded', ...);
test('flexible update denied or failed → no restart prompt', ...);   // denied/failed/throw → 回到 idle，記 log
test('start while downloading does not call the gateway twice', ...);
test('install calls completeFlexible', ...);
// new_version_dialog_test.dart
testWidgets('android: primary button is Update and starts the download', ...);   // isAndroidProvider true
testWidgets('android: empty releases shows the notes-unavailable text and the play tag in the title', ...);
testWidgets('windows: primary button still opens the GitHub page', ...);
// app_shell 相關：既有 app_shell_test 的 _Sync 模式
testWidgets('downloaded update shows a persistent restart snackbar', ...);
```

- [ ] **Step 2: 執行，確認失敗**

Run: `fvm flutter test test/state/play_update_download_test.dart test/widgets/dialogs/new_version_dialog_test.dart test/pages/app_shell_test.dart`
Expected: FAIL

- [ ] **Step 3: 實作**（log：`play flexible update start`、`... result=downloaded|denied|failed`、`play flexible update install`）

- [ ] **Step 4: 執行，確認通過**（同 Step 2 的指令）→ PASS

- [ ] **Step 5: 品質檢查並 commit**

`feat(update): flexible Play update flow with restart prompt`

---

### Task 4: release 簽章、Android 發佈流程、Release 頁尾

**Files:**
- Modify: `android/app/build.gradle.kts`、`.gitignore`、`.github/release-footer.md`
- Create: `.github/workflows/release-android.yml`

**Interfaces:**
- Consumes: Task 1 的 CLI。
- `build.gradle.kts`：
  - `android/key.properties` 存在時，建立 `release` signingConfig（鍵：`storeFile`、`storePassword`、`keyAlias`、`keyPassword`；`storeFile` 是相對於 `android/` 的路徑或絕對路徑），release buildType 使用它。
  - 檔案不存在時，維持用 debug 金鑰（開發者 `flutter run --release` 照常能跑）。
- `.gitignore`：加入 `android/key.properties`、`*.jks`、`*.keystore`。
- `release-android.yml`（`workflow_dispatch`，輸入 `tag` 與可選的 `ref`，預設 `master`）：
  1. checkout `ref`。
  2. 用 Task 1 的 CLI 換算版本代碼；tag 不合法則失敗。
  3. 從 secrets 還原：`ANDROID_UPLOAD_KEYSTORE_BASE64` → `android/upload.jks`；`ANDROID_UPLOAD_STORE_PASSWORD`、`ANDROID_UPLOAD_KEY_ALIAS`、`ANDROID_UPLOAD_KEY_PASSWORD` → `android/key.properties`；`CLOUD_SYNC_CLIENT_ID`／`CLOUD_SYNC_CLIENT_SECRET` → `secrets/cloud_sync_defines.json`（做法沿用 `release-windows.yml`）。任一金鑰 secret 缺少就失敗，不可退回 debug 簽章。
  4. 安裝 Flutter（版本取 `.fvmrc`）、Java 17、Rust toolchain。
  5. `flutter build appbundle --release --build-name <BUILD_NAME> --build-number <VERSION_CODE> --dart-define-from-file=secrets/cloud_sync_defines.json`。
  6. 用 `PLAY_SERVICE_ACCOUNT_JSON` 上傳到 `internal` 軌道，不填版本說明（Action 由實作者選，例如 `r0adkll/upload-google-play`）。
  7. AAB 存成 workflow 產出物。
  8. 最後一定刪除金鑰與 JSON 暫存檔（`if: always()`）。
- `release-footer.md`：「注意 Notice」段改成只針對 Windows。中文開頭改為「**Windows 版**在安裝或執行時…」，英文改為「The **Windows version** may be blocked…」，其餘文字不動。

- [ ] **Step 1: 驗證沒有金鑰時仍可建置**

Run: `fvm flutter build appbundle --release`（確認沒有 `android/key.properties`）
Expected: `✓ Built ...app-release.aab`

- [ ] **Step 2: 實作 gradle 簽章與 .gitignore，再用暫時金鑰驗證**

在 scratch 目錄用 `keytool` 產生一把**丟棄用**的測試金鑰（不是使用者的正式金鑰），寫一份暫時的 `android/key.properties` 指向它，然後：

Run: `fvm flutter build appbundle --release --build-name 1.9.0-rc.1 --build-number 1090001`
Run: `keytool -printcert -jarfile build/app/outputs/bundle/release/app-release.aab`
Expected: 憑證指紋是測試金鑰的指紋，不是 debug 金鑰的 `F8:09:DC:...`。驗證後刪掉暫時的 `key.properties` 與測試金鑰，`git status` 不可出現它們。

- [ ] **Step 3: 寫 `release-android.yml` 並檢查語法**

Run: `actionlint .github/workflows/release-android.yml`（沒有安裝就用 Python `yaml.safe_load` 確認能解析），並逐一比對上列 8 個步驟。

- [ ] **Step 4: 改頁尾，品質檢查並 commit**

`ci(android): sign releases and upload bundles to the Play internal track`

---

### Task 5: 新圖示（全平台）

**Files:**
- Replace: `tool/app_icon_source.png`（由主控在派工前備好，見下）
- Modify: `tool/generate_app_icons.dart`
- Create（由產生腳本輸出）：
  - `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml`
  - 各密度 `mipmap-*/ic_launcher_foreground.png`
  - `android/app/src/main/res/values/ic_launcher_background.xml`
  - `docs/play-store/icon-512.png`

**主控先做：** 用使用者的 `C:\Users\p2902\Downloads\Gemini_Generated_Image_aerz7aerz7aerz7a.jpg`（2048×2048），把四個黑色角落用鄰近的深藍背景補滿成滿版正方形（不改主體），存成 `tool/app_icon_source.png`（1024×1024 PNG）。另外記下背景的平均色碼交給實作者。

**Interfaces:**
- 既有輸出（App 內 UI 三種倍率、Windows `.ico`、legacy mipmap）照舊，由新主檔重產。
- 新增輸出：
  - 自適應圖示：
    - 前景是 108dp 畫布：把整張主檔縮小置中，四周用主檔邊緣像素延伸補滿，前景因此是不透明的、不會有接縫。
    - 縮放比例以「主體落在中央直徑 66dp 的安全圓內」為準，起始值約 72dp，由 Step 2 的遮罩預覽決定。
    - 主體幾乎佔滿原圖，背景又是漸層，所以**不做去背**。
    - 各密度依序為 108、162、216、324、432 px。
    - 背景層用色碼資源 `@color/ic_launcher_background`（主控給的色碼）。
    - `mipmap-anydpi-v26/ic_launcher.xml` 指向前景與背景。
  - Play 512×512 PNG 圖示：滿版、無圓角、無透明。
- 舊的角色圖示：重產時會被覆蓋。另外用 grep 確認 repo 內沒有其他地方引用舊圖（README、文件、assets）。

- [ ] **Step 1: 擴充產生腳本並執行**

Run: `fvm dart run tool/generate_app_icons.dart`
Expected: 每個輸出都印出 `✓`，包含新增的自適應圖示與 `docs/play-store/icon-512.png`。

- [ ] **Step 2: 目視檢查**

把以下三張拼成一張圖檢查：legacy 192 px、自適應前景（套上 72dp 可見區的圓形與方圓形遮罩）、Play 512。

通過條件：主體沒有被裁掉，四周沒有黑邊、白邊或接縫。主體被裁到就縮小比例重產。

- [ ] **Step 3: 建置確認**

Run: `fvm flutter build apk --debug` → `✓ Built`
Windows 圖示在 Task 7 的實機驗收時確認。

- [ ] **Step 4: 品質檢查並 commit**

`feat(branding): replace the app icon on all platforms and add an Android adaptive icon`

---

### Task 6: 上架文件與移植筆記

**Files:**
- Create: `docs/play-store/README.md`（索引與一次性設定步驟）、`docs/play-store/listing.md`（四種語言的商店頁文字）、`docs/play-store/privacy-policy.md`、`docs/play-store/data-safety.md`、`docs/play-store/review-notes.md`
- Modify: `docs/Android移植筆記.md`（新增「十、Play 上架（子專案 7）」）

依 spec 4.6、4.9 與第五節撰寫，至少包含：
- **商店頁**：標題用「工具名 for 遊戲名」，例如「喚取卡池分析 for 鳴潮」、「Convene Analyzer for Wuthering Waves」，每個不超過 30 字。說明開頭加「非官方工具，與庫洛遊戲無關」。簡短說明 80 字內、完整說明 4000 字內。
- **隱私權政策**：依 spec 4.6 列出的實際行為撰寫。
- **資料安全表單**：逐題列出建議答案與理由。
- **審查說明**：
  - 無線偵錯的操作步驟，以及為什麼需要 `WRITE_SECURE_SETTINGS`。
  - 審查人員沒有鳴潮帳號時，怎麼用「手動貼網址」測試。
- **一次性設定步驟**，依序列出：
  1. 用 `keytool` 產生上傳金鑰（PKCS12、RSA 2048 以上、有效期 25 年以上，密碼由使用者自行輸入）。
  2. 建立 `android/key.properties`。
  3. Play Console 建立 App，開啟 Play 應用程式簽署。
  4. 第一次手動上傳 AAB。
  5. 建立服務帳戶並授權給 Play Console。
  6. 設定 GitHub secrets，名稱同 Task 4。
  7. 在 Google Cloud 為 Play 簽署金鑰、上傳金鑰各建一筆 Android OAuth 用戶端。
  8. 填寫內容分級與目標對象。
- **每次發版步驟**：
  1. 跑 Windows 流程。
  2. 跑 Android 流程。
  3. 在 Play Console 填「新功能」並升級到正式版。
  - rc 只放內部測試。
- **上架後**：在頁尾和 README ×4 加上 Google Play 徽章。
- **素材清單**：512 圖示（Task 5 已輸出）、1024×500 主視覺圖（使用者提供）、四種語言的手機截圖。
- **移植筆記第十節**：
  - 版本代碼公式，以及 Windows 為何不用。
  - 簽章設定與 secrets 一覽。
  - SHA-1 一筆對應一個用戶端。
  - in_app_update 不提供版本說明，所以說明仍從 GitHub 取。
  - 用內部應用程式分享測試彈性更新。

- [ ] **Step 1: 撰寫文件**
- [ ] **Step 2: commit**：`docs(play): add Play listing, privacy policy, review notes and release steps`

---

### Task 7: 本機與實機驗收（主控執行）

不寫新程式；發現問題就回到對應的 Task 修正並補測試。這一步**不需要 Play Console**，用 debug 金鑰建置即可。

- [ ] **Step 1：手機安裝本機建置的版本並驗證**（`fvm flutter run` 或 `fvm flutter build apk --release`，沒有 `key.properties` 會用 debug 金鑰）
  - 新圖示在啟動器上正確顯示（圓形、方圓形裁切）。
  - 這個版本不是從 Play 安裝的：啟動時不跳任何更新提示；設定頁手動「檢查更新」顯示 `updateErrorPlay` 的訊息（Review Focus 第 2 點的實機版）。
  - 讀取紀錄、雲端同步照常可用（debug 金鑰的 SHA-1 已登記過）。
- [ ] **Step 2：Windows 驗收**
  - 新圖示出現在工作列、安裝檔、標題列。
  - 檢查更新照舊走 GitHub。

---

## 上架階段（最後執行，不在本輪）

使用者在上架前還有其他修改，所以以下步驟等那些修改完成、使用者說要上架時才做。程式（Task 1–6）已先備妥，屆時不需要再改程式；若發現問題，回到對應 Task 修正。

1. **（使用者）產生上傳金鑰並建立 `android/key.properties`**，依 `docs/play-store/README.md` 的步驟。
2. **本機建置簽章 AAB**：`fvm flutter build appbundle --release --build-name <版本> --build-number <版本代碼> --dart-define-from-file=secrets/cloud_sync_defines.json`。
3. **（使用者）在 Play Console 建立 App 並第一次手動上傳**到內部測試軌道，開啟 Play 應用程式簽署。
4. **（使用者）登記 SHA-1**：把 Play 簽署金鑰與上傳金鑰的 SHA-1，各建一筆 Android OAuth 用戶端（spec 4.5）。
5. **手機從內部測試軌道安裝並驗證**：讀取紀錄的各種方式、雲端同步連結與同步。
6. **用內部應用程式分享測試彈性更新**：分享兩個版本代碼遞增的 AAB，從舊版的分享連結安裝；開啟舊版 → 對話框出現 → 按更新 → 背景下載 → 出現重新啟動提示 → 重新啟動後變成新版本。
7. **截取商店截圖**（從手機用 adb，四種語言；放在最後，畫面才會是修改後的樣子）。
8. **（PR 合併後）跑一次 `release-android.yml`**：AAB 出現在內部測試軌道，版本代碼正確，log 裡沒有任何秘密。
9. **上架後**：頁尾與 README ×4 加 Google Play 徽章。
