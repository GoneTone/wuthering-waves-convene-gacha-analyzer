# Client.log 喚取憑證備援 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 等待攔截期間，背景同時監看遊戲的 `Client.log`，抓到新寫入的喚取 URL 就轉成 `GachaCredential` 跟攔截比快；找不到遊戲資料夾時，使用者可以從等待畫面或設定頁手動指定。

**Architecture:** 純 Dart 實作。純函式層（XOR 解碼、抓 URL、URL→憑證），加上 `GameDirLocator`（設定 → 登錄檔 → 常見路徑）和 `ClientLogWatch`（每秒檢查檔案長度、從 offset 讀新增的 bytes）。`GachaRepository._runMitm` 讓攔截和 log 比快。log 監看器沿用既有的 `CaptureSession` 型別，所以比快邏輯是對稱的。

**Tech Stack:** Flutter 3.47.5（FVM）、Riverpod 3（`NotifierProvider`／`Provider`）、`file_selector`（選資料夾）、`dart:io`（`RandomAccessFile`、`Process.run('reg', ...)`）。**不新增任何依賴。**

**Spec:** `docs/superpowers/specs/2026-11-01-client-log-credential-fallback-design.md`

## Global Constraints

- 所有 Flutter／Dart 指令一律用 `fvm flutter`／`fvm dart`；格式化只跑 `fvm dart format lib/ test/`。
- 每個宣告都要有一行 `///` dartdoc（Flutter override 除外）。實作層的 `//` 註解只寫「為什麼」。
- Log 訊息一律用英文；logger 名稱用 `gacha.clientLog`；路徑一律經過 `sanitizeFsPath`；憑證一律經過 `sanitizeCredential`。**禁止 log 喚取 URL 原文**（`sanitizeUrl` 遮不到 fragment 裡的 `record_id`）。
- Dialog 一律用 `AppDialog`（`size: AppDialogSize.sm`）。
- 新字串只寫進 `app_zh.arb`（template，含 `@key` metadata）、`app_zh_Hans.arb`、`app_en.arb`、`app_ja.arb` 四份，四份都要有完整的 `@` metadata。`lib/l10n/generated/` 是 gitignore，不 commit。CJK 用全形標點，省略號用 ASCII `...`。
- 只比對國際服 URL host：`aki-gm-resources-oversea.aki-game.net`。
- XOR 規則：`b ^ ((b & 1) != 0 ? 0xA5 : 0xEF)`。
- URL→欄位：`player_id→playerId`、`svr_id→serverId`、`resources_id→cardPoolId`（**不是** `gacha_id`）、`record_id→recordId`、`lang→languageCode`。
- 遊戲資料夾有效 ⇔ `<dir>\Client\Saved\Logs\Client.log` 存在。
- 設定 key：`pref.gameDir`，只存在本機，不加入雲端同步。
- log 監看器的任何失敗都**不能**讓更新失敗，只寫 log。
- Commit message 用英文 conventional commits，結尾附上 attribution 兩行。不要 push。

## Review Focus

1. **log 勝出時攔截端還沒停乾淨**：一定要 `await` 攔截 `result` 完成才開始拉取；收尾丟錯只記 `warning`，用 log 的憑證繼續（Task 5 測試）。
2. **log 勝出後、收尾期間使用者按取消**：要中止更新、清掉 progress，不能繼續拉取（Task 5 測試）。
3. **選了資料夾後才開歷史頁**：基準點重算，選之前已寫進去的 URL 不採用，選之後新寫的要採用（Task 4 和 Task 5 測試）。
4. **說明視窗開著時狀態離開等待**（成功、取消、失敗）：說明視窗和進度視窗都要正確關閉，不能關錯（Task 6 測試）。
5. **檔案被輪替或縮小、URL 被切在兩次讀取之間**：都不能漏抓，也不能把舊 URL 當新的（Task 4 測試）。

---

### Task 1: URL 解析與 log 解碼純函式

**Files:**
- Create: `lib/services/client_log_credential.dart`
- Modify: `lib/services/gacha_credential.dart`（新增 factory）
- Test: `test/services/client_log_credential_test.dart`、`test/services/gacha_credential_test.dart`（追加）

**Interfaces:**
- Produces:
  - `Uint8List decodeClientLogBytes(Uint8List raw)`：回傳新的 buffer，不改輸入。
  - `String? findLastConveneUrl(String text)`：沒有符合的 URL 時回傳 null。
  - `factory GachaCredential.fromConveneUrl(String url)`：缺欄位或格式錯誤時丟 `FormatException`。

