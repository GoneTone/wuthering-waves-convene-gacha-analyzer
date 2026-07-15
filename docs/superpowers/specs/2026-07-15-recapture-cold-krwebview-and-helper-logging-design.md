# 重攔首次落空修正 ＋ helper 觀測性設計

- 日期：2026-07-15
- 分支：`fix/recapture-cold-krwebview-and-helper-logging`
- 狀態：設計已與使用者確認，待轉 plan

## 一、問題陳述

使用者回報：**重開遊戲後**，在 app 點「更新資料」→ 依提示回遊戲開卡池歷史頁 → **有時仍卡在等待抓取**；必須先取消、再點一次「更新資料」、再回遊戲重開卡池歷史頁才抓得到。

**此現象是間歇性的、感覺隨機**（並非每次重開都必現）。這點很關鍵：**隨機而非確定性，最吻合一個 timing race**——冷 spawn 的 KRWebView 其 :443 CONNECT 事件，和「該行程映像名變得可讀」之間在賽跑，行程建立的微小時序抖動決定當次輸贏。

### 1.1 log 佐證（`2026-07-15.log`，08:53 這輪）

```
update start, forceRecapture=false
using cached credential for playerId=701****588
fetchPool failed cardPoolType=1 code=-1 msg=请求游戏获取日志异常!
first pool failed (code=-1), falling back to recapture
capture started
（20 秒後）capture cancelled by user
capture done with no match
```

拆解：

1. 「更新資料」先用**磁碟快取憑證**直打 gmserver（`gacha_repository.dart:255-273`）。
2. 伺服器回 **code=-1「请求游戏获取日志异常」**，即快取憑證的 `recordId` 已失效。這在鳴潮是**預期行為**（token 開頁才生成、很快過期），也是重攔存在的理由，不需修改。
3. 自動 fallback 進 MITM 重攔（`gacha_repository.dart:289-295` 的 `_runMitm(isFallback: true)`）。
4. 使用者開了卡池頁，但 **MITM 全程沒收到任何命中**（`capture done with no match`），最後取消。

**真正的 bug 是第 4 步：重攔第一次抓不到。**

### 1.2 關鍵盲點：helper 是黑箱

決定「某條 :443 連線要不要重導向進 MITM」的是 `capture_helper.exe`——一個由主程式 `ShellExecuteExW` + `runas` 提權、`SW_HIDE` 隱藏啟動的**獨立行程**（`rust/src/helper.rs`）。它的所有判斷只走 `eprintln!` 到自己的 stderr，而該 stderr **沒有被任何地方接住**。因此 app log 只看得到「no match」，完全看不到 helper 到底有沒有把 KRWebView 的連線導進來、為什麼沒導。這個盲點讓根因**目前無法從現有 log 證實**。

## 二、根因判斷（強假設，待 helper log 證實）

擷取鏈路：WinDivert SOCKET 層在 CONNECT 當下用 PID 查行程名 → 判定屬 `KRWebView.exe` 的 :443 埠 → NETWORK 層把該埠封包重導向到本機 shim → shim 只對 `gmserver-api.aki-game2.net` 發 CONNECT 進 hudsucker MITM。

重導向**必須在 SYN 當下完成**：連線一旦以直連方式建立，就無法中途改導 loopback（既有 ESTABLISHED socket 認的是真實 server IP）。所以「是不是 KRWebView」必須在 SYN 前判定好。

判定依賴 `proc_name(pid)`（`rust_capture_helper/src/main.rs:709`，用 `sysinfo` 讀映像名）。**重開遊戲後第一次開卡池頁時，KRWebView 是剛 spawn、誕生不到數毫秒的冷行程**，此時映像名常常讀不到、回空字串 → 被判成「非 KRWebView」→ 該本機埠被寫進 `not_target_ports`。

一旦落進 `not_target_ports`，NETWORK 層 `known_not` 分支會**永久短路跳過**（`main.rs:249`），連 SYN 時的 `GetExtendedTcpTable` 補救查詢都不做 → 這條連線再也不會被重導向 → MITM 全程看不到 → no match。

**為何隨機而非每次必現**：`proc_name` 能否在 CONNECT 當下讀到剛 spawn 行程的映像名，取決於行程建立各階段（loader 映射 exe、Windows 填好 image name）與 CONNECT 事件到達的相對時序。這個時序每次都有微小抖動，故有時及時讀到（該次成功）、有時沒讀到（該次落空並被永久毒化）。這正是使用者觀察到「間歇隨機」的成因，也是 timing race 的典型特徵。

### 2.1 待證實與替代機制

此判斷需 helper log 證實。「間歇隨機」雖最吻合 5.1/5.2 的 `proc_name` timing race，但**隨機性本身無法排除**下列同樣會呈現隨機的機制，故軌 A 必須先上、當場分辨；屆時視 log 另案處理（本次不預先實作，遵循 YAGNI）：

