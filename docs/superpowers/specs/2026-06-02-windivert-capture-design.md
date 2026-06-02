# 鳴潮喚取攔截改用 WinDivert 透明重導向 — 設計 spec

- 狀態：草案（待使用者審核）
- 日期：2026-06-02
- 前因：PoC gate 證實**鳴潮喚取 webview（Kuro CEF）完全忽略 Windows 系統代理**，原「系統代理 + MITM」對鳴潮不可行（只有 WinINet app 如 AnyDesk 會進代理，遊戲不會）。使用者實測 **mitmproxy 的「Local Applications 透明攔截（WinDivert）」可成功攔到**，且證明**遊戲信任系統根憑證、無 cert pinning**。
- 決策：**自己接 WinDivert** 把遊戲流量導進我們**現有的 hudsucker MITM**（憑證/MITM 全沿用），而非改用讀 log。

---

## 一、核心洞察與沿用範圍

- **可沿用（不動）**：`ca.rs`/`cert_store.rs`（自簽 CA 安裝到系統根，遊戲 CEF 已證實會信任）、`mitm.rs` 的 hudsucker MITM（CONNECT-based、`is_target`、讀 body、`CapturedRequest.body`）、整個 Dart 下游（`GachaCredential`/8 卡池迭代/`record_merge`/存檔/UI）。
- **移除**：`sys_proxy.rs`（設系統代理）——鳴潮不吃，無用。
- **新增**：WinDivert 透明重導向 + 一個「透明→CONNECT」shim，封裝在一個**提權的小 helper 行程**裡。

關鍵手法：**用 shim 把「WinDivert 重導向來的透明連線」轉成「帶 CONNECT 的連線」**，餵給現有 hudsucker——hudsucker 完全不用改成 transparent mode。

---

## 二、架構與資料流

```
鳴潮行程 :443 → gmserver-api.aki-game2.net（直連，不理系統代理）
   │
   │  ① WinDivert（核心驅動，helper 內，提權）
   │     攔下「鳴潮行程對 :443 的出站封包」並重導向到本機 shim
   ▼
本機 shim listener（helper 內，非提權亦可，但與 WinDivert 同行程故提權）
   │  ② 由 WinDivert 連線表查出原始目的地（gmserver-api:443）
   │  ③ 連到主程式 hudsucker 代理（127.0.0.1:18080）
   │     送 CONNECT gmserver-api.aki-game2.net:443 → 收 200
   │  ④ raw bytes 雙向 splice（不解 TLS，純位元組管道）
   ▼
主程式 hudsucker MITM（127.0.0.1:18080，非提權，沿用現有）
   │  用現有 CA 簽 leaf、解密、handle_request 命中 is_target → 讀 POST body
   ▼
CapturedRequest.body → Dart GachaCredential（下游全沿用）
```

**提權邊界（依使用者決策：按更新時才彈 UAC helper）**：
- 主程式（**非提權**）：跑 hudsucker MITM + CA 安裝（CA 安裝寫的是 CurrentUser\Root，非提權可寫）+ Dart UI。
- helper（**提權**、ephemeral）：只做 WinDivert + shim。按「更新」時由主程式以 `ShellExecute(runas)` 觸發 UAC spawn，攔到或取消/逾時後結束（關閉 WinDivert handle = 自動停止過濾、還原）。

> 為何 helper 只做 WinDivert+shim、MITM 留主程式：privilege 最小化——提權碼面越小越好；MITM/CA/sink→Dart 的既有流程不動。helper 攔到的 body 不需回傳，主程式的 hudsucker sink 直接拿到（現有 `CaptureSession` 流程）。

---

## 三、元件

### A. 新 helper 行程（Rust）
- 形式：rust crate 內第二個 binary target（如 `src/bin/capture_helper.rs`），或獨立小 crate；編譯出 `capture_helper.exe`，隨 app 散佈。
- 參數（命令列）：proxy port（主程式 hudsucker 的 18080）、target host（`gmserver-api.aki-game2.net`）、timeout 秒數。
- 職責：
  1. 載入 WinDivert（`windivert` Rust crate；驅動 `WinDivert64.sys` + `WinDivert.dll` 需在 helper 旁）。
  2. 安裝過濾並重導向（見〈四、WinDivert 過濾策略〉）。
  3. 起本機 shim listener；每條被導向的連線 → 查原始 dst → 連 hudsucker → 送 CONNECT → splice。
  4. 收到主程式的停止訊號（或逾時/攔到後）→ 關閉 WinDivert handle（還原）、結束。
