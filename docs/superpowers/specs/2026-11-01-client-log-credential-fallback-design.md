# 喚取憑證改由「攔截＋讀遊戲 Client.log」雙來源取得 — 設計 spec

- 狀態：草案（待使用者審核）
- 日期：2026-11-01
- 前因：issue #92。回報者（歐服、Win10 19045、app v1.7.1）開啟喚取記錄後，helper 整段沒看到任何 `KRWebView.exe` 的 :443 連線（全部 `verdict=not_target`），導致攔不到請求、一直停在等待畫面。對照影片時間軸，歷史頁載入的時間點只出現一個非 `KRWebView.exe` 的新行程連線，推測他的環境改由別的行程載入歷史頁（尚待回報者提供行程名確認）。同時期 WuWa Tracker 仍然正常，因為它讀的是遊戲本機 log，不依賴發請求的是哪個行程。

---

## 一、目的與動機

讓「更新」不再只依賴「攔截 `KRWebView.exe` 流量」這一條路。等待攔截期間，同時監看遊戲寫在本機的 `Client.log`，從中取得喚取記錄 URL 並轉成 `GachaCredential`。兩條路哪邊先拿到新憑證就用哪邊。遊戲之後再換 WebView 實作或發請求的行程時，使用者照樣能匯入，不需要我們追著修。

兩條路的弱點剛好互補：

| 情境 | 攔截 | 讀 log |
|---|---|---|
| 遊戲換 WebView／發請求的行程（#92） | 壞 | 正常 |
| Kuro 改 log 格式或混淆方式 | 正常 | 壞 |
| 使用者關掉遊戲 log（`Engine.ini` `[Core.Log] Global=off`） | 正常 | 壞 |

## 二、目標／非目標／反目標

**目標**

- 等待攔截期間，背景同時監看 `Client.log`，抓到**新寫入**的喚取 URL 時就以它完成等待，下游流程（`_fetchAllBanners`、存檔、UI 進度）完全不變。
- 自動偵測遊戲資料夾；偵測不到或偵測錯時，使用者可以從等待畫面的連結手動選擇。選擇結果存進設定，設定頁也能查看、修改、清除。
- 讀 log 這條路的任何失敗都不能打斷等待，也不能讓更新失敗；一律只寫 log。

**非目標**

- 不修改攔截這條路（helper、WinDivert、MITM）。#92 的 `TARGET_PROCESS` 擴充等回報者回覆後另案處理。
- 不支援國服（`aki-gm-resources.aki-game.com`／`gmserver-api.aki-game2.com`）。現有 fetcher 和 MITM 都只處理國際服 `gmserver-api.aki-game2.net`，這次維持一致。
- 不讀 `KRSDKWebView\debug.log`。本機實測它在 2026-06-14 之後就沒再寫入。
- 不修改遊戲檔案的 ACL（WuWa Tracker 會 `takeown`／`icacls`，我們不做）。
- 不執行或內嵌 WuWa Tracker 的腳本（該 repo 沒有授權條款；遠端執行有供應鏈風險）。只參考公開事實（檔案位置、XOR 規則、URL 格式），自己實作。

**反目標**（技術上可行但算失敗的情況）

- 使用者看到的更新流程變了，或多了一個必須先做的步驟。使用者曾明確要求遷移時沿用原本的流程和 UX。
- 拿到 `Client.log` 裡**上一次**留下、已經過期的 URL，造成白跑一輪 `code=-1`。
- 喚取 URL 原文（含 `record_id`、`player_id`）寫進 app log。

## 三、已驗證的事實（2026-11-01 在維護者本機實測）

