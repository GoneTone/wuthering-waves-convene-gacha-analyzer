# Android 取得喚取記錄（子專案 2）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Android 版按「更新資料」能透過 root、Android 10 以下直接讀、或自我配對的無線偵錯讀取 `Client.log` 取得喚取記錄網址；兩個平台都能手動輸入（貼上整段文字或選 `Client.log` 檔案）。

**Architecture:** 把 `PollingClientLogWatch` 的讀檔抽成 `ClientLogSource`（本機檔案／shell），電腦版行為不變；Android 由 `LogAccessResolver` 依 root → 直接讀 → 無線偵錯決定來源，`GachaRepository` 在 Android 走新的等待分支。系統層（Settings.Global、NSD、intent、權限、配對前景服務）集中在一個 Kotlin MethodChannel 與一個 `shortService` 前景服務；配對與 shell 用純 Dart 的 `flutter_adb`。

**Tech Stack:** Flutter 3.47.5（FVM）、Riverpod 3、`flutter_adb` 1.0.0、既有 `flutter_secure_storage`／`file_selector`／`synchronized`、Kotlin（AGP 9）。

**Spec:** `docs/superpowers/specs/2026-11-06-android-credential-capture-design.md`（必讀，第三節是實機事實）

## Global Constraints

- 所有 Flutter／Dart 指令走 `fvm`；commit 前依序 `fvm dart format lib/ test/`、`fvm flutter analyze`（`No issues found!`）、`fvm flutter test`（`All tests passed!`）。
- 不要 `git push`。Commit message 英文 conventional commits，結尾加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` 與當次 session 的 `Claude-Session:` 行。
- 新增 Dart 依賴只有 `flutter_adb: ^1.0.0`。不引入 `device_info_plus`、`permission_handler`、`connectivity_plus`、`flutter_local_notifications`。
- Log 訊息一律英文；Logger 名稱：`capture.android`、`capture.adb`、`capture.pairing`，監看沿用 `gacha.clientLog`。網址、憑證經 `sanitizeUrl`／`sanitizeCredential`，路徑經 `sanitizeFsPath`；配對碼、金鑰絕不入 log。
- 所有宣告（含 private）要有一行 `///` dartdoc；實作層 `//` 註解只寫 WHY。
- UI 文字：繁中全形標點、省略號用 ASCII `...`；一律稱「裝置」不說「手機」（引用系統設定原名例外，例如「關於手機」）。四份核心 ARB（`app_zh.arb`、`app_en.arb`、`app_ja.arb`、`app_zh_Hans.arb`）同步新增，改完跑 `fvm flutter gen-l10n`（generated 檔 gitignore）。
- 新 dialog 一律 `AppDialog`（`lib/widgets/dialogs/app_dialog.dart`）。
- 遊戲套件只支援 `com.kurogame.wutheringwaves.global`；`Client.log` 路徑：`/sdcard/Android/data/com.kurogame.wutheringwaves.global/files/UE4Game/Client/Client/Saved/Logs/Client.log`。
- shell 指令白名單（spec 5.5）：`id`、`stat -c %s '<路徑>'`、`tail -c +<n> '<路徑>' | head -c <n>`、`pm grant|revoke tw.reh.wuwa.gacha android.permission.WRITE_SECURE_SETTINGS`。只插入常數路徑與整數。
- 電腦版既有攔截與 Client.log 監看行為不能變；既有測試全部要繼續通過。
- Ascent 是 AGPL 不可抄；Shizuku（Apache-2.0）只參考做法。
- 每個任務完成時，若有踩到新坑，同步補進 `docs/Android移植筆記.md` 第六節。

## Review Focus

1. `stat` 輸出帶換行、空字串（檔案不存在）或非數字 → 長度視為 0，不丟例外（Task 1 測試）。
2. 貼上的文字裡網址後面緊接全形字（例如 `」`、`。`）或含兩個網址 → 取最新且合法的那個，`recordId` 正確（Task 2 測試）。
3. 使用者在 resolver 還在連線（NSD／重試中）時按取消 → 不能在取消後才啟動監看，本次開啟的無線偵錯要關掉（Task 6 測試）。
4. 抓資料進行中（不在等待）又送出手動輸入 → 忽略，不重入更新（Task 2 測試）。
5. secure storage 讀金鑰丟例外 → 視為未配對並記 warning，不讓更新卡住（Task 4 測試）。

---

## File Structure

| 檔案 | 責任 |
|---|---|
| `lib/services/client_log_source.dart`（新） | `ClientLogSource` 介面、`LocalFileLogSource`、`ShellLogSource`、指令字串產生、`androidClientLogPath` |
| `lib/state/client_log_watch.dart`（改） | 監看改吃 `ClientLogSource`，`start` 改 async，加單次讀取上限 |
| `lib/services/client_log_credential.dart`（改） | 新增 `latestCredentialIn`、`credentialFromClientLogBytes` |
| `lib/state/platform.dart`（新） | `isAndroidProvider` |
| `lib/widgets/dialogs/manual_credential_dialog.dart`（新） | 手動輸入對話框（兩平台） |
| `lib/services/android/log_access_platform.dart`（新） | Kotlin MethodChannel 的 Dart 包裝 |
| `lib/services/android/adb_shell_client.dart`（新） | 連線逐一嘗試、指令排隊與重試、斷線重連；`AdbSession` 介面 |
| `lib/services/android/flutter_adb_session.dart`（新） | `flutter_adb` 實作的 `AdbSession`、`AdbKeyStore` |
| `lib/services/android/root_shell.dart`（新） | `su` 偵測與執行 |
| `lib/services/android/log_access_resolver.dart`（新） | 讀取方式決定、無線偵錯開關規則、`release` |
| `lib/state/adb_pairing.dart`（新） | 配對流程狀態（說明頁→引導→完成／授權失敗） |
| `lib/pages/log_access_setup_page.dart`（新） | 說明頁＋配對引導頁 UI |
| `lib/state/gacha_repository.dart`（改） | Android 等待分支、`submitManualCredential`、`retryLogAccess` |
| `lib/state/update_progress.dart`（改） | `WaitingForCapture.logAccessUnavailable` |
| `lib/widgets/update_progress_dialog.dart`（改） | Android 等待畫面變體、手動輸入連結 |
| `lib/pages/settings_page.dart`（改） | Android「讀取遊戲記錄」區塊；Android 隱藏「遊戲資料夾」 |
| `lib/state/settings.dart`、`lib/services/settings_storage.dart`（改） | `logAccessMethod` 偏好 |
| `android/app/src/main/kotlin/tw/reh/wuwa/gacha/LogAccessChannel.kt`（新） | MethodChannel handler |
| `android/app/src/main/kotlin/tw/reh/wuwa/gacha/AdbPairingService.kt`（新） | 配對前景服務 |
| `android/app/src/main/kotlin/tw/reh/wuwa/gacha/MainActivity.kt`（改） | 註冊 channel、權限結果轉送 |
| `android/app/src/main/AndroidManifest.xml`、`res/values*/strings.xml`（改） | 權限、服務、queries、通知文字四語 |