- [ ] **Step 1: 寫失敗測試**
  - `decodeClientLogBytes([0xE5])` 等於 `[0x0A]`；`decodeClientLogBytes([0x0A])` 等於 `[0xE5]`；`decodeClientLogBytes(encode('abc'))` 等於 `'abc'`（測試裡用同一套 XOR 寫個 `encode` helper，因為這套運算自己就是反函式）。
  - `findLastConveneUrl`：文字裡有兩筆 `https://aki-gm-resources-oversea.aki-game.net/aki/gacha/index.html#/record?...&record_id=A...` 和 `...record_id=B...` 時，回傳 B 那筆。URL 結尾在 `"`、`,`、空白或換行時都要停下。只有國服 host `aki-gm-resources.aki-game.com` 時回傳 null。
  - `fromConveneUrl`：輸入 `...#/record?svr_id=S&player_id=123456789&lang=zh-Hant&gacha_id=G&gacha_type=1&svr_area=global&record_id=R&resources_id=C&platform=PC`，期望 `playerId=='123456789'`、`serverId=='S'`、`cardPoolId=='C'`、`recordId=='R'`、`languageCode=='zh-Hant'`。缺 `record_id` 時丟 `FormatException`。值有 percent-encoding 時要解碼（例如 `lang=zh%2DHant` 變成 `zh-Hant`）。
- [ ] **Step 2: 跑測試確認失敗**：`fvm flutter test test/services/client_log_credential_test.dart test/services/gacha_credential_test.dart`，期望 FAIL（找不到函式）。
- [ ] **Step 3: 實作**
  - regex：`https://aki-gm-resources-oversea\.aki-game\.net/aki/gacha/index\.html#/record[^"\s,]*`
  - `fromConveneUrl`：取 `#` 之後、`?` 之後的部分，用 `Uri.splitQueryString` 解析，再依 Global Constraints 的欄位表取值。必要欄位是空字串或不存在時，丟 `FormatException('convene url missing field "<key>"')`。
- [ ] **Step 4: 跑測試確認通過**：同 Step 2 指令，期望 PASS。
- [ ] **Step 5: Commit**：`feat(capture): parse convene credential from game log url`

---

### Task 2: 設定新增 `gameDir`

**Files:**
- Modify: `lib/services/settings_storage.dart`（`AppSettings` 欄位、`copyWith`、`_kGameDir = 'pref.gameDir'`、`load`／`save`）
- Modify: `lib/state/settings.dart`（新增 `setGameDir`）
- Test: `test/services/settings_storage_test.dart`（storage 讀寫）、`test/state/settings_test.dart`（notifier），兩個都追加。

**Interfaces:**
- Produces：`AppSettings.gameDir`（`String?`）、`copyWith({String? gameDir, bool clearGameDir = false})`、`Future<void> SettingsNotifier.setGameDir(String? dir)`（null 代表清除）。

- [ ] **Step 1: 寫失敗測試**：`setGameDir(r'D:\Wuthering Waves\Wuthering Waves Game')` 之後，`SettingsStorage.load()` 讀回同一個值；`setGameDir(null)` 之後，讀回 null，而且 prefs 裡沒有 `pref.gameDir` 這個 key。
- [ ] **Step 2: 跑測試確認失敗**
- [ ] **Step 3: 實作**：照 `skippedReleaseTag` 的寫法（null 就 `remove`）。`setGameDir` 要記 `Logger('app.settings').info('gameDir set source=manual path=${sanitizeFsPath(dir)}')`，null 時記 `cleared`。
- [ ] **Step 4: 跑測試確認通過**
- [ ] **Step 5: Commit**：`feat(settings): persist game directory preference`

---

### Task 3: `GameDirLocator`

**Files:**
- Create: `lib/services/game_dir_locator.dart`
- Test: `test/services/game_dir_locator_test.dart`

**Interfaces:**
- Produces:
  ```dart
  enum GameDirSource { setting, registry, common }
  class GameDirLocation { const GameDirLocation(this.path, this.source); final String path; final GameDirSource source; }
  typedef RegistryInstallPathReader = Future<List<String>> Function(); // 回傳所有讀到的 InstallPath（啟動器資料夾）
  class GameDirLocator {
    GameDirLocator({RegistryInstallPathReader? readInstallPaths, List<String>? commonDirs});
    Future<GameDirLocation?> locate({String? settingDir});
    Future<String?> normalize(String picked); // 有效 → 回傳遊戲資料夾；選到啟動器資料夾 → 自動修正；都不符合 → null
    static String clientLogPath(String gameDir); // <gameDir>\Client\Saved\Logs\Client.log
  }
  final gameDirLocatorProvider = Provider<GameDirLocator>((ref) => GameDirLocator());
  ```

