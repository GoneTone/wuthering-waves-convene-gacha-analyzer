# 重攔首次落空修正 ＋ helper 觀測性 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓提權 helper 把每條 :443 連線的分類決策寫進當天主 log（軌 A 觀測性），並修掉「剛 spawn 的 KRWebView 因映像名一時讀不到而被永久誤標成非目標、永不重導向」的破口（軌 B），使重攔首次即命中。

**Architecture:** 提權隱藏行程 `capture_helper.exe` 目前只把判斷 `eprintln!` 到無人接的 stderr。本計畫：(A) 由主程式把 `logsDir` 路徑經 frb → `helper::spawn` → argv 傳入 helper，helper 以純 append 寫進 app 現有的 `logs/YYYY-MM-DD.log`（沿用既有保留清理與匯出，無需改 app 匯出邏輯）；(B) 把 `proc_name` 回空字串（未解析）從「快取成非目標並毒化 `not_target_ports`」改為「維持未分類」，並在 network_loop 對未分類的 :443 SYN 做有上限的「扣住 SYN 重試 `proc_name`」，讓冷 KRWebView 在連線建立前被正確分類。

**Tech Stack:** Rust（`rust_capture_helper` 獨立 binary crate：windivert、sysinfo、windows、新增 chrono）、flutter_rust_bridge 2.12.0、Dart／Flutter（Riverpod）。

## Global Constraints

- **指令一律優先用 `fvm`**：`fvm dart format lib/ test/`、`fvm flutter analyze`、`fvm flutter test`、`fvm flutter gen-l10n`；找不到 `fvm` 才退回 `dart`／`flutter`。
- **提交前品質檢查（全通過才 commit）**：`fvm dart format lib/ test/`（不要對 `.` 跑，會動到 `rust_builder/`）→ `fvm flutter analyze` 須輸出 `No issues found!` → `fvm flutter test` 須輸出 `All tests passed!`。不得用 `--no-verify`。
- **helper Rust 測試**：`cargo test --manifest-path rust_capture_helper/Cargo.toml`，需先設 `WINDIVERT_PATH` 指向 `rust_capture_helper/windivert/x64`（與 CMake 建置同一環境，見 `windows/CMakeLists.txt:82`），否則 windivert-sys 連結失敗。PowerShell：`$env:WINDIVERT_PATH="<repo>\rust_capture_helper\windivert\x64"`。
- **frb codegen**：改動 `rust/src/api/*` 的公開簽名後必須跑 `flutter_rust_bridge_codegen generate`（需先 `cargo install flutter_rust_bridge_codegen --version 2.12.0`）；`lib/src/rust/**` 為產生碼、不手改。
- **標點依語言慣例**：本計畫與 spec、程式碼內 dartdoc／`///`、Rust `//`／`///` 註解、UI 文字用繁體中文全形標點；**commit message／PR 標題用英文半形、conventional commits**。省略號一律用 ASCII `...`。
- **dartdoc**：新增的 Dart 宣告（含 private）寫一行 `///`；Rust 新增函式／型別寫一行 `///`。
- **log 脫敏**：helper log 只記 port／pid／行程名／目標 host；非目標 SNI 記成 `(other)`；絕不記 body／憑證。
- **不主動 `git push`**。

---

## File Structure

- `rust_capture_helper/Cargo.toml` — 新增 `chrono` 相依（時間戳格式化）。
- `rust_capture_helper/src/main.rs` — 主要改動：新增純函式（`Verdict`／`classify_verdict`／`format_helper_log_line`／`helper_log_file_name`）＋全域 logger（`init_hlog`／`hlog`）；改 `socket_watcher` 三態分類＋log；改 `network_loop` 扣住 SYN 重試＋log；改 `shim_listener` SNI log；`main()` 解析 argv[4]＝log 目錄並初始化 logger。
- `rust/src/api/capture.rs` — `start_capture` 新增 `log_dir: String` 參數並轉交 `helper::spawn`。
- `rust/src/helper.rs` — `spawn` 新增 `log_dir: &str` 參數，加進傳給 helper 的 argv（引號包路徑）。
- `lib/src/rust/api/capture.dart`＋`lib/src/rust/frb_generated*.dart` — frb codegen 自動更新（勿手改）。
- `lib/state/gacha_capture.dart` — `RustGachaCapture` 建構子注入 `logsPath`，`start()` 傳給 `startCapture(logDir: ...)`。
- `lib/state/gacha_repository.dart` — `gachaCaptureProvider` 從 `logServiceProvider.logsDir.path` 注入路徑。
- `test/state/gacha_capture_test.dart`（新）— 驗證 `RustGachaCapture` 保存注入路徑。