---

### Task 1: `ClientLogSource` 抽象與監看改寫

**Files:**
- Create: `lib/services/client_log_source.dart`
- Modify: `lib/state/client_log_watch.dart`、`lib/state/gacha_repository.dart:511-513`（呼叫端）
- Test: `test/services/client_log_source_test.dart`（新）、`test/state/client_log_watch_test.dart`、`test/state/gacha_repository_update_test.dart`（`_FakeWatch` 改簽名）

**Interfaces:**
- Produces:
  - `abstract interface class ClientLogSource { Future<int> length(); Future<Uint8List> read(int offset, int length); String get logLabel; }`（`logLabel` 給 log 用，已脫敏）
  - `class LocalFileLogSource implements ClientLogSource { LocalFileLogSource(String path); final String path; }`（檔案不存在 → `length()` 回 0；`logLabel` = `sanitizeFsPath(path)`）
  - `typedef ShellExec = Future<Uint8List> Function(String command);`
  - `class ShellLogSource implements ClientLogSource { ShellLogSource({required ShellExec exec, String path = androidClientLogPath, String label = 'shell'}); }`
  - `const String androidClientLogPath = '/sdcard/Android/data/com.kurogame.wutheringwaves.global/files/UE4Game/Client/Client/Saved/Logs/Client.log';`
  - `String clientLogLengthCommand(String path)` → `"stat -c %s '$path'"`
  - `String clientLogReadCommand(String path, int offset, int length)` → `"tail -c +${offset + 1} '$path' | head -c $length"`；`offset < 0`、`length <= 0` 或 path 含 `'` 時丟 `ArgumentError`
  - `abstract class ClientLogWatch { Future<CaptureSession> start(ClientLogSource source); }`（baseline 長度在回傳 session 前取得）
  - `PollingClientLogWatch({Duration interval = const Duration(seconds: 1), int maxReadBytes = 2 * 1024 * 1024})`

- [ ] **Step 1: 寫 `client_log_source_test.dart` 的失敗測試**

```dart
test('read command quotes path and uses 1-based tail offset', () {
  expect(clientLogReadCommand('/a/Client.log', 0, 10),
      "tail -c +1 '/a/Client.log' | head -c 10");
  expect(clientLogReadCommand('/a/Client.log', 99, 5),
      "tail -c +100 '/a/Client.log' | head -c 5");
});
test('read command rejects quote in path and bad ranges', () {
  expect(() => clientLogReadCommand("/a/x'y", 0, 1), throwsArgumentError);
  expect(() => clientLogReadCommand('/a', -1, 1), throwsArgumentError);
  expect(() => clientLogReadCommand('/a', 0, 0), throwsArgumentError);
});
test('shell length parses trimmed stat output, empty or garbage is 0', () async {
  for (final (out, want) in [('1234\n', 1234), ('', 0), ('stat: No such file\n', 0)]) {
    final src = ShellLogSource(exec: (_) async => Uint8List.fromList(utf8.encode(out)));
    expect(await src.length(), want);
  }
});
test('shell read sends the read command and returns raw bytes', () async {
  final sent = <String>[];
  final src = ShellLogSource(exec: (c) async { sent.add(c); return Uint8List.fromList([1, 2, 3]); });
  expect(await src.read(5, 3), [1, 2, 3]);
  expect(sent.single, clientLogReadCommand(androidClientLogPath, 5, 3));
});
test('local file source: missing file has length 0', () async {
  expect(await LocalFileLogSource('${tmp.path}/nope.log').length(), 0);
});
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/services/client_log_source_test.dart`
Expected: FAIL（`client_log_source.dart` 不存在）

- [ ] **Step 3: 實作 `lib/services/client_log_source.dart`，並把 `PollingClientLogWatch` 改成吃 `ClientLogSource`**

監看邏輯（輪替、carry、由新到舊試網址、錯誤不中斷）保持不變，只把 `File` 的 `exists/length/open/read` 換成 `source.length()`／`source.read()`；`start` 先 `await source.length()` 當 baseline（失敗記 warning 用 0），再開 timer。每輪讀 `min(length - offset, maxReadBytes)`，還有剩就留給下一輪。log 中的路徑改用 `source.logLabel`。`GachaRepository._startClientLogWatch` 改成 `await ref.read(clientLogWatchProvider).start(LocalFileLogSource(GameDirLocator.clientLogPath(location.path)))`，`await` 之後重新檢查 `generation`／`hit.isCompleted`，過期就 `cancel()` 掉剛開的 session。

- [ ] **Step 4: 更新既有測試**

`client_log_watch_test.dart` 的 `begin()` 改成 `Future<CaptureSession> begin() => PollingClientLogWatch(interval: ...).start(LocalFileLogSource(file.path));`，各測試 `final s = await begin();`。新增：

```dart
test('reads large backlog in maxReadBytes chunks', () async {
  final s = await PollingClientLogWatch(interval: const Duration(milliseconds: 20), maxReadBytes: 64)
      .start(LocalFileLogSource(file.path));
  _append(file, '${'x' * 500}\n${_url('C')}\n');
  expect((await _await(s.result))!.recordId, 'C');
});
```

