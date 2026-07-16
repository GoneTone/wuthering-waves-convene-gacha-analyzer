//! 提權 helper 的 log 轉發:helper 無 frb 橋、又無法與 app 併寫同一 log 檔（Windows share
//! 衝突），故改由 helper 連本機 TCP 送 log 行；本模組在 app（行程內 Rust）收下後轉成 tracing
//! 事件（target `capture.helper`），沿用既有 tracing → frb → Dart LogService 的落地路徑,
//! 由 Dart 單一寫入者寫進當天 log 檔。

use std::io::{BufRead, BufReader};
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

use anyhow::Result;

/// helper log 轉發用的本機埠（沿用 18080 MITM／18081 shim 的固定埠風格）。
pub const LOG_RELAY_PORT: u16 = 18082;

/// RAII guard:drop 時通知 reader 執行緒停止並 join。
pub struct LogRelayGuard {
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl Drop for LogRelayGuard {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

/// 綁定 127.0.0.1:port、起一條 reader 執行緒等 helper 連入並轉發其 log 行。
/// 正式路徑:每行經 [`emit_tracing`] 轉成 tracing 事件。
pub fn start(port: u16) -> Result<LogRelayGuard> {
    start_with_sink(port, emit_tracing)
}

/// [`start`] 的可注入版本:`sink(level, msg)` 決定每行的去向（正式用 tracing、測試用 channel）。
fn start_with_sink<F>(port: u16, sink: F) -> Result<LogRelayGuard>
where
    F: Fn(&str, &str) + Send + 'static,
{
    let listener = TcpListener::bind(("127.0.0.1", port))?;
    listener.set_nonblocking(true)?;
    let stop = Arc::new(AtomicBool::new(false));
    let stop_thread = stop.clone();
    let handle = std::thread::spawn(move || relay_loop(listener, stop_thread, sink));
    Ok(LogRelayGuard {
        stop,
        handle: Some(handle),
    })
}

/// 等 helper 連入（nonblocking accept + stop 檢查），連上後逐行讀取並經 `sink` 轉發,直到 EOF 或 stop。
fn relay_loop<F: Fn(&str, &str)>(listener: TcpListener, stop: Arc<AtomicBool>, sink: F) {
    let stream = loop {
        if stop.load(Ordering::SeqCst) {
            return;
        }
        match listener.accept() {
            Ok((s, _)) => break s,
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(_) => return,
        }
    };
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(Duration::from_millis(300)));
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    loop {
        if stop.load(Ordering::SeqCst) {
            break;
        }
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break, // EOF:helper 已退出
            Ok(_) => forward(line.trim_end_matches(['\r', '\n']), &sink),
            Err(ref e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                continue; // 讀取 timeout:回頭檢查 stop
            }
            Err(_) => break,
        }
    }
}

/// 解析一行 `LEVEL\tMESSAGE`;無 tab 則整行視為 message、level 預設 INFO。
fn parse_line(line: &str) -> (&str, &str) {
    line.split_once('\t').unwrap_or(("INFO", line))
}

/// 空行略過,其餘解析後交給 `sink`。
fn forward<F: Fn(&str, &str)>(line: &str, sink: &F) {
    if line.is_empty() {
        return;
    }
    let (level, msg) = parse_line(line);
    sink(level, msg);
}

/// 正式轉發:依 level 呼叫對應 tracing 巨集（target `capture.helper`，沿用既有 forward 到 Dart 的路徑）。
fn emit_tracing(level: &str, msg: &str) {
    match level {
        "WARNING" | "WARN" => tracing::warn!(target: "capture.helper", "{msg}"),
        "SEVERE" | "ERROR" => tracing::error!(target: "capture.helper", "{msg}"),
        _ => tracing::info!(target: "capture.helper", "{msg}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::net::TcpStream;
    use std::sync::mpsc;

    #[test]
    fn parse_line_splits_level_and_message() {
        assert_eq!(
            parse_line("WARNING\tport=1 pid=2"),
            ("WARNING", "port=1 pid=2")
        );
        assert_eq!(parse_line("INFO\thello"), ("INFO", "hello"));
        assert_eq!(parse_line("no-tab"), ("INFO", "no-tab"));
    }

    /// 端到端(同機)驗證:client 連上 relay、送兩行 helper 協定格式,relay 讀取→解析→經 sink 轉出。
    /// client 全程存活(不像無 admin 的真 helper 會秒退 RST),故無競態、可確定性斷言。
    #[test]
    fn relay_receives_parses_and_forwards_lines() {
        // 先綁 :0 找一個空閒埠,再交給 relay,避免固定埠衝突。
        let free = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = free.local_addr().unwrap().port();
        drop(free);

        let (tx, rx) = mpsc::channel::<(String, String)>();
        let sink = move |level: &str, msg: &str| {
            let _ = tx.send((level.to_string(), msg.to_string()));
        };
        let _guard = start_with_sink(port, sink).expect("relay start");

        // 以 client 身分連上(重試等 listener 就緒),連線全程保持存活。
        let mut client = None;
        for _ in 0..100 {
            if let Ok(s) = TcpStream::connect(("127.0.0.1", port)) {
                client = Some(s);
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let mut client = client.expect("connect to relay");
        client.write_all(b"INFO\tcapture_helper started\n").unwrap();
        client
            .write_all(b"WARNING\tport=51000 verdict=unknown\n")
            .unwrap();
        client.flush().unwrap();

        let first = rx.recv_timeout(Duration::from_secs(3)).expect("line 1");
        let second = rx.recv_timeout(Duration::from_secs(3)).expect("line 2");
        assert_eq!(
            first,
            ("INFO".to_string(), "capture_helper started".to_string())
        );
        assert_eq!(
            second,
            ("WARNING".to_string(), "port=51000 verdict=unknown".to_string())
        );

        drop(client); // 斷言完才關,避免中途 RST
    }
}