---

## Task 1: Helper 純函式基礎 ＋ chrono（TDD）

建立可單元測的純函式：分類三態、log 行格式、log 檔名。這些是軌 A／軌 B 後續任務共用的基礎，先以 TDD 完成。

**Files:**
- Modify: `rust_capture_helper/Cargo.toml`（新增 chrono）
- Modify: `rust_capture_helper/src/main.rs`（新增純函式與 `#[cfg(test)]` 測試）
- Test: `rust_capture_helper/src/main.rs`（同檔 `#[cfg(test)] mod tests`）

**Interfaces:**
- Produces:
  - `enum Verdict { Target, NotTarget, Unknown }`（`#[derive(Clone, Copy, PartialEq, Debug)]`）
  - `fn classify_verdict(proc_name: &str) -> Verdict`
  - `fn format_helper_log_line(ts: &str, level: &str, msg: &str) -> String`
  - `fn helper_log_file_name(now: chrono::DateTime<chrono::Utc>) -> String`

- [ ] **Step 1: 新增 chrono 相依**

在 `rust_capture_helper/Cargo.toml` 的 `[dependencies]` 末尾加入：

```toml
chrono = "0.4"
```

- [ ] **Step 2: 寫失敗測試**

在 `rust_capture_helper/src/main.rs` 檔尾新增：

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn classify_empty_name_is_unknown() {
        assert_eq!(classify_verdict(""), Verdict::Unknown);
    }

    #[test]
    fn classify_krwebview_is_target_case_insensitive() {
        assert_eq!(classify_verdict("KRWebView.exe"), Verdict::Target);
        assert_eq!(classify_verdict("krwebview.EXE"), Verdict::Target);
    }

    #[test]
    fn classify_other_process_is_not_target() {
        assert_eq!(classify_verdict("chrome.exe"), Verdict::NotTarget);
        assert_eq!(classify_verdict("capture_helper.exe"), Verdict::NotTarget);
    }

    #[test]
    fn format_log_line_matches_app_format() {
        // app 格式：<UTC ISO8601 帶 Z> [LEVEL(padRight 7)] [capture.helper] msg
        let line = format_helper_log_line(
            "2026-07-15T08:53:36.538986Z",
            "WARNING",
            "port=51000 pid=1234 name=unresolved verdict=unknown",
        );
        assert_eq!(
            line,
            "2026-07-15T08:53:36.538986Z [WARNING] [capture.helper] \
             port=51000 pid=1234 name=unresolved verdict=unknown"
        );
    }

    #[test]
    fn format_log_line_pads_short_level_to_width_7() {
        let line = format_helper_log_line("2026-07-15T00:00:00.000000Z", "INFO", "hi");
        assert_eq!(line, "2026-07-15T00:00:00.000000Z [INFO   ] [capture.helper] hi");
    }

    #[test]
    fn log_file_name_uses_utc_date() {
        let dt = chrono::Utc.with_ymd_and_hms(2026, 7, 15, 23, 59, 0).unwrap();
        assert_eq!(helper_log_file_name(dt), "2026-07-15.log");
    }
}
```

- [ ] **Step 3: 執行測試確認失敗**

Run（PowerShell，先設環境變數）：
```
$env:WINDIVERT_PATH="<repo>\rust_capture_helper\windivert\x64"
cargo test --manifest-path rust_capture_helper\Cargo.toml
```
Expected: 編譯失敗（`Verdict`／`classify_verdict`／`format_helper_log_line`／`helper_log_file_name` 未定義）。

- [ ] **Step 4: 實作純函式**

在 `rust_capture_helper/src/main.rs` 的 `const` 區塊之後（`TARGET_API_HOST` 附近）新增：

```rust
/// 行程分類三態。`Unknown` 代表映像名一時讀不到（剛 spawn 的行程常見），
/// 不可據此下「非目標」的永久判定，否則會毒化 `not_target_ports`。
#[derive(Clone, Copy, PartialEq, Debug)]
enum Verdict {
    Target,
    NotTarget,
    Unknown,
}

/// 依映像名分類：空字串 → Unknown、等於目標行程 → Target、其餘 → NotTarget。
fn classify_verdict(proc_name: &str) -> Verdict {
    if proc_name.is_empty() {
        Verdict::Unknown
    } else if proc_name.eq_ignore_ascii_case(TARGET_PROCESS) {
        Verdict::Target
    } else {
        Verdict::NotTarget
    }
}