- [ ] **Step 1: 寫失敗測試**（在 temp dir 建立假的資料夾結構）
  - `normalize(gameDir)` 回傳 `gameDir` 本身；`normalize(launcherDir)` 在 `launcherDir\Wuthering Waves Game\Client\Saved\Logs\Client.log` 存在時，回傳 `launcherDir\Wuthering Waves Game`；`normalize(emptyDir)` 回傳 null。
  - `locate(settingDir: valid)` 的 source 是 `setting`；設定的資料夾無效時，退回 reader 回傳的 `[launcherDir]`，source 是 `registry`；reader 回傳空清單時，用 `commonDirs` 裡第一個有效的，source 是 `common`；全部都無效時回傳 null。
  - reader 丟例外時，`locate` 不丟例外，繼續往下一個來源找。
- [ ] **Step 2: 跑測試確認失敗**
- [ ] **Step 3: 實作**
  - 預設 reader：依序對下面三個 key 跑 `Process.run('reg', ['query', key, '/v', 'InstallPath'])`，exit 0 時用 `RegExp(r'InstallPath\s+REG_SZ\s+(.+)$', multiLine: true)` 取值（記得 trim）。
    - `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\KRInstall Wuthering Waves Overseas`（維護者本機實測就在這裡）
    - `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\KRInstall Wuthering Waves Overseas`
    - `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\KRInstall Wuthering Waves Overseas`
  - 預設 `commonDirs`：至少包含 `C:\Program Files\Wuthering Waves\Wuthering Waves Game`（#92 回報者的位置）、`C:\Wuthering Waves\Wuthering Waves Game`、`C:\Program Files (x86)\Steam\steamapps\common\Wuthering Waves\Wuthering Waves Game`。Epic、Xbox 的路徑由實作者查證後補上；查不到就不加。
  - registry 和 common 都要經過 `normalize`。`locate` 的結果用 `Logger('gacha.clientLog')` 記 `game dir resolved source=<s> path=<sanitizeFsPath>` 或 `game dir not found`。
- [ ] **Step 4: 跑測試確認通過**
- [ ] **Step 5: Commit**：`feat(capture): locate game directory for client log`

---

### Task 4: `ClientLogWatch` 監看器

**Files:**
- Create: `lib/state/client_log_watch.dart`
- Test: `test/state/client_log_watch_test.dart`

**Interfaces:**
- Consumes：Task 1 的 `decodeClientLogBytes`、`findLastConveneUrl`、`GachaCredential.fromConveneUrl`；既有的 `CaptureSession`（`lib/state/gacha_capture.dart`）。
- Produces:
  ```dart
  abstract class ClientLogWatch { CaptureSession start(String clientLogPath); }
  class PollingClientLogWatch implements ClientLogWatch {
    PollingClientLogWatch({Duration interval = const Duration(seconds: 1)});
  }
  final clientLogWatchProvider = Provider<ClientLogWatch>((ref) => PollingClientLogWatch());
  ```
  `result` 在命中時 complete 成憑證；`cancel()` 後 complete 成 null。**永遠不會 completeError**（錯誤只記 log）。

- [ ] **Step 1: 寫失敗測試**（用真的 temp 檔案，`interval: Duration(milliseconds: 20)`；寫入時用 Task 1 測試的 `encode`）
  - `ignores url written before start`：先寫入一筆 URL A 再 `start`，等 200ms，`result` 還沒 complete；`cancel()` 後 `result` 是 null。
  - `completes with url appended after start`：`start` 之後 append 一行含 URL B 的內容加 `\n`，`result` 的 `recordId` 是 B。
  - `joins url split across two reads`：先 append URL 的前半（沒有 `\n`），等 100ms，再 append 後半加 `\n`，最後要拿到完整的憑證。
  - `resets offset when file shrinks`：`start` 之後把檔案截成只剩一行新 URL C（長度比 baseline 小），要拿到 C。
  - `missing file then created`：`start` 時檔案還不存在（baseline 當 0），之後才建立並寫入 URL D，要拿到 D。
  - `malformed url keeps waiting`：append 一行缺 `record_id` 的 URL，`result` 不 complete；再 append 有效的 URL，要拿到後者。