- `Client.log` 路徑：`<遊戲資料夾>\Client\Saved\Logs\Client.log`。遊戲執行中持續寫入，必須用共享模式（ReadWrite＋Delete share）開檔。本機大小約 7.7 MB。
- 內容經過**逐 byte XOR 混淆**：`b ^ ((b & 1) != 0 ? 0xA5 : 0xEF)`。原始 bytes 裡找不到 URL，解碼後找到 12 筆。這是逐 byte 的運算、不依賴前後文，所以**只解新增的部分也是正確的**。
- URL 格式：`https://aki-gm-resources-oversea.aki-game.net/aki/gacha/index.html#/record?svr_id=…&player_id=…&lang=…&gacha_id=…&gacha_type=…&svr_area=global&record_id=…&resources_id=…&platform=PC`。注意參數在 `#` 之後的 fragment 裡。
- **每開一次歷史頁就會寫入一組新的 log 行**：開頭是一行 `[KuroSdk] OpenWebView [sdkJson: {"url":"<喚取 URL>",...}]`，接著幾行 KRSDK `sdklog` 也帶有同一個 URL。本機在 13:55:16 和 13:55:36 各開一次，各寫了一組。同一次遊戲 session 內，`record_id` 不會變。所以「baseline 之後新出現的 URL」可以當作「使用者剛開了歷史頁」的訊號。
- 本機那幾行 sdklog 顯示 WebView 走的是 CEF（`KRCefApp::createWebView`、`krwebviewcefhandler.cpp`）。#92 回報者那邊如果是別的實作，這幾行的內容應該會不同，可以當作診斷資料。
- 欄位對照：跟同一次 session 的 `*.cred.json` 逐欄比對全部吻合。

  | URL 參數 | `GachaCredential` 欄位 |
  |---|---|
  | `player_id` | `playerId` |
  | `svr_id` | `serverId` |
  | `resources_id` | `cardPoolId`（**不是** `gacha_id`） |
  | `record_id` | `recordId` |
  | `lang` | `languageCode` |

- 遊戲資料夾偵測：登錄檔 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\KRInstall Wuthering Waves Overseas` 的 `InstallPath` 是啟動器資料夾（本機為 `D:\Wuthering Waves`），遊戲本體在它底下的 `Wuthering Waves Game`。
- 遊戲行程是提權執行的（有 ACE 反作弊），非提權的 app 讀不到它的執行檔路徑，所以**不能**從執行中的行程反查路徑。

## 四、做法選擇

| 做法 | 取捨 | 結果 |
|---|---|---|
| **A. 純 Dart 定時檢查 log** | 不碰 Rust、FRB、helper；解碼和解析都是純函式，容易測；最多晚 1 秒拿到結果 | **採用**（使用者選定） |
| B. 作業系統檔案變更通知（`watcher`／`Directory.watch`） | Windows 對持續開著寫入的檔案，通知和大小資訊常要等 flush 才更新，最後還是得加定時檢查 | 不採用 |
| C. 寫在 Rust、透過 FRB 傳 stream | 大檔解碼較快，但 A 只解新增的部分，效能不是問題；多 codegen 和跨語言除錯成本 | 不採用 |

## 五、使用者決定的行為

1. **流程不變，背景兩路比快**：按「更新」後一樣先試快取憑證，失效就進入原本的等待畫面。等待期間攔截和讀 log 同時進行，先拿到的那邊勝出。
2. **等待畫面多一行固定顯示的連結**，大意是「已經開啟喚取記錄，卻一直沒有反應？」（用詞可再修）。**一直顯示**，不加任何計時或自動跳出，因為程式分辨不了「使用者還沒開歷史頁」和「開了但沒偵測到」。
3. **點連結開說明視窗，內容依情況調整**：
   - 找不到遊戲資料夾：說明找不到，提供「選擇遊戲資料夾」。
   - 已經有資料夾（自動偵測或設定的）：顯示目前讀取的路徑，提供「重新選擇」，涵蓋偵測到錯誤安裝（例如舊版殘留）的情況。
4. **選好的資料夾存進設定**；設定頁新增「遊戲資料夾」欄位，可以查看、修改、清除。

## 六、設計細節

### 6.1 新元件

- **`lib/services/client_log_credential.dart`**（純函式，不碰 I/O）：
  - `decodeClientLogBytes(Uint8List)`：XOR 解碼。
  - `findLastConveneUrl(String text)`：用 regex 抓最後一筆喚取 URL。只比對國際服 host `aki-gm-resources-oversea.aki-game.net`。
  - `GachaCredential.fromConveneUrl(String url)`：放在 `gacha_credential.dart`，跟 `fromCapturedBody` 並列，作為從 URL 建立憑證的唯一入口。解析 `#` 後的 query，依第三節的表格對應欄位；缺任何一個欄位就丟 `FormatException`。