`gacha_repository_update_test.dart` 的 `_FakeWatch.start` 改簽名 `Future<CaptureSession> start(ClientLogSource source) async`，`paths.add((source as LocalFileLogSource).path)`。

- [ ] **Step 5: 跑全部測試**

Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
git add lib/services/client_log_source.dart lib/state/client_log_watch.dart lib/state/gacha_repository.dart test/
git commit -m "refactor(capture): read Client.log through a pluggable source"
```

---

### Task 2: 手動輸入喚取記錄（兩平台）

**Files:**
- Modify: `lib/services/client_log_credential.dart`、`lib/state/client_log_watch.dart`（改用 `latestCredentialIn`）、`lib/state/gacha_repository.dart`、`lib/widgets/update_progress_dialog.dart`、四份 ARB
- Create: `lib/state/platform.dart`、`lib/widgets/dialogs/manual_credential_dialog.dart`
- Test: `test/services/client_log_credential_test.dart`、`test/state/gacha_repository_update_test.dart`、`test/widgets/manual_credential_dialog_test.dart`（新）、`test/widgets/update_progress_dialog_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `ClientLogWatch`
- Produces:
  - `GachaCredential? latestCredentialIn(String text, {void Function(FormatException e)? onRejected})`（`findConveneUrls` 由新到舊試 `GachaCredential.fromConveneUrl`）
  - `GachaCredential? credentialFromClientLogBytes(Uint8List raw)`
  - `final isAndroidProvider = Provider<bool>((ref) => Platform.isAndroid);`
  - `GachaRepository.submitManualCredential(GachaCredential cred) → Future<void>`：等待中（`_logHit` 未完成）→ 完成 `_logHit`；`_isUpdating` 為 false → 以此憑證跑一次更新（不讀快取、不等待）；其他情況（抓資料中）→ 記 info 並忽略
  - `Future<void> showManualCredentialDialog(BuildContext context, {Future<Uint8List?> Function()? pickClientLog})`

- [ ] **Step 1: 寫失敗測試**

`client_log_credential_test.dart`：

```dart
// 飛行模式複製到的整段錯誤頁文字（帳號資料為假值）。
const airplaneText = '網頁無法使用\n無法載入位於 '
    'https://aki-gm-resources-oversea.aki-game.net/aki/gacha/index.html#/record'
    '?svr_id=s1&player_id=700000001&lang=zh-Hant&gacha_id=100087&gacha_type=1'
    '&svr_area=global&record_id=rec1&resources_id=res1&platform=Android '
    '的網頁，原因如下：\n\nnet::ERR_NAME_NOT_RESOLVED';
test('extracts credential from pasted airplane-mode error page', () {
  final c = latestCredentialIn(airplaneText)!;
  expect(c.recordId, 'rec1');
  expect(c.playerId, '700000001');
});
test('url followed by full-width punctuation still parses', () {
  final c = latestCredentialIn('「${_url('rec2')}」。')!;
  expect(c.recordId, 'rec2');
});
test('newest valid url wins over older one', () {
  expect(latestCredentialIn('${_url('old')} ${_url('new')}')!.recordId, 'new');
});
test('no url returns null', () => expect(latestCredentialIn('hello'), isNull));
test('client log bytes are decoded before searching', () {
  expect(credentialFromClientLogBytes(encodeClientLog('x ${_url('r3')}\n'))!.recordId, 'r3');
});
```

（`_url` 沿用該檔或 `client_log_watch_test.dart` 的寫法；`encodeClientLog` 在 `test/helpers/client_log_fixtures.dart`。若「全形標點」測試失敗，代表 `fromConveneUrl` 把 `」` 吃進最後一個參數值——在 `latestCredentialIn` 內先把網址截斷在第一個非 ASCII 字元，不要改 `findConveneUrls` 的 regex，以免影響電腦版 log 解析。）

`gacha_repository_update_test.dart`（新 group `manual credential`）：

```dart
test('manual credential completes the pending wait and fetches', ...);   // _ControlledCapture 不完成；submit 後 capture.cancelCalls == 1，最後 UpdateCompleted
test('manual credential when idle starts an update without capture', ...); // capture fake 若被 start 就 fail
test('manual credential while fetching is ignored', ...);              // MockClient 卡住第一池時 submit，fetch 次數不變、不重入
```

`manual_credential_dialog_test.dart`：貼上無網址文字按確定 → 顯示 `l.manualCredentialNotFound` 且對話框仍在；貼上 `airplaneText` 按確定 → `submitManualCredential` 被呼叫一次且對話框關閉；`pickClientLog` 回傳編碼 bytes → 同上；`isAndroidProvider` override 為 true／false 時，展開「如何取得網址？」分別出現飛行模式說明／Windows 路徑說明。