- [ ] **Step 2: 跑測試確認失敗**
- [ ] **Step 3: 實作 `PollingClientLogWatch`**
  - `start` 時用 `File(path).length()` 取 baseline（檔案不存在就當 0）。
  - 用 `Timer.periodic`（或 async loop，由實作者決定）每個 interval：
    1. 長度比 offset 小 → offset 歸零，清掉 carry，記 `info` `client log rotated`。
    2. 長度比 offset 大 → 用 `File.open(mode: FileMode.read)` 讀 `[offset, length)`。`dart:io` 在 Windows 開唯讀檔案時會允許其他程式同時讀寫；如果實測跟遊戲衝突（sharing violation），這一輪記 `warning`、下一輪重試。
    3. 解碼後接在 carry 後面，只處理到最後一個 `0x0A`，剩下的存進 carry（上限 1 MiB，超過就丟棄並記 `warning`）。
    4. `utf8.decode(allowMalformed: true)` → `findLastConveneUrl` → `fromConveneUrl`。成功就 complete，並記 `info` `client log hit cred=${sanitizeCredential(cred.toJsonString())}`；失敗記 `warning` 後繼續。
  - 讀取時的 I/O 例外：記 `warning`（帶 OS error 訊息），不中止監看。
  - 開始時記 `info` `client log watch started path=<sanitizeFsPath> offset=<n>`。
- [ ] **Step 4: 跑測試確認通過**
- [ ] **Step 5: Commit**：`feat(capture): watch game client log for convene url`

---

### Task 5: Repository 比快

**Files:**
- Modify: `lib/state/gacha_repository.dart`（`_runMitm`、`cancelCapture`，新增 `restartClientLogWatch`）
- Test: `test/state/gacha_repository_update_test.dart`（追加；比照既有的 `_FakeCapture` 寫法）

**Interfaces:**
- Consumes：`gameDirLocatorProvider`、`clientLogWatchProvider`、`settingsProvider`（`gameDir`）。
- Produces：`Future<void> GachaRepository.restartClientLogWatch()`。只在 `state.progress is WaitingForCapture` 時有作用：停掉目前的 log session，重新 `locate` 後 `start`（基準點從這一刻重算）。

- [ ] **Step 1: 寫失敗測試**（fake capture 和 fake watch 都用 `Completer` 控制完成時機；`gameDirLocatorProvider` 用 override 回傳固定的 `GameDirLocation`）
  - `log wins: waits capture teardown before fetching`：log 先 complete，驗證 fake capture 的 `cancel` 有被呼叫；在 capture 的 `result` complete 之前，fetcher 的 mock client 收到 0 個請求；complete 之後才開始拉取，更新成功。
  - `log wins: capture teardown error is ignored`：log 先 complete，capture 的 `result` `completeError`，更新照樣完成（`UpdateCompleted`）。
  - `capture wins: log watch cancelled`：capture complete 成憑證，fake watch 的 `cancel` 有被呼叫，更新完成。
  - `capture error before log: update fails and log watch cancelled`：結果是 `UpdateFailed`，watch 的 `cancel` 有被呼叫。
  - `user cancel stops both`：呼叫 `cancelCapture()` 後 capture 回傳 null，watch 的 `cancel` 有被呼叫，progress 被清掉。
  - `user cancel during log-won teardown aborts`：log 已經 complete、capture 收尾還沒完成時呼叫 `cancelCapture()`，等 capture 完成後，沒有發出任何拉取請求，progress 被清掉。
  - `no game dir: capture only`：locator 回傳 null 時不呼叫 watch 的 `start`，流程跟現在一樣。
  - `restartClientLogWatch re-locates and restarts`：等待中呼叫它，舊的 watch session 被 `cancel`，新的 session 被 `start`；新 session 命中時以它勝出。
  - fallback 重攔（`isFallback: true`）也會啟動 log 監看：用既有的「第一池 `code=-1` → 重攔」測試情境，讓 log 勝出。