- **`lib/services/game_dir_locator.dart`**：自動偵測遊戲資料夾，並驗證手動選擇的資料夾。
- **`lib/state/client_log_watch.dart`**：log 監看器。介面刻意比照 `GachaCapture`／`CaptureSession`（`start()` 回傳一個有 `result` future 和 `cancel` 的物件），讓 `gacha_repository` 可以對稱地比快，測試也能比照現有的 fake capture 注入 fake watcher。

### 6.2 新 URL 的判定（避免拿到舊 URL）

- 監看開始時記下 `Client.log` 目前的長度當作 **baseline offset**，之後**只解析 offset 之後新增的 bytes**。
- 使用者在等待途中才選好或換了資料夾時，基準點從**選好的那一刻**開始重算，並在視窗裡請使用者**再開一次喚取記錄**。
- 檔案長度變得比 offset 小（遊戲重啟、log 輪替）時，offset 歸零，從頭讀新檔。

### 6.3 定時讀取

- 每 1 秒 `File.length()`。長度變大時，用共享模式開檔，讀 `[offset, length)` 這一段，解碼後找 URL。
- 為了避免 URL 剛好被切在兩次讀取之間，每次只處理到最後一個 `\n` 為止，剩下的 bytes 保留下來，跟下一段一起處理。（混淆前的 `\n` 是 `0x0A`，因為是偶數，會被 XOR `0xEF` 成 `0xE5`。實作時要找解碼後的 `\n`，或直接在原始 bytes 裡找 `0xE5`，兩者等價，由實作決定。）
- 找到 URL 後，用 `fromConveneUrl` 解析：
  - 成功：完成 `result`。
  - 失敗（缺欄位）：記 `warning`，繼續等。

### 6.4 與攔截的比快（`gacha_repository._runMitm`）

- 進入 `WaitingForCapture` 時，同時呼叫 `gachaCapture.start()` 和 `clientLogWatch.start()`。
- **log 先拿到**：呼叫攔截 session 的 `cancel()`，**並且要等它的 `result` 完成**（也就是 helper 停止、WinDivert 重導向已還原）之後才回傳憑證。現有程式碼刻意等 stream `onDone` 才開始 HTTP 拉取，這個前提要保留。
  - **log 勝出後，攔截端的錯誤一律記 `warning` 並忽略**，用 log 的憑證繼續更新。手上已經有有效憑證，不應該因為收尾失敗（例如使用者拒絕 UAC、helper 停止時出錯）讓更新失敗。（我的判斷）
  - **UAC 提示還沒回應時也照樣等待**：`start_capture` 在 UAC 提權 spawn helper 期間持有 `SESSION` 鎖（`rust/src/api/capture.rs`），`stop_capture` 要拿同一把鎖，所以 `cancel()` 會一直等到使用者回應 UAC。這跟現在「UAC 沒回應就卡著」的行為一樣，使用者一定會看到 UAC 提示，所以不另外處理。不改 Rust 端。（我的判斷）
  - `cancel()` 本身也可能卡住，所以 log 勝出後的等待過程中，取消按鈕要照樣能用。
- **攔截先拿到**：停止 log 監看器，流程跟現在一樣。
- **使用者取消**：兩邊都停掉。
- **log 還沒勝出前，攔截就丟錯（`onError`，例如 UAC 被拒）**：維持現有行為（更新失敗），同時停止 log 監看器。log 那條路不負責救援攔截的錯誤，避免改變既有的失敗分流。（我的判斷）
- 第一次（primary）和失效後重攔（fallback）兩種情況都要走這個比快流程。

### 6.5 遊戲資料夾

- **自動偵測的順序**（我的判斷，可調整）：
  1. 設定裡存的資料夾（驗證有效才用）。
  2. 登錄檔 `Uninstall\KRInstall Wuthering Waves Overseas` 的 `InstallPath` + `\Wuthering Waves Game`。HKLM、HKCU、WOW6432Node 都要查。
  3. 常見的 Steam、Epic、Xbox 安裝路徑。

  **不掃描整個磁碟**，太慢，而且手動選擇已經能處理其餘情況。