- 與主程式協調：主程式 spawn 後等自己的 hudsucker 攔到 body（既有 `CaptureSession`）或使用者取消/逾時 → 終止 helper（kill 行程，或 helper 自行逾時退出）。helper 以 stdout/exit code 回報 ready/error。

### B. 主程式 Rust 改動
- `capture.rs`：`start_capture` 流程把 `sys_proxy::apply` 換成「spawn 提權 helper」。hudsucker 仍在主程式啟動、CA 仍安裝。`stop_capture` 改為「終止 helper + 既有 hudsucker graceful shutdown」。
- 移除 `sys_proxy.rs` 及其呼叫；`cleanup_stale_proxy` 改為「結束殘留的 helper / WinDivert 狀態」（WinDivert handle 隨 helper 行程結束自動還原，故殘留風險低；仍可在啟動時殺殘留 helper）。
- `mitm.rs`：**不動**（`is_target`、讀 body、`fired`、`handle_response` 全留）。

### C. Dart 改動
- `gacha_capture.dart` / capture 流程：spawn helper 的觸發點。UAC（`ShellExecute runas`）由 Rust 端做（主程式 Rust spawn helper）較自然，Dart 只是呼叫既有 `startCapture`。介面契約（`CaptureSession.result` → `GachaCredential?`）**不變**。
- 進度/提示文案：UAC 提示、「請在遊戲內開啟喚取記錄頁」維持。

### D. 打包
- 隨 app/installer 帶 `WinDivert64.sys`（官方簽章）+ `WinDivert.dll`，放在 `capture_helper.exe` 同目錄。
- installer 安裝這三個檔；README 附 WinDivert LGPL 授權聲明。
- 防毒可能標記 WinDivert 驅動——README/下載頁需說明（比照原本對自簽憑證的說明）。

---

## 四、目標行程與辨識策略（PoC + mitmproxy 已實證定案）

> **2026-06-02 PoC 結論（已用 `tool/windivert_poc/` 在實機驗證、並以使用者的 mitmproxy 截圖佐證）：**
>
> - **目標行程＝`KRWebView.exe`**（Kuro 的 CEF WebView，喚取記錄頁。每次開頁是**全新行程**、關頁自關）。mitmproxy 的「Local Applications」就是只鎖 `KRWebView.exe`、**不用重啟遊戲**即攔到 gmserver POST。
> - **不能靠 TLS SNI 辨識 gmserver**：`aki-gm-resources-oversea.aki-game.net` 與 `gmserver-api.aki-game2.net` 走**同一 Akamai 邊緣 IP、同一張憑證（SAN 同時涵蓋兩網域）**，Chromium 因此做 **HTTP/2 connection coalescing**——只開一條 TLS 連線（SNI=`aki-gm-resources`），gmserver 的 POST 以 `:authority: gmserver-api.aki-game2.net` **多工在同一條連線裡**。故 sniff 只看得到 `aki-gm-resources` 的 SNI，gmserver 主機名在加密 h2 標頭內。
> - **MITM 會讓 coalescing 自然破裂**：我們對每個網域簽**單網域** leaf 憑證（cert 不涵蓋另一網域）→ Chromium 不再 coalesce → gmserver 自成一條 `SNI=gmserver-api` 的獨立連線 → 被 MITM、解密、`is_target` 命中。mitmproxy 即如此（Flow List 每 host 各一條）。
> - gmserver 是 **HTTP/2 over TCP**（非 QUIC）。但 Chromium 仍可能對頁面/端點嘗試 QUIC，故仍建議**擋掉 KRWebView 的 UDP 443**逼全程 TCP（belt-and-suspenders）。

**定案策略**：