- [ ] **Step 2: 跑測試確認失敗**
- [ ] **Step 3: 實作**
  - 在 `_runMitm` 裡：
    - 建立一個 `Completer<GachaCredential> logHit`（等待期間只用這一個）。log session 命中且憑證不是 null 時 complete 它；`restartClientLogWatch` 換 session 時也接到同一個 `logHit`。
    - 用 `Future.any` 比快：攔截 `result`（成功、null、錯誤都算結束）對上 `logHit.future`。
    - 依 spec 6.4 處理四種結果。log 勝出時：`await capture.cancel()`，然後 `try { await capture.result } catch (e) { warning 'capture teardown error after log win: $e' }`。這段期間如果 `_logWinCancelRequested` 被設成 true，就回傳 null（呼叫端會把它當成使用者取消）。
    - 記 `info` `credential source=log|capture`。
    - `finally`：停掉 log session、清掉 `_activeCancel`。
  - `cancelCapture()`：一併設定 `_logWinCancelRequested = true`，並停掉 log session。
  - 起點：`settings.gameDir`，交給 `locate(settingDir:)`；回傳 null 就不啟動監看。
- [ ] **Step 4: 跑測試確認通過**：`fvm flutter test test/state/`，期望全部 PASS（既有測試也不能壞）。
- [ ] **Step 5: Commit**：`feat(capture): race client log watch against capture`

---

### Task 6: 等待畫面連結和說明視窗

**Files:**
- Create: `lib/widgets/dialogs/game_dir_help_dialog.dart`
- Create: `lib/widgets/game_dir_picker.dart`（等待畫面的說明視窗和設定頁共用）
- Modify: `lib/widgets/update_progress_dialog.dart`（`_Body` 的 `WaitingForCapture` 分支加連結；progress 變成 null 時改成「先 `popUntil` 到自己的 route 再 pop」）
- Modify: 四份 ARB
- Test: `test/widgets/update_progress_dialog_test.dart`（追加）、`test/widgets/dialogs/game_dir_help_dialog_test.dart`

**Interfaces:**
- Consumes：`gameDirLocatorProvider`、`settingsProvider`、`GachaRepository.restartClientLogWatch()`。
- Produces:
  ```dart
  enum GameDirPickOutcome { saved, cancelled, invalid }
  /// 開啟選資料夾視窗，用 normalize 驗證後存進設定。
  Future<GameDirPickOutcome> pickAndSaveGameDir(WidgetRef ref, {Future<String?> Function()? pickDirectory});
  Future<void> showGameDirHelpDialog(BuildContext context);
  ```

- [ ] **Step 1: 新增 ARB 字串**（四份；zh 的文案如下，其餘三份照意思翻譯，保持一致）

  | key | zh（template） |
  |---|---|
  | `progressNotDetectedLink` | 已經開啟喚取記錄，卻一直沒有反應？ |
  | `gameDirHelpTitle` | 偵測不到喚取記錄 |
  | `gameDirHelpNotFound` | 找不到鳴潮的遊戲資料夾。選擇遊戲資料夾後，本工具也能改從遊戲記錄檔讀取喚取記錄。 |
  | `gameDirHelpFound` | 目前讀取的遊戲資料夾：{path}（placeholder `path`: String）。如果不是你正在玩的那份遊戲，請重新選擇。 |
  | `gameDirHelpReopen` | 已設定遊戲資料夾。請回到遊戲，再開啟一次喚取記錄。 |
  | `gameDirInvalid` | 這個資料夾裡找不到遊戲記錄檔，請選擇「Wuthering Waves Game」資料夾。 |
  | `actionChooseGameDir` | 選擇遊戲資料夾 |
  | `actionRechooseGameDir` | 重新選擇 |

  跑 `fvm flutter gen-l10n` 確認沒有錯誤（untranslated 的警告是正常的）。
- [ ] **Step 2: 寫失敗測試**
  - `WaitingForCapture shows not-detected link`：等待狀態下找得到 `progressNotDetectedLink` 的文字，點下去會出現 `gameDirHelpTitle`。
  - 說明視窗內容：locator 回傳 null 時顯示 `gameDirHelpNotFound` 和 `actionChooseGameDir`；回傳 `GameDirLocation(p, registry)` 時，顯示含 `p` 的文字和 `actionRechooseGameDir`。
  - `pickAndSaveGameDir`：`pickDirectory` 回傳有效的資料夾 → 回傳 `saved`，`settings.gameDir` 是 normalize 後的值；回傳空資料夾 → `invalid`，設定不變；回傳 null → `cancelled`。
  - 在說明視窗裡選好資料夾後，視窗內改顯示 `gameDirHelpReopen`，而且有呼叫 `restartClientLogWatch`（用 fake repository 計數）。
  - `help dialog closes when progress leaves waiting`：說明視窗開著時，把 progress 改成 `FetchingBanner`，說明視窗消失、進度視窗還在。
  - `both dialogs close when progress becomes null`：說明視窗開著時，把 progress 改成 null，兩個視窗都消失，底下的頁面還在（沒有多 pop）。