- **有效的定義**：`<資料夾>\Client\Saved\Logs\Client.log` 存在。
- **手動選擇時的寬容處理**（我的判斷）：如果使用者選的是啟動器資料夾（例如 `D:\Wuthering Waves`），而它底下有 `Wuthering Waves Game\Client\Saved\Logs\Client.log`，就自動修正成遊戲資料夾。兩種都不符合時，在視窗內顯示錯誤，讓使用者重選。
- **設定**：在 `SettingsStorage` 新增 `pref.gameDir`。這是每台電腦各自的設定，**不加入雲端同步**；目前雲端同步本來就不同步 `AppSettings`。
- 設定的資料夾後來失效（遊戲搬家）時，當作沒設定，退回自動偵測。點連結開的視窗會顯示「找不到」。

### 6.6 UI

- **等待畫面**（`lib/widgets/update_progress_dialog.dart` 的 `WaitingForCapture` 分支）：在 `progressOpenGameHint`／`progressFallbackHint` 下方加一個不顯眼的文字連結。
- **說明視窗**：新的 dialog，一律用 `AppDialog`（`size: AppDialogSize.sm`），開在等待視窗上方，不關閉等待畫面。選資料夾用既有的 `file_selector` 的 `getDirectoryPath`。
  - **陷阱**：`UpdateProgressDialog` 在 progress 變成 null 時會呼叫 `Navigator.pop()`。如果這時說明視窗還開著，被 pop 掉的會是說明視窗，進度視窗反而留在畫面上。所以**說明視窗要在狀態離開 `WaitingForCapture` 時自己先關閉**（不管是攔截或 log 勝出、取消、失敗都一樣）。
- **設定頁**：放在既有的 `SectionCard` 裡（建議放進「資料管理」或新增一個小區塊，由實作依版面決定）。顯示目前路徑和它的來源（自動偵測／手動設定），並提供「選擇」「清除」兩個按鈕。
- **字串**：新增的字串只寫進核心四份 ARB（`app_zh.arb` 是 template）。標點依 CLAUDE.md 規則：繁中用全形，省略號用 ASCII `...`。

### 6.7 Log（logger 名稱 `gacha.clientLog`，訊息一律英文）

- `info`：監看開始（資料夾來源：`setting`／`registry`／`common`／`none`、baseline offset）、偵測到 log 輪替、命中（用 `sanitizeCredential` 記錄）、哪一邊贏了比快。
- `warning`：開檔或讀檔失敗（附 OS error）、URL 缺欄位、找不到遊戲資料夾。
- **不得記錄喚取 URL 原文**。`sanitizeUrl` 只會遮蔽原神的 query key，遮不到 fragment 裡的 `record_id`；一律先轉成憑證，再用 `sanitizeCredential` 記錄。
- 路徑一律經過 `sanitizeFsPath`。

## 七、測試（驗收條件）

- 單元測試：
  - XOR 解碼（含已知的 `0x0A → 0xE5`）。
  - `findLastConveneUrl`：多筆 URL 時取最後一筆；忽略國服 host。
  - `fromConveneUrl`：欄位對應正確（特別是 `resources_id → cardPoolId`）；缺欄位時丟錯。
  - 監看器：baseline 之前的 URL 不採用；URL 被切在兩次讀取之間時能正確接起來；檔案變小時 offset 歸零。用暫存檔模擬即可。
  - `game_dir_locator`：選到啟動器資料夾時自動修正；無效資料夾回報錯誤。
- repository 測試：用 fake watcher 和 fake capture 驗證比快的結果：
  - log 贏：一定是攔截的 `result` 完成之後才開始拉取。
  - log 贏後攔截收尾丟錯：照樣用 log 的憑證完成更新。
  - 攔截贏。
  - 取消。
  - log 還沒贏，攔截就丟錯：更新失敗，log 監看器有停掉。
- widget 測試：說明視窗開著的時候狀態離開 `WaitingForCapture`，說明視窗和進度視窗都正確關閉。
- `fvm flutter analyze` 和 `fvm flutter test` 全綠。
- 手動 E2E（維護者本機）：
  1. 正常情況：攔截和 log 都能拿到，任一方勝出後都能完成更新。
  2. 暫時把 `TARGET_PROCESS` 改成不存在的名稱來模擬 #92：只靠 log 也能完成更新。

## 八、留給實作者決定

- 讀取間隔的精確值（約 1 秒）、殘留 bytes 的上限。
- 常見安裝路徑的清單內容。
- 說明視窗和設定頁欄位的實際版面與用詞（遵守 RWD、不超出邊界）。
- 監看器內部用 `Timer.periodic` 或 async loop。
