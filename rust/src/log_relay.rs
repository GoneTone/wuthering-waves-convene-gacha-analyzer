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
pub fn start(port: u16) -> Result<LogRelayGuard> {
    let listener = TcpListener::bind(("127.0.0.1", port))?;
    listener.set_nonblocking(true)?;
    let stop = Arc::new(AtomicBool::new(false));
    let stop_thread = stop.clone();
    let handle = std::thread::spawn(move || relay_loop(listener, stop_thread));
    Ok(LogRelayGuard {
        stop,
        handle: Some(handle),
    })
}

/// 等 helper 連入（nonblocking accept + stop 檢查），連上後逐行讀取並轉發,直到 EOF 或 stop。
fn relay_loop(listener: TcpListener, stop: Arc<AtomicBool>) {
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
            Ok(_) => emit(line.trim_end_matches(['\r', '\n'])),
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

/// 把一行轉成對應 level 的 tracing 事件（target `capture.helper`）。
fn emit(line: &str) {
    if line.is_empty() {
        return;
    }
    let (level, msg) = parse_line(line);
    match level {
        "WARNING" | "WARN" => tracing::warn!(target: "capture.helper", "{msg}"),
        "SEVERE" | "ERROR" => tracing::error!(target: "capture.helper", "{msg}"),
        _ => tracing::info!(target: "capture.helper", "{msg}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_line_splits_level_and_message() {
        assert_eq!(
            parse_line("WARNING\tport=1 pid=2"),
            ("WARNING", "port=1 pid=2")
        );
        assert_eq!(parse_line("INFO\thello"), ("INFO", "hello"));
        assert_eq!(parse_line("no-tab"), ("INFO", "no-tab"));
    }
}