1. **依行程鎖定 `KRWebView.exe`**：用 WinDivert SOCKET 層學到 `KRWebView.exe` 的 PID 與其連線的本機埠，只重導向「該行程的 :443」（不碰 AnyDesk/瀏覽器/PhpStorm 等）。`windivert` crate 支援 SOCKET 層；若行程鎖定成本過高，退而求其次：對 KRWebView 連線「全部重導向 + shim 讀 SNI 設 CONNECT host」。
2. **擋 KRWebView 的 UDP 443**（drop，逼 QUIC 退回 TCP）。
3. **shim 讀每條連線的 ClientHello SNI → CONNECT <SNI host>:443 餵 hudsucker**；hudsucker 用 CA 簽**單網域** leaf（破 coalescing）。
4. **辨識 gmserver 靠「解密後的 HTTP 請求」**（`is_target`：host==`gmserver-api.aki-game2.net` && path==`/gacha/record/query`），**不靠 SNI**。`mitm.rs` 現有 `is_target` 正是看解密後的 host/path，沿用即可。
5. **免 RST、免重啟遊戲**：KRWebView 每次開頁全新，連線一開就被重導向。

> 不再需要原 F1（依 IP，CDN 多 IP 脆弱）或「shim 內 SNI 篩 gmserver」（coalescing 下 gmserver 無獨立 SNI，篩不到）。改為「鎖行程 + 全重導向 + 解密後 host 辨識」，與 mitmproxy 一致。

---

## 五、測試策略

- **可單元測試**：shim 的「透明連線 → 組 CONNECT 字串 → 解析 200」邏輯；WinDivert filter 字串組裝；原始 dst 對應表。
- **無法自動測（需實機）**：實際 WinDivert 重導向、遊戲流量被攔、端到端攔到 body——**只能在使用者本機 + 實際遊戲 + 管理員**驗證（本開發環境無 WinDivert/無遊戲/無 admin）。這部分列為**使用者本機驗收**。
- 既有 795 個測試 + cargo test 維持全綠（capture 改動不應動到下游）。

---

## 六、風險與待實機驗證

1. **WinDivert 過濾正確性 / 迴圈**：F2 的行程鎖定與 SNI 篩選是關鍵；做錯會漏攔或誤傷全機 HTTPS、或造成迴圈。→ 實機謹慎驗。
2. **shim 透明 passthrough 的正確性**：非 gmserver 的 SNI 必須無損 passthrough，否則遊戲其他連線壞掉。
3. **UAC helper 協調**：spawn/kill/逾時/取消/清理；helper 崩潰時 WinDivert handle 關閉即還原（風險低），但仍要處理殘留 helper。
4. **驅動簽章/防毒**：WinDivert64.sys 官方簽章，但防毒可能擋；需文件說明。Win10/11 driver signing 要求。
5. **CDN/IP 變動**（若採 F1）。
6. **`windivert` Rust crate 的能力與維護度**：需確認支援 NETWORK + SOCKET/FLOW 層、reinjection、與我們 tokio runtime 的整合。

---

## 七、實作分期（建議）

1. 研究 + PoC：`windivert` crate 起一個最小 helper，確認能鎖定鳴潮行程的 :443 並重導向到本機 listener（純印出、不接 hudsucker）。**先在使用者本機證明 WinDivert 重導向可行**（最高風險前置）。
2. shim：透明→CONNECT，接上現有 hudsucker，端到端攔到 body。
3. 主程式整合：`capture.rs` 換 spawn 提權 helper、移除 sys_proxy、`ShellExecute runas`。
4. 打包：帶 WinDivert64.sys/.dll、installer、README 授權與防毒說明。
5. 全綠驗收 + 使用者本機端到端驗。

---

## 八、確認狀態（2026-06-02 已定案）

- ✅ 架構認可：helper 做 WinDivert+shim、MITM/CA 留主程式、shim 轉 CONNECT 餵 hudsucker。
- ✅ 提權：按「更新」時才 UAC 提權小 helper。
- ✅ 隸帶 WinDivert（LGPL 動態連結 + README 授權聲明）。
- ✅ PoC（§七 第1步）已在實機完成：WinDivert 驅動/管理員/過濾/SNI/行程鎖定全可行（`tool/windivert_poc/`）。
- ✅ 目標行程＝`KRWebView.exe`；辨識靠解密後 host（非 SNI，因 h2 coalescing）；免 RST／免重啟遊戲——皆由 PoC + mitmproxy 截圖佐證（見 §四）。

**結論：可進入完整實作（§七 第2–5步）。**