/// 組一行 helper log，格式對齊 app 的 `LogService._format`：
/// `<UTC ISO8601 帶 Z> [LEVEL(左對齊補到 7 寬)] [capture.helper] <msg>`。
fn format_helper_log_line(ts: &str, level: &str, msg: &str) -> String {
    format!("{ts} [{level:<7}] [capture.helper] {msg}")
}

/// 依 UTC 時間算當天 log 檔名（`YYYY-MM-DD.log`），對齊 `LogService._fileFor` 命名。
fn helper_log_file_name(now: chrono::DateTime<chrono::Utc>) -> String {
    format!("{}.log", now.format("%Y-%m-%d"))
}
```

- [ ] **Step 5: 執行測試確認通過**

Run：`cargo test --manifest-path rust_capture_helper\Cargo.toml`
Expected: 全數 PASS（含既有測試若有）。

- [ ] **Step 6: Commit**

```
git add rust_capture_helper/Cargo.toml rust_capture_helper/src/main.rs
git commit -m "feat(capture-helper): add pure classification and log-format helpers"
```

---

## Task 2: 貫通 log 目錄路徑 ＋ 全域 hlog（wiring）

把 `logsDir` 從 Dart 一路傳到 helper 並初始化全域 logger，讓 capture 啟動時 helper 即寫一行啟動訊息到當天主 log。

**Files:**
- Modify: `rust_capture_helper/src/main.rs`（全域 logger、`init_hlog`、`hlog`、`main()` 解析 argv[4]）
- Modify: `rust/src/helper.rs`（`spawn` 簽名＋argv）
- Modify: `rust/src/api/capture.rs`（`start_capture` 簽名）
- Regenerate: `lib/src/rust/**`（frb codegen，勿手改）
- Modify: `lib/state/gacha_capture.dart`（`RustGachaCapture` 建構子＋`start()`）
- Modify: `lib/state/gacha_repository.dart`（provider 注入路徑）
- Test: `test/state/gacha_capture_test.dart`（新）

**Interfaces:**
- Consumes（Task 1）：`format_helper_log_line`、`helper_log_file_name`。
- Produces:
  - Rust: `fn init_hlog(log_dir: &str)`、`fn hlog(level: &str, msg: &str)`（全域、多執行緒安全）。
  - Rust: `helper::spawn(mitm_port: u16, log_dir: &str) -> Result<HelperHandle>`。
  - Rust: `start_capture(log_dir: String, sink: StreamSink<CapturedRequest>) -> Result<()>`。
  - Dart（frb 產生）：`Stream<CapturedRequest> startCapture({required String logDir})`。
  - Dart: `RustGachaCapture(String logsPath)`，欄位 `final String logsPath`。

- [ ] **Step 1: 寫失敗的 Dart 測試（provider 注入路徑）**

新增 `test/state/gacha_capture_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/state/gacha_capture.dart';

void main() {
  test('RustGachaCapture 保存注入的 logs 路徑', () {
    const path = r'C:\Users\x\AppData\Roaming\app\logs';
    final capture = RustGachaCapture(path);
    expect(capture.logsPath, path);
  });
}
```

- [ ] **Step 2: 執行測試確認失敗**

Run：`fvm flutter test test/state/gacha_capture_test.dart`
Expected: 編譯失敗（`RustGachaCapture` 目前無參數建構子、無 `logsPath` 欄位）。

- [ ] **Step 3: 改 `RustGachaCapture` 建構子與 `start()`**

在 `lib/state/gacha_capture.dart`，把 `RustGachaCapture` 類別改為：

```dart
/// 以 Rust 端 WinDivert 重導向 + hudsucker MITM 實作的 [GachaCapture]。
class RustGachaCapture implements GachaCapture {
  /// 建立 [RustGachaCapture]；[logsPath] 為 app 的 `logs/` 目錄，
  /// 傳給提權 helper 讓它把分類決策寫進當天主 log 檔。
  RustGachaCapture(this.logsPath);

  /// app 的 `logs/` 目錄絕對路徑。
  final String logsPath;

  static final _log = Logger('gacha.capture');

  @override
  CaptureSession start() {
    final completer = Completer<GachaCredential?>();
    GachaCredential? captured;
    _log.info('capture started');

    rust_capture.startCapture(logDir: logsPath).listen(
```

（其餘 `.listen(...)` 內容不變。）

- [ ] **Step 4: 改 provider 注入路徑**

在 `lib/state/gacha_repository.dart:110-112`，把 provider 改為：

```dart
/// [GachaCapture] 實作，預設為 [RustGachaCapture]（logs 路徑取自 [logServiceProvider]）。
final gachaCaptureProvider = Provider<GachaCapture>(
  (ref) => RustGachaCapture(ref.watch(logServiceProvider).logsDir.path),
);
```

確認 `gacha_repository.dart` 已 import `log_service.dart`（`logServiceProvider` 來源）；若無則加入：
```dart
import 'package:wuthering_waves_convene_gacha_analyzer/state/log_service.dart';
```

- [ ] **Step 5: 改 Rust `start_capture` 簽名**

`rust/src/api/capture.rs`，把 `start_capture` 改為（新增 `log_dir: String`、轉交 `spawn`）：

```rust
pub fn start_capture(log_dir: String, sink: StreamSink<CapturedRequest>) -> Result<()> {
    let mut guard = SESSION.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_some() {
        return Err(anyhow!("capture already running"));
    }

    crate::api::logging::init_tracing_once();

    let root = ca::load_or_generate()?;
    cert_store::install_to_current_user_root(&root.cert_der)?;

    let addr: SocketAddr = PROXY_ADDR.parse()?;
    let mitm = mitm::start(addr, &root.cert_pem, &root.key_pem, sink)?;
    let helper = helper::spawn(addr.port(), &log_dir)?;

    *guard = Some(Session {
        _helper: helper,
        _mitm: mitm,
    });
    Ok(())
}
```

- [ ] **Step 6: 改 `helper::spawn` 簽名與 argv**

`rust/src/helper.rs`，把 `spawn` 簽名改為 `pub fn spawn(mitm_port: u16, log_dir: &str) -> Result<HelperHandle>`，並把 `params` 那行（原 `:54`）改為在末尾加上引號包起的 log 目錄：

```rust
    let params = format!(
        "{mitm_port} {event_name} {} \"{log_dir}\"",
        std::process::id()
    );
```

更新 `spawn` 的 dartdoc/`///` 一行說明，註明第 4 個 argv 為 log 目錄。

> 注意：`log_dir` 來自 Dart `Directory.path`，Windows 下無尾端反斜線，故 `\"{log_dir}\"` 的結尾不會誤逸出引號；`CommandLineToArgvW` 會還原成原始路徑。

- [ ] **Step 7: 新增全域 hlog 並在 `main()` 初始化**

在 `rust_capture_helper/src/main.rs` 頂部 `use` 區補上：

```rust
use std::fs::OpenOptions;
use std::sync::OnceLock;
```

在純函式區（Task 1 新增的函式附近）新增全域 logger：

```rust
/// 全域 helper log 檔 handle（多執行緒共享）。未提供 log 目錄時為 None，`hlog` 靜默略過。
static LOG_FILE: OnceLock<Mutex<std::fs::File>> = OnceLock::new();

/// 依 log 目錄開當天 log 檔（append 模式）。失敗則不設，`hlog` 之後為 no-op。
fn init_hlog(log_dir: &str) {
    let path = format!("{log_dir}/{}", helper_log_file_name(chrono::Utc::now()));
    if let Ok(f) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = LOG_FILE.set(Mutex::new(f));
    } else {
        eprintln!("[warn] 無法開啟 helper log：{path}");
    }
}

/// 寫一行 helper log 到當天主 log 檔（純 append、每筆一次 write 整行、避免與 app IOSink 交錯）。
/// 未初始化時 no-op。同時保留 stderr 輸出供獨立除錯。
fn hlog(level: &str, msg: &str) {
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Micros, true);
    let line = format_helper_log_line(&ts, level, msg);
    eprintln!("{line}");
    if let Some(m) = LOG_FILE.get() {
        if let Ok(mut f) = m.lock() {
            let _ = f.write_all(line.as_bytes());
            let _ = f.write_all(b"\n");
        }
    }
}
```

在 `main()`（`:71` 起）解析 argv[4] 並初始化，緊接在 watchdog 設定之後、spawn 執行緒之前：

```rust
    if let Some(dir) = args.get(4) {
        init_hlog(dir);
    }
    hlog(
        "INFO",
        &format!("capture_helper started, mitm_port={mitm_port}"),
    );
```

> `write_all(line)` + `write_all("\n")` 是兩次呼叫，但都在同一把 `LOG_FILE` mutex 內、且本 helper 是唯一以此 handle 寫入者，故本行不與自己交錯；與 app 的另一 handle 之間靠 `FILE_APPEND_DATA` 原子 append 保證整行不被切斷（app 端 `writeln` 亦為整行）。

- [ ] **Step 8: 重跑 frb codegen**

Run：`flutter_rust_bridge_codegen generate`
Expected: `lib/src/rust/api/capture.dart` 的 `startCapture` 變為具名參數 `{required String logDir}`；`frb_generated*.dart` 一併更新。**勿手改產生碼。**

- [ ] **Step 9: 跑 Dart 測試與分析**

Run：
```
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test test/state/gacha_capture_test.dart
```
Expected: `analyze` → `No issues found!`；該測試 PASS。

- [ ] **Step 10: 編譯 helper 確認 Rust 端無誤**

Run：`cargo build --manifest-path rust_capture_helper\Cargo.toml`（已設 `WINDIVERT_PATH`）
Expected: 編譯成功。

- [ ] **Step 11: Commit**

```
git add rust_capture_helper/src/main.rs rust/src/helper.rs rust/src/api/capture.rs lib/src/rust lib/state/gacha_capture.dart lib/state/gacha_repository.dart test/state/gacha_capture_test.dart
git commit -m "feat(capture): thread logs dir into helper and add file logger"
```

---

## Task 3: socket_watcher 三態分類修法 ＋ 分類 log（軌 B 核心之一）

把 CONNECT 層的「非 KRWebView 一律塞 `not_target_ports`」改為三態：未解析（Unknown）**不快取、不塞任何集合**，交給 network_loop 再判；同時在每次首度分類時寫一行 log。

**Files:**
- Modify: `rust_capture_helper/src/main.rs`（`socket_watcher`，原 `:129-189`）

**Interfaces:**
- Consumes（Task 1／2）：`Verdict`、`classify_verdict`、`hlog`。

- [ ] **Step 1: 改 pid 快取型別與分類邏輯**

在 `socket_watcher`（`:129`）內，把 pid 快取由 `HashMap<u32, bool>` 改為 `HashMap<u32, Verdict>`，並只快取 `Target`／`NotTarget`（不快取 `Unknown`）。將 `:138-158`（`let mut pid_is_target ...` 到取得 `is_kr` 的 match）替換為：

```rust
    let mut sys = System::new();
    // 只快取已定案的 Target/NotTarget；Unknown（映像名一時讀不到）不快取，
    // 讓後續事件或 network_loop 的 SYN fallback 再判，避免永久誤標。
    let mut pid_verdict: HashMap<u32, Verdict> = HashMap::new();
    let mut buf = vec![0u8; 65535];
    loop {
        let packet = match divert.recv(Some(&mut buf)) {
            Ok(p) => p,
            Err(_) => continue,
        };
        let addr = &packet.address;
        if addr.remote_port() != TARGET_PORT {
            continue;
        }
        let pid = addr.process_id();
        // 回傳 (verdict, 是否為本次首度分類)：首度才寫 log，避免重複洗版。
        let (verdict, first_seen) = match pid_verdict.get(&pid) {
            Some(&v) => (v, false),
            None => {
                let name = proc_name(pid, &mut sys);
                let v = classify_verdict(&name);
                if v != Verdict::Unknown {
                    pid_verdict.insert(pid, v);
                }
                (v, true)
            }
        };
```

- [ ] **Step 2: 改分類後的集合寫入與 log**

把 `:159-188`（`let lport = ...` 到迴圈尾的 if/else 分類）替換為：

```rust
        let lport = addr.local_port();
        let proto = addr.protocol();
        let v6 = addr.ipv6();
        let closing = format!("{:?}", addr.event()).contains("Close");

        let mut g = shared.lock().unwrap();
        if closing {
            g.tcp_ports.remove(&lport);
            g.udp_ports.remove(&lport);
            g.v6_drop_ports.remove(&lport);
            g.not_target_ports.remove(&lport);
            g.redirects.remove(&lport);
            continue;
        }
        match verdict {
            Verdict::Target => {
                match (proto, v6) {
                    (6, false) => {
                        g.tcp_ports.insert(lport);
                    }
                    (6, true) => {
                        g.v6_drop_ports.insert(lport);
                    }
                    (17, _) => {
                        g.udp_ports.insert(lport);
                    }
                    _ => {}
                }
                drop(g);
                if first_seen {
                    hlog(
                        "INFO",
                        &format!(
                            "connect port={lport} pid={pid} name=KRWebView.exe \
                             verdict=target proto={proto} v6={v6}"
                        ),
                    );
                }
            }
            Verdict::NotTarget => {
                // 非 KRWebView（含 helper 自己對上游的連線）→ 記下供 network_loop 跳過查詢。
                g.not_target_ports.insert(lport);
                drop(g);
                if first_seen {
                    hlog(
                        "INFO",
                        &format!(
                            "connect port={lport} pid={pid} verdict=not_target \
                             proto={proto} v6={v6}"
                        ),
                    );
                }
            }
            Verdict::Unknown => {
                // 映像名一時讀不到：維持未分類（不塞任何集合），交給 SYN fallback。
                drop(g);
                if first_seen {
                    hlog(
                        "WARNING",
                        &format!(
                            "connect port={lport} pid={pid} name=unresolved \
                             verdict=unknown proto={proto} v6={v6} (defer to SYN fallback)"
                        ),
                    );
                }
            }
        }
    }
}
```

> 行為差異：原本 `else` 分支對「非目標與未解析」一律 `not_target_ports.insert`；現在只有明確 `NotTarget` 才 insert，`Unknown` 完全不動集合，故 network_loop 的 `known_not` 短路不再吃掉冷 KRWebView。

- [ ] **Step 2b: 移除未使用的舊 log 匯入（若有）**

若編譯器警告 `proc_name` 之類未使用，忽略（network_loop 仍用）。確認沒有殘留對舊 `pid_is_target` 的引用。

- [ ] **Step 3: 編譯確認**

Run：`cargo build --manifest-path rust_capture_helper\Cargo.toml`
Expected: 編譯成功、無 warning（`pid_verdict`／`Verdict` 都有用到）。

- [ ] **Step 4: 跑 helper 單元測試（確保純函式未被破壞）**

Run：`cargo test --manifest-path rust_capture_helper\Cargo.toml`
Expected: PASS。

- [ ] **Step 5: Commit**

```
git add rust_capture_helper/src/main.rs
git commit -m "fix(capture-helper): treat unresolved process name as unclassified, not not_target"
```

---

## Task 4: network_loop 扣住 SYN 重試 ＋ fallback log（軌 B 核心之二）

對未分類的 :443 SYN，若 owner 行程名一時讀不到，有上限地扣住 SYN 重試 `proc_name`（總延遲上限約 24ms），解析出結果再決定重導向；仍未解析則維持未分類（不毒化），並寫 fallback log。

**Files:**
- Modify: `rust_capture_helper/src/main.rs`（`network_loop` 的 `is_kr_tcp` 區塊 `:239-259`，新增重試函式）

**Interfaces:**
- Consumes：`find_tcp_pid`、`proc_name`、`classify_verdict`、`hlog`、`TARGET_PROCESS`。
- Produces：`fn resolve_syn_target_with_retry(port: u16, sys: &mut System) -> Verdict`。

- [ ] **Step 1: 新增有上限的重試解析函式**

在 `tcp_port_is_target`（`:539`）附近新增：

```rust
/// 對剛學到的 :443 SYN，查 owner 行程並分類；剛 spawn 的行程映像名可能一時讀不到，
/// 故有上限地重試（最多 RETRIES 次、每次間隔 DELAY_MS，總延遲上限 RETRIES*DELAY_MS）。
/// 回傳 Target/NotTarget 為已定案；Unknown 代表重試後仍無法解析（呼叫端應維持未分類、不毒化）。
fn resolve_syn_target_with_retry(port: u16, sys: &mut System) -> Verdict {
    const RETRIES: u32 = 4;
    const DELAY_MS: u64 = 6;
    for attempt in 0..=RETRIES {
        if let Some(pid) = find_tcp_pid(port, false) {
            let v = classify_verdict(&proc_name(pid, sys));
            if v != Verdict::Unknown {
                return v;
            }
        }
        if attempt < RETRIES {
            std::thread::sleep(std::time::Duration::from_millis(DELAY_MS));
        }
    }
    Verdict::Unknown
}
```

- [ ] **Step 2: 改 `is_kr_tcp` 的 fallback 分支**

把 `network_loop` 內 `is_kr_tcp` 計算（`:239-259`）替換為：

```rust
        let is_kr_tcp = p.proto == 6 && p.dst_port == TARGET_PORT && {
            let (known_kr, known_not) = {
                let g = shared.lock().unwrap();
                (
                    g.tcp_ports.contains(&p.src_port),
                    g.not_target_ports.contains(&p.src_port),
                )
            };
            if known_kr {
                true
            } else if known_not {
                false
            } else if is_syn_only(packet.data.as_ref(), p.ihl) {
                // 未分類的 :443 SYN：扣住重試解析 owner（冷 spawn 行程名一時讀不到）。
                // 重導向必須在 SYN 當下完成，故在此定案；期間不 reinject 本封包。
                match resolve_syn_target_with_retry(p.src_port, &mut sys) {
                    Verdict::Target => {
                        shared.lock().unwrap().tcp_ports.insert(p.src_port);
                        hlog(
                            "INFO",
                            &format!("syn-fallback port={} verdict=target -> redirect", p.src_port),
                        );
                        true
                    }
                    Verdict::NotTarget => {
                        shared.lock().unwrap().not_target_ports.insert(p.src_port);
                        hlog(
                            "INFO",
                            &format!("syn-fallback port={} verdict=not_target -> skip", p.src_port),
                        );
                        false
                    }
                    Verdict::Unknown => {
                        // 重試後仍讀不到：維持未分類、不毒化，讓後續（如重送 SYN）再試。
                        hlog(
                            "WARNING",
                            &format!("syn-fallback port={} verdict=unknown -> skip (not poisoned)", p.src_port),
                        );
                        false
                    }
                }
            } else {
                false
            }
        };
```

> 差異：原 fallback 用 `tcp_port_is_target`（等同 `Some(false)` 與 `Unknown` 都回 false 且不記錄），現在明確區分「明確非目標→記 not_target（省後續查表）」與「未解析→不記錄（保留再試機會）」，並各寫一行 log。`tcp_port_is_target`（`:539`）若不再被其他地方使用可保留（v6 路徑 `v6_drop_decision` 仍用它），**勿刪**。

- [ ] **Step 3: 編譯確認**

Run：`cargo build --manifest-path rust_capture_helper\Cargo.toml`
Expected: 編譯成功。（`tcp_port_is_target` 仍被 `v6_drop_decision` 使用，不會有 dead-code warning。）

- [ ] **Step 4: 跑 helper 單元測試**

Run：`cargo test --manifest-path rust_capture_helper\Cargo.toml`
Expected: PASS。

- [ ] **Step 5: Commit**

```
git add rust_capture_helper/src/main.rs
git commit -m "fix(capture-helper): hold-and-retry SYN owner lookup for cold-spawned KRWebView"
```

---

## Task 5: shim SNI 判斷 log（軌 A 收尾）

在 shim 每條連線的 SNI 判斷點寫一行 log，讓「導進 MITM」還是「直連 passthrough」可見；非目標 host 記成 `(other)` 不落實際主機名。

**Files:**
- Modify: `rust_capture_helper/src/main.rs`（`shim_listener` 執行緒 `:354-390`）

- [ ] **Step 1: 在 SNI 分支加 log**

在 `shim_listener` 的 `thread::spawn` 內、`peek_sni` 之後，把 if/else（`:358`）改為：

```rust
            let sni = peek_sni(&mut client, &mut head);
            if sni.as_deref() == Some(TARGET_API_HOST) {
                let host = sni.unwrap();
                hlog("INFO", &format!("shim cport={cport} sni={host} -> mitm"));
                match connect_via_mitm(&host, &head, mitm_port) {
                    Ok(up) => {
                        let _ = splice(client, up);
                    }
                    Err(e) => eprintln!("[shim] {cport} ({host}) CONNECT 進 MITM 失敗：{e}"),
                }
            } else {
                hlog("INFO", &format!("shim cport={cport} sni=(other) -> passthrough"));
                // 其餘一律直連原始 server passthrough（conntrack 查 IP，head 先補送）。
                let server_ip = shared
```

（其餘 passthrough 內容不變。）

- [ ] **Step 2: 編譯確認**

Run：`cargo build --manifest-path rust_capture_helper\Cargo.toml`
Expected: 編譯成功。

- [ ] **Step 3: Commit**

```
git add rust_capture_helper/src/main.rs
git commit -m "feat(capture-helper): log shim SNI routing decision"
```

---

## Task 6: 全量品質檢查 ＋ 手動 E2E 驗收

**Files:** 無（僅執行與驗收）

- [ ] **Step 1: Dart 格式化／分析／測試全綠**

Run：
```
fvm dart format lib/ test/
fvm flutter analyze
fvm flutter test
```
Expected: `analyze` → `No issues found!`；`test` → `All tests passed!`。

- [ ] **Step 2: helper Rust 測試全綠**

Run（已設 `WINDIVERT_PATH`）：`cargo test --manifest-path rust_capture_helper\Cargo.toml`
Expected: 全數 PASS。

- [ ] **Step 3: 建置整包（含 helper 由 CMake 觸發 cargo）**

Run：`fvm flutter build windows --release`（或依 `scripts/build_installer/build_release.ps1`）
Expected: 建置成功，`capture_helper.exe` 產生並 install 到 runner 目錄旁。

- [ ] **Step 4: 手動 E2E 驗收（核心）**

執行 release build，重現使用者情境並驗收：

1. 重開遊戲 → app 點「更新資料」→ 依提示回遊戲開卡池歷史頁。
2. **預期：首次即命中**（不再需要取消重試）。多試幾輪（含只關頁再開、含整個 client 重啟）確認穩定。
3. 設定頁匯出 log，檢查當天 `YYYY-MM-DD.log`：
   - 有 `[capture.helper]` 行，且**與 app 行交錯處無斷行汙染**（每行都以完整時間戳開頭）。
   - 冷啟動時可見軌跡：`connect ... verdict=unknown (defer to SYN fallback)` → `syn-fallback ... verdict=target -> redirect`（證實 `proc_name` race 為主因），或 `shim ... sni=gmserver-api.aki-game2.net -> mitm`。
   - 若反而看到「該 :443 從未出現在事件流、卻 no match」→ 指向**連線復用**機制，記錄下來另案處理（本計畫的軌 B 不涵蓋，但軌 B 的不毒化仍為無害改進）。
   - log 內**無** body／憑證等敏感內容；非目標 SNI 顯示 `(other)`。

- [ ] **Step 5: 依 E2E 結果決定是否需 proc_name 強化（gate）**

檢視 E2E log 的 `syn-fallback ... verdict=unknown` 出現頻率：
- **幾乎不出現**（重試已足夠解析）→ 無需再改，跳過。
- **頻繁出現且伴隨 no match**（重試上限仍讀不到）→ 記為後續獨立變更：把 `proc_name` 改用 Win32 `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` + `QueryFullProcessImageNameW`（elevated helper 有權限），以更可靠解析年輕行程；此為 spec §5.3 的延伸，**本計畫不強制實作**，避免未驗證的改動。

- [ ] **Step 6: 更新 spec 狀態並 commit（若有 E2E 觀察值得記錄）**

若 E2E 證實了主因或發現替代機制，於 spec 末補一行「驗收觀察」。

```
git add docs/superpowers/specs/2026-07-15-recapture-cold-krwebview-and-helper-logging-design.md
git commit -m "docs: record E2E acceptance observations for recapture fix"
```

---

## Self-Review

**Spec coverage：**
- 軌 A log 落點（併入當天主 log、沿用保留/匯出）→ Task 2（init_hlog 用 `helper_log_file_name`）＋純函式 Task 1。✓
- 軌 A 路徑流動（Dart→frb→spawn→argv）→ Task 2 Steps 3-8。✓
- 軌 A 記錄內容（CONNECT 分類／unresolved 警告／SYN fallback／redirect／SNI）→ Task 3（CONNECT）、Task 4（SYN fallback）、Task 5（SNI）。✓
- 軌 A 脫敏（只記 port/pid/name/host、非目標 SNI 記 `(other)`）→ Task 5 ＋ Global Constraints。✓
- 軌 B §5.1 socket_watcher 三態、不毒化 → Task 3。✓
- 軌 B §5.2 network_loop 扣住 SYN 重試、None 不毒化、明確非目標才記 not_target → Task 4。✓
- 軌 B §5.3 proc_name 強化「實作期驗證」→ Task 6 Step 5（gate，不強制）。✓
- §6 契約（既有流程不變、frb 簽名變更、`GachaCapture.start()` 介面不變）→ Task 2（start() 無參數、僅 RustGachaCapture 內部帶路徑）。✓
- §7 測試（純邏輯單元測、格式、E2E）→ Task 1（單元測）、Task 6（E2E）。✓
- §8 風險（併寫交錯、SYN 延遲、根因未證實）→ Task 2 Step 7 註解、Task 4 重試上限、Task 6 Step 4-5。✓

**Placeholder scan：** 無 TBD/TODO；每個改碼步驟都附完整程式碼；Task 6 Step 5 的 proc_name 強化為明確 gate 條件（非 placeholder，附具體 Win32 API 名）。✓

**Type consistency：** `Verdict`（Task 1）於 Task 3/4 一致使用；`classify_verdict`／`hlog`／`format_helper_log_line`／`helper_log_file_name` 簽名跨任務一致；`resolve_syn_target_with_retry` 回 `Verdict`（Task 4）與 socket_watcher 的三態對齊；`RustGachaCapture(String logsPath)`／`logsPath`（Task 2 測試與實作一致）；frb `startCapture({required String logDir})` 與 Dart 呼叫 `startCapture(logDir: logsPath)` 一致。✓