- [ ] **Step 3: 實作**
  - 連結用 `TextButton`（或樣式一致的連結），放在提示文字下方。
  - 說明視窗在 build 時用 `FutureBuilder` 讀 `locate(settingDir: settings.gameDir)` 決定顯示哪種內容。用 `ref.listen` 監看 progress：一旦不是 `WaitingForCapture`，而且 `ModalRoute.of(context)?.isCurrent == true`，就 pop 自己。
  - `UpdateProgressDialog` 的 listener：progress 變成 null 時，先 `Navigator.popUntil((r) => r == ModalRoute.of(context))` 再 `pop()`，不管上面疊了幾層都只關到自己為止。
  - `pickAndSaveGameDir`：預設 `pickDirectory` 是 `getDirectoryPath`；normalize 成功後呼叫 `settingsNotifier.setGameDir`。
- [ ] **Step 4: 跑測試確認通過**：`fvm flutter test test/widgets/`
- [ ] **Step 5: Commit**：`feat(ui): add game folder help from capture waiting dialog`

---

### Task 7: 設定頁「遊戲資料夾」區塊

**Files:**
- Modify: `lib/pages/settings_page.dart`（在「資料管理」之後新增一個 `SectionCard`，icon 用 `Icons.sports_esports_outlined`）
- Create: 區塊 widget 放在 `settings_page.dart` 裡的私有類別 `_GameDirSection`（沿用這個檔案既有的寫法）
- Modify: 四份 ARB
- Test: `test/pages/settings_game_dir_section_test.dart`

**Interfaces:**
- Consumes：`pickAndSaveGameDir`（Task 6）、`gameDirLocatorProvider`、`SettingsNotifier.setGameDir`。

- [ ] **Step 1: 新增 ARB 字串**：`settingsGameDir`＝遊戲資料夾、`settingsGameDirAuto`＝自動偵測：{path}、`settingsGameDirManual`＝手動設定：{path}、`settingsGameDirNone`＝找不到遊戲資料夾、`actionClearGameDir`＝清除（目前 ARB 裡沒有通用的「清除」字串，所以要新增）。
- [ ] **Step 2: 寫失敗測試**：
  - 有設定值時顯示「手動設定」加路徑，並且有清除按鈕；按清除後 `gameDir` 變成 null，改顯示自動偵測的結果或「找不到」。
  - 沒有設定值、locator 回傳 registry 結果時，顯示「自動偵測」。
  - 按選擇按鈕會走 `pickAndSaveGameDir`（注入 fake `pickDirectory`）；結果是 `invalid` 時顯示 `gameDirInvalid`（SnackBar 或 inline，跟設定頁其他錯誤的呈現方式一致）。
- [ ] **Step 3: 實作**：路徑文字很長時要 ellipsis 或換行，不能超出邊界；窄視窗下按鈕要能換行（RWD）。
- [ ] **Step 4: 跑測試確認通過**：`fvm flutter test test/pages/settings_game_dir_section_test.dart`
- [ ] **Step 5: Commit**：`feat(settings): add game folder section`

---

### Task 8: 收尾驗證

- [ ] **Step 1**：`fvm dart format lib/ test/`
- [ ] **Step 2**：`fvm flutter analyze`，必須輸出 `No issues found!`
- [ ] **Step 3**：`fvm flutter test`，必須輸出 `All tests passed!`
- [ ] **Step 4: 手動 E2E（維護者本機，`fvm flutter run -d windows`）**
  1. 正常更新：log 拿到 `credential source=...`，更新完成。
  2. 暫時把 `rust_capture_helper/src/main.rs` 的 `TARGET_PROCESS` 改成 `"NoSuchProcess.exe"` 並重新 build，模擬 #92：只靠 log 也能完成，log 有 `credential source=log`、`capture teardown`，而且沒有錯誤。**驗證完要把這個修改還原，不能 commit。**
  3. 清除設定裡的遊戲資料夾，再把 locator 暫時指到不存在的路徑（或在沒裝遊戲的環境測）：點連結 → 顯示「找不到」→ 選擇資料夾 → 提示再開一次 → 開歷史頁 → 完成。
  4. 匯出 log，檢查裡面沒有喚取 URL 原文，也沒有完整的 `record_id`。
- [ ] **Step 5: Commit**（如果 format 有改動）：`style: format`