`update_progress_dialog_test.dart`：`WaitingForCapture()` 時兩平台都有 `l.progressManualInputLink`。

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/services/client_log_credential_test.dart test/state/gacha_repository_update_test.dart test/widgets/`
Expected: FAIL（函式與字串不存在）

- [ ] **Step 3: 實作**

- `latestCredentialIn`、`credentialFromClientLogBytes` 放 `client_log_credential.dart`；`PollingClientLogWatch` 的 for 迴圈改呼叫 `latestCredentialIn(text, onRejected: (e) => _log.warning('client log url rejected reason=${e.message}'))`。
- `submitManualCredential`：log `_clientLog.info('credential source=manual')`；憑證跟其他來源一樣在抓完後由既有流程 `saveCapturedCredential`。
- 對話框（`AppDialog`, `size: AppDialogSize.md`, `scrollable: true`）：多行 `TextField`、「從剪貼簿貼上」（`Clipboard.getData`）、「選擇 Client.log 檔案」（預設用 `file_selector` 的 `openFile` 讀 bytes）、可展開的「如何取得網址？」（`ExpansionTile`），內容依 `isAndroidProvider`。說明文字照 spec 4.3 與畫面稿 v2（`.superpowers/brainstorm/*/content/all-ui-v2.html` 第二段）。
- 等待畫面在既有「沒有反應？」連結下方加「手動輸入喚取記錄」`TextButton`。

ARB 新增（zh 為準，其餘三語對應翻譯）：`progressManualInputLink`「手動輸入喚取記錄」、`manualCredentialTitle`「手動輸入喚取記錄」、`manualCredentialHint`「貼上喚取記錄的網址，或包含網址的整段文字。」、`manualCredentialPaste`「從剪貼簿貼上」、`manualCredentialPickLog`「選擇 Client.log 檔案」、`manualCredentialHowTo`「如何取得網址？」、`manualCredentialNotFound`「找不到喚取記錄網址」、`manualCredentialHelpAndroid`、`manualCredentialHelpWindows`、`manualCredentialWarning`「網址含有帳號憑證，請勿公開分享。網址過一段時間會失效。」。

- [ ] **Step 4: 跑全部測試**

Run: `fvm flutter gen-l10n; fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add lib/ test/
git commit -m "feat(capture): add manual convene record input on all platforms"
```

---

### Task 3: Kotlin 系統層 channel、權限與 Dart 包裝

**Files:**
- Create: `android/app/src/main/kotlin/tw/reh/wuwa/gacha/LogAccessChannel.kt`、`lib/services/android/log_access_platform.dart`
- Modify: `MainActivity.kt`、`AndroidManifest.xml`
- Test: `test/services/android/log_access_platform_test.dart`（新）

**Interfaces:**
- Produces（channel 名 `tw.reh.wuwa.gacha/log_access`；Dart `class LogAccessPlatform`，provider `logAccessPlatformProvider`）：

| Dart 方法 | 回傳 | Kotlin 行為 |
|---|---|---|
| `sdkInt()` | `Future<int>` | `Build.VERSION.SDK_INT` |
| `isWifiConnected()` | `Future<bool>` | `ConnectivityManager` active network 有 `TRANSPORT_WIFI` |
| `isDevelopmentSettingsEnabled()` | `Future<bool>` | `Settings.Global.DEVELOPMENT_SETTINGS_ENABLED == 1` |
| `isAdbWifiEnabled()` | `Future<bool>` | `Settings.Global "adb_wifi_enabled" == 1` |
| `setAdbWifiEnabled(bool)` | `Future<bool>` | 寫入；`SecurityException` 回 false |
| `hasWriteSecureSettings()` | `Future<bool>` | `checkSelfPermission` |
| `discoverAdbConnectPorts()` | `Future<List<int>>` | NSD `_adb-tls-connect._tcp` 收集 2 秒、只留 host 為本機 IP 或 loopback 的結果、去重 |
| `openWirelessDebugging()` | `Future<void>` | spec 3.2 兩段式 intent（帶 `:settings:fragment_args_key`），全失敗退回 `ACTION_APPLICATION_DEVELOPMENT_SETTINGS` |
| `openDeveloperOptions()`、`openDeviceInfoSettings()`、`openAppNotificationSettings()` | `Future<void>` | 對應 `Settings.ACTION_*` |
| `areNotificationsEnabled()` | `Future<bool>` | `NotificationManagerCompat`／`NotificationManager.areNotificationsEnabled()` |
| `requestNotificationPermission()` | `Future<bool>` | API 33+ `requestPermissions(POST_NOTIFICATIONS)`，結果經 `onRequestPermissionsResult` 回傳；33 以下直接回 `areNotificationsEnabled()` |
| `hasStoragePermission()`、`requestStoragePermission()` | `Future<bool>` | `READ_EXTERNAL_STORAGE`（只在 SDK ≤ 29 有意義） |
| `isGameInstalled()`、`launchGame()` | `Future<bool>` | `getLaunchIntentForPackage("com.kurogame.wutheringwaves.global")` |

所有方法遇到 `PlatformException`／`MissingPluginException` 在 Dart 端記 `capture.android` warning 並回保守值（bool → false、list → `[]`），不往外丟。

- [ ] **Step 1: 寫失敗測試**（用 `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler`）

```dart
test('discoverAdbConnectPorts maps list and tolerates errors', ...); // handler 回 [37155, 44091] → [37155, 44091]；丟 PlatformException → []
test('setAdbWifiEnabled false on platform error', ...);
test('missing plugin returns conservative defaults', ...);           // 不設 handler → isWifiConnected() == false
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/services/android/log_access_platform_test.dart`
Expected: FAIL

- [ ] **Step 3: 實作 Dart 包裝與 Kotlin**

`MainActivity` 在 `configureFlutterEngine` 建 `LogAccessChannel(this, flutterEngine.dartExecutor.binaryMessenger)`，並覆寫 `onRequestPermissionsResult` 轉給它。NSD 每次 `resolveService` 在 API < 34 只能一次一個，要排隊解析。

Manifest 新增（spec 第七節）：`WRITE_SECURE_SETTINGS`（`tools:ignore="ProtectedPermissions"`，記得加 `xmlns:tools`）、`POST_NOTIFICATIONS`、`FOREGROUND_SERVICE`、`READ_EXTERNAL_STORAGE`（`android:maxSdkVersion="29"`）、`<application android:requestLegacyExternalStorage="true">`、`<queries><package android:name="com.kurogame.wutheringwaves.global"/></queries>`。

- [ ] **Step 4: 跑測試並建置 APK**

Run: `fvm flutter test; fvm flutter build apk --debug`
Expected: `All tests passed!`；`✓ Built build\app\outputs\flutter-apk\app-debug.apk`

- [ ] **Step 5: Commit**

```bash
git add android/ lib/services/android/log_access_platform.dart test/services/android/
git commit -m "feat(android): add log access platform channel"
```

---

### Task 4: ADB shell 用戶端、金鑰保存與 root shell

**Files:**
- Modify: `pubspec.yaml`（`flutter_adb: ^1.0.0`）
- Create: `lib/services/android/adb_shell_client.dart`、`lib/services/android/flutter_adb_session.dart`、`lib/services/android/root_shell.dart`
- Test: `test/services/android/adb_shell_client_test.dart`、`test/services/android/root_shell_test.dart`、`test/services/android/adb_key_store_test.dart`

**Interfaces:**
- Consumes: Task 1 `ShellExec`
- Produces:
  - `abstract interface class AdbSession { Future<Uint8List> shell(String command); Future<void> close(); }`
  - `typedef AdbConnector = Future<AdbSession?> Function(int port);`
  - `class AdbShellClient { AdbShellClient({required AdbConnector connect, Future<List<int>> Function()? rediscover, Duration retryDelay = const Duration(milliseconds: 300)}); Future<bool> connectAny(List<int> ports); Future<Uint8List> exec(String command); Future<void> close(); bool get isConnected; }`
    - `connectAny`：依序嘗試，對每個連上的 session 先跑 `id`，輸出含 `uid=2000` 才算成功；全部失敗回 false。
    - `exec`：用 `synchronized` 的 `Lock` 排隊；失敗等 `retryDelay` 重試一次；仍失敗且有 `rediscover` → 呼叫它取得新連接埠、`connectAny` 後再試一次；都失敗丟 `AdbShellException`。
  - `class AdbShellException implements Exception { AdbShellException(this.message); final String message; }`
  - `class FlutterAdbSession implements AdbSession`、`Future<AdbSession?> connectFlutterAdb(AdbCrypto crypto, int port)`（host `127.0.0.1`）
  - `class AdbKeyStore { AdbKeyStore({FlutterSecureStorage storage = const FlutterSecureStorage()}); Future<bool> hasKey(); Future<AdbCrypto> loadOrCreate(); Future<void> delete(); }`（key `adb.keypair.v1`，`adbKeyName: 'wuwa-gacha'`；讀取例外 → `hasKey()` 回 false 並記 warning）
  - `Future<bool> pairWithCode({required AdbCrypto crypto, required int port, required String code})`（包 `AdbPairing.pair('127.0.0.1', ...)`，例外回 false）
  - `class RootShell { RootShell({ProcessRunner? run, List<String> suPaths = defaultSuPaths}); Future<bool> isSuPresent(); Future<bool> verify(); Future<Uint8List> exec(String command); }`
    - `typedef ProcessRunner = Future<ProcessResult> Function(String exe, List<String> args);`
    - `const defaultSuPaths = ['/system/bin/su', '/system/xbin/su', '/sbin/su', '/su/bin/su', '/debug_ramdisk/su', '/system_ext/bin/su'];`
    - `verify` 跑 `su -c id`，stdout 含 `uid=0` 才 true；`exec` 用 `stdoutEncoding: null` 取 bytes，非 0 exit 丟 `RootShellException`

- [ ] **Step 1: 寫失敗測試**

```dart
test('connectAny skips refused stale port and uses the next', ...);       // connector: 44091 → null, 38435 → fake session 回 'uid=2000(shell)'；結果 true，exec 走 38435
test('exec retries once after a stream open failure', ...);               // fake session 第一次 shell 丟例外、第二次成功；只重試一次
test('exec reconnects via rediscover when retry also fails', ...);
test('exec calls are serialized', ...);                                    // 兩個 exec 同時呼叫，fake 記錄進出順序不交錯
test('key store read failure is treated as not paired', ...);             // FlutterSecureStorage fake read 丟例外 → hasKey() false
test('root verify requires uid=0', ...);                                  // run 回 'uid=2000' → false；'uid=0(root)' → true
test('su absent means no process is spawned', ...);                       // suPaths 都不存在 → isSuPresent false，run 未被呼叫
```

（`FlutterSecureStorage` 在測試用 `FlutterSecureStorage.setMockInitialValues` 或注入 fake。）

- [ ] **Step 2: 跑測試確認失敗**

Run: `fvm flutter test test/services/android/`
Expected: FAIL

- [ ] **Step 3: 實作**（`fvm flutter pub add flutter_adb:^1.0.0`；API 用法參考移植筆記第 2、19 節與 spike：`AdbCrypto(keyPair: AdbCrypto.keyPairFromStorageMap(map), adbKeyName: ...)`、`exportKeyPairForStorage()`、`AdbConnection(host, port, crypto).connect()`、`open('shell:$cmd')` 收 `onPayload` 到 `onDone`、逾時 20 秒）

- [ ] **Step 4: 跑全部測試**

Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/services/android/ test/services/android/
git commit -m "feat(android): add adb shell client, key store and root shell"
```

---

### Task 5: 讀取方式決定（`LogAccessResolver`）與偏好保存

**Files:**
- Create: `lib/services/android/log_access_resolver.dart`
- Modify: `lib/state/settings.dart`、`lib/services/settings_storage.dart`
- Test: `test/services/android/log_access_resolver_test.dart`、`test/state/settings_test.dart`（或既有 settings 測試檔）

**Interfaces:**
- Consumes: Task 3 `LogAccessPlatform`、Task 4 `AdbShellClient`／`AdbKeyStore`／`RootShell`、Task 1 `ShellLogSource`／`LocalFileLogSource`
- Produces:
  - `enum LogAccessMethod { root, legacyDirect, wirelessDebugging }`
  - `enum LogAccessUnavailable { notPaired, noWifi, adbConnectFailed, wirelessDebuggingOff, storagePermissionDenied, unsupported }`
  - `sealed class LogAccessOutcome`；`final class LogAccessReady extends LogAccessOutcome { LogAccessReady({required this.source, required this.method, required this.release}); final ClientLogSource source; final LogAccessMethod method; final Future<bool> Function() release; }`（`release` 回傳 true 代表「照規則應該關掉無線偵錯，但沒有權限關」，也就是手動開關模式下要提示玩家自行關閉）；`final class LogAccessBlocked extends LogAccessOutcome { LogAccessBlocked(this.reason); final LogAccessUnavailable reason; }`
  - `class LogAccessResolver { Future<LogAccessOutcome> resolve({LogAccessMethod? preferred, bool forceDisableAfterUse = false}); }`，provider `logAccessResolverProvider`
  - `SettingsNotifier.setLogAccessMethod(LogAccessMethod? method)`；`SettingsState.logAccessMethod`（存 `pref.logAccessMethod`，enum name 字串）

決定順序（`preferred` 不為 null 時先試它，失敗再依序）：
1. root：`isSuPresent() && verify()` → `ShellLogSource(exec: root.exec, label: 'root')`，`release` 為 no-op。
2. `sdkInt() <= 29`：`hasStoragePermission()` 否則 `requestStoragePermission()`；拒絕 → `Blocked(storagePermissionDenied)`；成功 → `LocalFileLogSource(androidClientLogPath)`。
3. `sdkInt() >= 30`：`!hasKey` → `notPaired`；`!isWifiConnected` → `noWifi`；`wasOn = isAdbWifiEnabled()`；`!wasOn` 時 `setAdbWifiEnabled(true)`，回 false → `wirelessDebuggingOff`；`discoverAdbConnectPorts()` 最多 5 次間隔 1 秒，`connectAny` 失敗 → `adbConnectFailed`（若本次開過就關回去）。連上後若 `!hasWriteSecureSettings()` 就 `exec('pm grant tw.reh.wuwa.gacha android.permission.WRITE_SECURE_SETTINGS')`（失敗只記 warning）。`release`：`client.close()`；`(!wasOn || forceDisableAfterUse)` 時：有 `hasWriteSecureSettings()` 就 `setAdbWifiEnabled(false)` 並回 false，沒有就回 true（留著開）；其他情況回 false。root／直接讀的 `release` 一律回 false。`AdbShellClient.rediscover` 傳入「必要時重開無線偵錯＋重新 discover」。
4. `sdkInt() < 24` 不會發生（minSdk 24）；其他無法判斷 → `unsupported`。

- [ ] **Step 1: 寫失敗測試**（fake platform／root／key store／connector）

```dart
test('root wins when su present and verified', ...);
test('root denied falls through to wireless debugging', ...);
test('android 10 with permission uses local file source', ...);
test('android 10 permission denied is blocked', ...);
test('not paired is blocked before touching wifi debugging', ...);    // setAdbWifiEnabled 未被呼叫
test('no wifi is blocked', ...);
test('cannot enable wifi debugging means manual toggle mode', ...);   // setAdbWifiEnabled 回 false → wirelessDebuggingOff
test('release turns wifi debugging off only if we turned it on', ...); // wasOn true → 不關；false → 關
test('forceDisableAfterUse turns it off even if it was on', ...);
test('connect failure turns wifi debugging back off', ...);
test('grants write secure settings once when missing', ...);
test('preferred method is tried first', ...);                        // preferred: wirelessDebugging 時不呼叫 root.verify
```

- [ ] **Step 2–4: 跑測試確認失敗 → 實作 → 全部測試通過**

Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add lib/ test/
git commit -m "feat(android): resolve how to read the game log"
```

---

### Task 6: `GachaRepository` 的 Android 等待分支與等待畫面

**Files:**
- Modify: `lib/state/gacha_repository.dart`、`lib/state/update_progress.dart`、`lib/widgets/update_progress_dialog.dart`、四份 ARB
- Test: `test/state/gacha_repository_android_test.dart`（新）、`test/widgets/update_progress_dialog_test.dart`

**Interfaces:**
- Consumes: Task 5 `LogAccessResolver`／`LogAccessOutcome`／`setLogAccessMethod`、Task 2 `isAndroidProvider`／`submitManualCredential`、Task 3 `isGameInstalled`／`launchGame`／`openWirelessDebugging`／`requestStoragePermission`
- Produces:
  - `WaitingForCapture({..., LogAccessUnavailable? logAccessUnavailable})`：非 null 表示沒有自動讀取方式（畫面不顯示進度條）
  - `GachaRepository.retryLogAccess() → Future<void>`：只在 `WaitingForCapture.logAccessUnavailable != null` 時重新 resolve；成功就切到正常等待
  - `GachaRepository.update({bool afterPairing = false})`：`afterPairing` 傳給 `resolve(forceDisableAfterUse: true)`
  - 兩處 `_runMitm(isFallback: ...)` 改呼叫 `_acquireCredential(isFallback: ...)`：Android → `_runAndroidWait`，其他 → 原 `_runMitm`

`_runAndroidWait` 流程：
1. `state = WaitingForCapture(isFallback)`；建立 `_logHit`、`_waitCancelled`（沿用既有欄位，讓 `submitManualCredential`／`cancelCapture` 直接可用）。
2. `resolve(preferred: settings.logAccessMethod, forceDisableAfterUse: afterPairing)`；resolve 期間被取消 → 拿到 `Ready` 也立刻 `release()` 並回 null。
3. `Ready` → `setLogAccessMethod(method)`、`await watch.start(source)`、等 `logHit`／`waitCancelled`；結束一律停監看並 `release()`（`finally`）。`release()` 回 true 時記下來，這次的 `UpdateCompleted` 帶 `wirelessDebuggingLeftOn: true`（新欄位，預設 false），完成畫面多一行 `progressWirelessLeftOnHint`「無線偵錯仍是開啟的，可以到系統設定自行關閉。」。
4. `Blocked` → `state = WaitingForCapture(isFallback, logAccessUnavailable: reason)`，等 `logHit`（手動）／`waitCancelled`／`retryLogAccess` 觸發的重新 resolve。
5. log：`capture.android` 記 method、reason、耗時；命中記 `credential source=log`／`manual`。

等待畫面（`update_progress_dialog.dart`，`isAndroidProvider` 為 true 時）：
- 標題 `progressWaitingLog`「等待喚取記錄...」（電腦版維持 `progressWaiting`）。
- 正常：既有提示＋「開啟鳴潮」`FilledButton`（`isGameInstalled()` 為 true 才顯示）＋「手動輸入喚取記錄」；不顯示「沒有反應？」。
- `logAccessUnavailable != null`：標題 `progressLogUnavailableTitle`「無法自動讀取喚取記錄」、不顯示進度條、顯示原因文字與按鈕：

| reason | 原因文字 key | 主要按鈕 |
|---|---|---|
| `notPaired` | `logUnavailableNotPaired`「尚未設定讀取遊戲記錄的方式。設定一次之後，每次更新都會自動讀取。」 | 「設定讀取方式」→ `cancelCapture()` 後 push `LogAccessSetupPage`（Task 7） |
| `noWifi` | `logUnavailableNoWifi`「無線偵錯只能在連上 Wi‑Fi 時使用。請連上 Wi‑Fi 後再按一次更新，或改用手動輸入。」 | 無 |
| `adbConnectFailed` | `logUnavailableAdbFailed`「連不上無線偵錯。可能是配對已失效，請重新配對。」 | 「重新配對」（同「設定讀取方式」） |
| `wirelessDebuggingOff` | `logUnavailableWirelessOff`「你的裝置不允許本 App 自動開啟無線偵錯。請在無線偵錯頁打開開關，再回到本 App，就會自動繼續。」 | 「前往無線偵錯」→ `openWirelessDebugging()` |
| `storagePermissionDenied` | `logUnavailableStorage`「需要儲存空間權限才能讀取遊戲記錄。」 | 「重新授權」→ `requestStoragePermission()` 後 `retryLogAccess()` |
| `unsupported` | `logUnavailableUnsupported`「這台裝置無法自動讀取遊戲記錄，請改用手動輸入。」 | 無 |

  每種都有「手動輸入喚取記錄」與「取消」。對話框掛 `AppLifecycleListener(onResume: repo.retryLogAccess)`。

- [ ] **Step 1: 寫失敗測試**（`isAndroidProvider` override true、fake resolver、`_FakeWatch` 沿用 Task 1 簽名）

```dart
test('android ready: watches source, persists method, releases after hit', ...);
test('android blocked: waits for manual input without watching', ...);
test('retryLogAccess switches blocked wait to watching', ...);
test('cancel during slow resolve releases access and never watches', ...); // Review Focus 3
test('fallback after all pools fail waits again on android', ...);
test('afterPairing passes forceDisableAfterUse', ...);
test('release left wireless debugging on → UpdateCompleted.wirelessDebuggingLeftOn', ...);
test('shell read failures during wait keep waiting', ...);                  // fake source 連續丟例外後恢復，最後仍命中
test('windows path still uses capture race', ...);                          // isAndroidProvider false → _ControlledCapture 被 start
```

widget：Android 正常狀態有「開啟鳴潮」（fake `isGameInstalled` true）、沒有「沒有反應？」；六種 reason 顯示對應文字與按鈕；電腦版不受影響。

- [ ] **Step 2–4: 跑測試確認失敗 → 實作 → 全部測試通過**

Run: `fvm flutter gen-l10n; fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add lib/ test/
git commit -m "feat(android): wait for the convene url through the game log"
```

---

### Task 7: 配對前景服務、說明頁與配對引導

**Files:**
- Create: `android/app/src/main/kotlin/tw/reh/wuwa/gacha/AdbPairingService.kt`、`lib/state/adb_pairing.dart`、`lib/pages/log_access_setup_page.dart`
- Modify: `LogAccessChannel.kt`、`AndroidManifest.xml`、`android/app/src/main/res/values*/strings.xml`（四語）、`lib/services/android/log_access_platform.dart`、四份 ARB
- Test: `test/state/adb_pairing_test.dart`、`test/pages/log_access_setup_page_test.dart`

**Interfaces:**
- Consumes: Task 3 platform、Task 4 `AdbKeyStore`／`pairWithCode`／`AdbShellClient`／`connectFlutterAdb`、Task 6 `update(afterPairing: true)`
- Produces:
  - Platform 新增：`startPairingService()`、`stopPairingService()`、`isPairingServiceRunning() → Future<bool>`、`setPairingCodeHandler(Future<({bool ok, String message})> Function(int port, String code)? handler)`（Kotlin 以 `invokeMethod("pairCode", {port, code})` 呼叫並等待回傳 `{ok, message}`）
  - `enum PairingPhase { disclosure, needDevOptions, needNotifications, ready, waitingCode, pairing, grantFailed, done }`
  - `class AdbPairingState { final PairingPhase phase; final String? error; }`
  - `class AdbPairingController extends Notifier<AdbPairingState>`（provider `adbPairingProvider`）：`refresh()`、`startSetup()`、`openWirelessDebugging()`（啟動服務＋跳轉）、`retryGrant()`、`skipGrant()`、`handlePairingCode(int port, String code)`（`build` 時註冊為 handler，dispose 時清掉）
  - `class LogAccessSetupPage extends ConsumerStatefulWidget`（route 入口；`onResume` 呼叫 `refresh()`；`done` 後 `Navigator.pop` 並 `update(afterPairing: true)`；`grantFailed` 選略過後同樣 pop 並更新）

Kotlin 服務（`android:foregroundServiceType="shortService"`、`exported="false"`）：
- `ACTION_START`：建 channel（`IMPORTANCE_HIGH`），`startForeground`（API 34+ 帶 `FOREGROUND_SERVICE_TYPE_SHORT_SERVICE`），NSD 找 `_adb-tls-pairing._tcp`（只留本機 IP），找到後更新為可輸入通知（`RemoteInput` key `pairing_code`、`PendingIntent.getForegroundService` + `FLAG_MUTABLE`），附「停止」。啟動 3 分鐘自我計時。
- `ACTION_REPLY`：先 `startForeground`；`MainActivity` 的 channel 不在 → 通知「配對失敗，請回到 App 再試一次」並停止；否則 `invokeMethod("pairCode")`，成功 → 「配對成功，點這裡回到 App」（點了開 `MainActivity`），4 秒後停止；失敗 → 「配對失敗：<message>，請重新輸入」保留輸入框。
- 計時到或 `onTimeout`（API 34+）→ 停止並發非前景通知「配對逾時，點這裡重新開始」（開 `MainActivity`）。
- 通知文字放 `res/values*/strings.xml` 四語（en、zh-rTW、zh-rCN、ja）。配對碼不寫 log（`Log` tag `capture.pairing` 只記狀態）。

`handlePairingCode`：`keyStore.loadOrCreate()` → `pairWithCode` → 成功後 `discoverAdbConnectPorts` + `connectAny` → `pm grant ...` → `hasWriteSecureSettings()` 為 true → `done`，否則 `grantFailed`；斷線。失敗訊息不含配對碼。

頁面內容依畫面稿 v2 第三、五段（3a～3d、5a、5b），步驟清單形式；`needDevOptions` 的按鈕開 `openDeviceInfoSettings()`；`needNotifications` 被拒時改顯示「前往通知設定」；`grantFailed` 教學為通用說明再舉例（小米「USB 偵錯（安全性設定）」、OPPO／realme「停用權限監控」），按鈕「前往開發人員選項」「重試」「略過（每次更新時手動開啟無線偵錯）」。

- [ ] **Step 1: 寫失敗測試**（fake platform／key store／pair 函式／connector）

```dart
test('refresh: dev options off → needDevOptions; on but no notifications → needNotifications; both → ready', ...);
test('service is not started until openWirelessDebugging', ...);
test('pairing code success with grant → done', ...);
test('pairing code success but grant fails → grantFailed', ...);
test('wrong code returns ok=false without leaking the code', ...);  // 回傳 message 不含 code 字串
test('refresh restarts service when waiting and service stopped', ...);
test('skipGrant ends setup as done-without-toggle', ...);
```

widget：每個 phase 顯示對應標題與按鈕；`done` 時 pop 並呼叫 `update(afterPairing: true)`（fake repository 記錄）。

- [ ] **Step 2–4: 跑測試確認失敗 → 實作 → 全部測試通過，並建置 APK**

Run: `fvm flutter gen-l10n; fvm flutter test; fvm flutter build apk --debug`
Expected: `All tests passed!`；APK 建置成功

- [ ] **Step 5: Commit**

```bash
git add android/ lib/ test/
git commit -m "feat(android): pair wireless debugging through a notification"
```

---

### Task 8: 設定頁「讀取遊戲記錄」區塊與解除配對

**Files:**
- Modify: `lib/pages/settings_page.dart`、四份 ARB
- Test: `test/pages/settings_page_log_access_test.dart`（新）

**Interfaces:**
- Consumes: Task 5 `logAccessMethod`／`setLogAccessMethod`、Task 4 `AdbKeyStore`、Task 3 `hasWriteSecureSettings`、Task 7 `LogAccessSetupPage`、Task 5 resolver（解除配對時連線用）
- Produces: `class _LogAccessSection extends ConsumerWidget`（只在 `isAndroidProvider` 為 true 時插入；同時 Android 不插入 `_GameDirSection`）

內容（畫面稿 v2 第六段）：
- 讀取方式：`root`／`直接讀取`／`無線偵錯`／`尚未設定`（依 `logAccessMethod`；`wirelessDebugging` 但 `hasKey()` 為 false 視為尚未設定）。
- 無線偵錯：配對狀態「已配對」或「已配對（需手動開啟無線偵錯）」（`hasWriteSecureSettings()` false）；後者多「重試授權」（push `LogAccessSetupPage`，直接進 `grantFailed` 階段）。
- 「解除配對」：`AppDialog` 確認 → 嘗試 resolve 連線，連上就 `exec('pm revoke tw.reh.wuwa.gacha android.permission.WRITE_SECURE_SETTINGS')` 再 `release()` → `keyStore.delete()` → `setLogAccessMethod(null)`；連不上時 SnackBar 提示「可以到系統的『無線偵錯 → 已配對的裝置』移除」。
- 尚未設定：「設定」→ push `LogAccessSetupPage`。

- [ ] **Step 1: 寫失敗測試**

```dart
testWidgets('android shows log access section and hides game dir', ...);
testWidgets('windows hides log access section', ...);
testWidgets('manual-toggle mode shows warning badge and retry grant', ...);
testWidgets('unpair revokes, deletes key and clears method', ...);
testWidgets('unpair when unreachable still deletes key and shows hint', ...);
```

- [ ] **Step 2–4: 跑測試確認失敗 → 實作 → 全部測試通過**

Run: `fvm flutter gen-l10n; fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add lib/ test/
git commit -m "feat(android): add log access settings and unpairing"
```

---

### Task 9: 實機與模擬器驗證、文件

**Files:**
- Modify: `docs/Android移植筆記.md`（第六節補實作踩雷）、`docs/superpowers/specs/2026-11-06-android-credential-capture-design.md`（驗證結果；尚未驗證項目更新）

- [ ] **Step 1: ASUS 實機（spec 第十節清單）**：全新安裝走完說明頁→配對→自動更新；關無線偵錯、重開機、換 Wi‑Fi 後各更新一次；等待中切去遊戲再切回；配對逾時後重新開始；手動輸入（飛行模式整段文字、選 Client.log 檔案）；解除配對後再按更新出現「設定讀取方式」；用 `adb shell pm revoke tw.reh.wuwa.gacha android.permission.WRITE_SECURE_SETTINGS` 模擬手動開關模式。每項用 `adb logcat -s flutter:I capture.pairing:*` 確認 log 無憑證與配對碼。
- [ ] **Step 2: 模擬器**：Android 10、Android 9（放假的 `Client.log` 到遊戲路徑，確認直接讀取）；Android 12 或 13（配對服務與 3 分鐘自行逾時）；有 root 的模擬器（`su` 路徑）。
- [ ] **Step 3: 電腦版回歸**：`fvm flutter build windows --release` 後，攔截更新、Client.log 監看、手動輸入（貼上與選檔）各一次。
- [ ] **Step 4: 更新文件並 commit**

```bash
git add docs/
git commit -m "docs(android): record credential capture verification"
```

- [ ] **Step 5: 清理**：從測試裝置移除 `pair_spike`、`adb_spike`、`luckdraw_spike`（使用者同意後）。