- **連線復用**：若 KRWebView 復用「重攔啟動前就已建立、仍在 pool 內的既有連線」，則整段沒有新 CONNECT/SYN，helper log 會顯示「該 :443 完全沒出現在事件流」。既有連線是否還活著取決於閒置時序，故也可能呈現隨機。（原以「重啟後無既有連線」排除，但使用者「重開」可能指重開卡池頁而非重啟整個 client，無法據此排除。）
- **QUIC / HTTP3 首選**：冷啟動先試 UDP 443，被 drop 後才 TCP fallback，其時序異常也可能隨機。log 會顯示 UDP drop 與後續 TCP SYN 的順序。

三者中若為 `proc_name` race，軌 B 直接修好；若為連線復用或 QUIC 時序，軌 B 的「不毒化 not_target」仍是無害的正確性改進，對應修法待 log 證實後另補。

## 三、目標與非目標

### 目標

1. **軌 A（觀測性）**：讓 helper 把每條連線的分類決策寫進「當天主 log 檔」，使此類「no match」失敗**可診斷**。
2. **軌 B（修法）**：修掉「未解析出行程名時被永久誤標成非目標」的破口，讓冷 KRWebView 首次即被正確分類、重導向。

### 非目標

- 不改「快取憑證優先 → code=-1 自動 fallback 重攔」的既有流程（`gacha_repository.dart:255-295`）——那是正確設計。
- 不預先實作「連線復用」「QUIC 時序」等未證實機制的修法。
- 不改 helper 的提權/停止/看門狗架構。

## 四、軌 A 設計：helper 觀測性

### 4.1 Log 落點：併入當天主 log 檔

helper 直接以 **append 模式**寫進 app 現有的 `logs/YYYY-MM-DD.log`（UTC 日期，與 `LogService._fileFor` 命名一致）。

**此決策反而簡化 app 端**：`_rotate` 的保留清理正則（`^(\d{4})-(\d{2})-(\d{2})\.log$`）與 `buildExportBundle` 的 `*.log` 匯出掃描本來就吃這個檔名，**兩者都不用改**。

**併寫安全性**（兩行程同時 append 同一檔）：

- helper 以**純 append 模式**開檔（`FILE_APPEND_DATA` 語意：每次 write 原子地 seek 到 EOF 再寫）。
- **每筆 log 一次 write 整行**（先在 buffer 組好整行、單一 write 呼叫），行長度控制在數 KB 內，確保不與 Dart IOSink 的 `writeln` 交錯出斷行。
- **行格式沿用 app 既有格式**：`<UTC ISO8601 帶 Z> [LEVEL  ] [target] message`（對齊 `LogService._format`），讓合併後的檔案格式一致、可依時間戳排序。target 用 `capture.helper` 標明來源。
- 驗收時**實際檢查一份真實合併 log 沒有斷行汙染**。

**邊界情況**：capture session 很短（數秒至一分鐘）。若正好跨 UTC 午夜、app 已 rollover 到新檔，helper 仍寫其啟動時算出的當天檔——影響可忽略（至多幾行落在前一天檔）。

### 4.2 路徑流動

Dart 已知 `LogService.logsDir`，需把它送到 helper：

```
gachaCaptureProvider (讀 logServiceProvider.logsDir.path)
  → RustGachaCapture(logsPath)               // 建構子注入
    → rust_capture.startCapture(logDir)      // frb 簽名新增參數，需重跑 codegen
      → capture.rs start_capture(sink, logDir)
        → helper::spawn(mitm_port, logDir)
          → capture_helper.exe argv[4]（路徑含空白/unicode，用雙引號包好）
```

**介面不變原則**：`GachaCapture.start()` 維持無參數，避免 test 內大量 `_FakeCapture` / `overrideWithValue` 連鎖改動；logs 路徑改由 `RustGachaCapture` 建構子注入（provider 內 `ref.watch(logServiceProvider).logsDir.path`）。

### 4.3 記錄內容（以「每個本機埠一次決策」為粒度，絕不逐封包）

- **CONNECT 分類**（socket_watcher，每埠一次）：`port pid name="<名稱或 unresolved>" verdict=target|not_target|unknown proto=tcp|udp v6=<bool>`
- **行程名未解析**時明確一行 `WARNING`（預期會抓到的煙槍）。
- **SYN fallback 查表**（network_loop）：`port pid name → redirect|skip`
- **重導向實際觸發**：`port → shim`（每埠一次，用已記集合去重、避免逐封包洗版）。
- **shim SNI 判斷**：`sni=<host> → mitm|passthrough`。
- 既有 `eprintln!` 的錯誤/警告一併導入此 log。

