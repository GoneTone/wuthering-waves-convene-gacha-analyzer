use crate::frb_generated::StreamSink;
use crate::{ca, cert_store, helper, mitm};
use anyhow::{anyhow, Result};
use flutter_rust_bridge::frb;
use once_cell::sync::Lazy;
use std::net::SocketAddr;
use std::sync::Mutex;

/// 主程式 hudsucker MITM 監聽位址；helper 的 shim 對此埠發 CONNECT。
const PROXY_ADDR: &str = "127.0.0.1:18080";

#[derive(Clone)]
#[frb]
pub struct CapturedRequest {
    pub method: String,
    pub url: String,
    pub host: String,
    pub timestamp_ms: i64,
    /// 攔到的 POST 請求 body 原文（JSON 字串）。鳴潮喚取憑證在此（playerId 等），
    /// Dart 端用 `GachaCredential.fromCapturedBody` 解析；Rust 端絕不印其原文。
    pub body: String,
}

struct Session {
    // Drop 順序刻意（宣告序＝drop 序）：_helper 先 drop → 設停止事件、等 helper 退出、WinDivert
    // 重導向還原（KRWebView :443 恢復直連）；_mitm 後 drop → graceful shutdown。命中後的
    // gmserver response 早在 mitm.rs 的延遲 auto-stop 前已回傳，故先停重導向不影響 in-flight。
    _helper: helper::HelperHandle,
    _mitm: mitm::MitmServerGuard,
}

static SESSION: Lazy<Mutex<Option<Session>>> = Lazy::new(|| Mutex::new(None));

pub fn start_capture(log_dir: String, sink: StreamSink<CapturedRequest>) -> Result<()> {
    let mut guard = SESSION.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_some() {
        return Err(anyhow!("capture already running"));
    }

    crate::api::logging::init_tracing_once();

    let root = ca::load_or_generate()?;
    cert_store::install_to_current_user_root(&root.cert_der)?;

    let addr: SocketAddr = PROXY_ADDR.parse()?;
    // 先起 MITM（確保 helper 的 shim CONNECT 時它已在聽），再 UAC 提權 spawn helper。
    // helper spawn 失敗（UAC 取消等）會讓上面的 mitm（區域變數）drop、自動收掉。
    let mitm = mitm::start(addr, &root.cert_pem, &root.key_pem, sink)?;
    let helper = helper::spawn(addr.port(), &log_dir)?;

    *guard = Some(Session {
        _helper: helper,
        _mitm: mitm,
    });
    Ok(())
}

pub fn stop_capture() -> Result<()> {
    let mut guard = SESSION.lock().unwrap_or_else(|e| e.into_inner());
    *guard = None; // Drop 順序：_helper 先（停重導向）→ _mitm（graceful shutdown）
    Ok(())
}