### 4.4 脫敏

- 只記 port / pid / 行程名 / 目標 host，**絕不碰任何 body/憑證**（helper 本就看不到解密內容）。
- 非目標 SNI 記成 `(other)`，不落實際主機名，避免記錄無關連線的目的地。
- 目標 host（`gmserver-api.aki-game2.net`）非敏感，可明記。

## 五、軌 B 設計：分類修法（`rust_capture_helper/src/main.rs`）

**核心原則：行程名沒解析出來時，絕不快取成「非目標」的負面判定。**

### 5.1 socket_watcher（CONNECT 層）

`proc_name(pid)` 三態化：

- 回 `KRWebView.exe` → **target**：快取 `pid_is_target[pid]=true`、依 proto 塞 `tcp_ports`/`udp_ports`/`v6_drop_ports`（同現行）。
- 回非空且非 KRWebView → **not_target**：快取 `pid_is_target[pid]=false`、塞 `not_target_ports`（同現行）。
- 回**空字串（未解析）→ unknown**：**不寫 `pid_is_target` 快取、不塞任何 port set**，讓連線維持未分類，交給 SYN fallback 再判。（現行 bug：這裡被塞進 `not_target_ports`，導致永久短路。）

### 5.2 network_loop（SYN fallback 層）

對未分類的 :443 SYN，查 owner PID（`find_tcp_pid`）→ `proc_name`：

- 解析為 KRWebView → `tcp_ports.insert`、重導向。
- 解析為明確非 KRWebView → 可寫 `not_target`（省後續查表）——**僅在明確解析出名稱時**才寫。
- **仍未解析** → **短暫「扣住 SYN 並重試」**：有上限地在 helper 內延遲重試 `proc_name`（例如至多數次、合計約數十毫秒），期間**不 reinject 該 SYN**（連線尚未建立、可安全延後），直到解析出結果再決定要不要改寫重導向。因為重導向必須在 SYN 當下完成，而 SYN 比 CONNECT 稍晚、行程已略成熟，扣住重試能補上冷啟動這段空窗。

重試上限與延遲的實際數值於 plan 決定，並以 helper log 觀察冷啟動實測值校準。

### 5.3 proc_name 可靠性（實作期一併驗證）

現行 `proc_name` 用 `sysinfo` 的 `refresh_processes_specifics(..., ProcessRefreshKind::nothing())`。實作期查證：改用直接 Win32 映像名查詢（`OpenProcess` + `QueryFullProcessImageNameW`）是否對年輕行程更可靠解析。若是，可能整體減少對 5.2 扣住重試的依賴（重試仍保留為安全網）。

## 六、契約與相容性

- **既有流程不變**：快取憑證優先、code=-1 自動 fallback 重攔維持原樣；重攔後仍全失敗才顯示 `errorGachaFailed`（`gacha_repository.dart:310-320`）。
- **frb 簽名變更**：`startCapture()` → `startCapture(logDir)`，需重跑 flutter_rust_bridge codegen（改 `flutter_rust_bridge.yaml` 對應 API 後 regenerate）。
- **`GachaCapture.start()` 介面不變**：test 的 `_FakeCapture` / `overrideWithValue` 不受影響。
- **helper 行為在非目標流量上不變**：仍只碰 KRWebView 的 :443，其餘 passthrough。

## 七、測試策略

helper 為提權整合行為、難純單元測；分兩層：

- **可純邏輯化的部分加單元測**：
  - 分類三態決策（target / not_target / unknown）的判定函式（可把 `proc_name` 抽成可注入，測空字串 → unknown 不毒化）。
  - log 行格式化與去重（同一 port 只記一次）。
  - （若 app 端有調整）保留正則、匯出掃描仍涵蓋當天檔。
- **端到端人工驗收**：重開遊戲 → 更新資料 → 開卡池頁，**首次即命中**；並匯出 log 檢查：
  - helper 分類決策確實寫入當天主 log、格式無斷行汙染；
  - 冷啟動當下可見 unresolved → fallback 重試 → redirect 的軌跡（證實根因）。
- `fvm flutter analyze` / `fvm flutter test` 全綠；`fvm dart format lib/ test/`。Rust 側 `cargo` 由 cargokit 掛在 flutter build，不另手動 build。

## 八、風險

- **併寫同檔交錯**：以純 append + 單次 write 整行緩解，驗收實測確認。
- **扣住 SYN 的延遲**：僅影響 KRWebView 首次連線建立、增加數十毫秒，使用者無感；上限保護避免無限扣住。
- **根因未證實**：軌 A 先讓機制可見；若 log 推翻主假設（指向連線復用/QUIC 時序），軌 B 的「不毒化 not_target」仍是無害的正確性改進，另案再補對應修法。
