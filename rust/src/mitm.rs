use crate::api::capture::CapturedRequest;
use crate::frb_generated::StreamSink;
use anyhow::{Context, Result};
use bytes::Bytes;
use http_body_util::BodyExt;
use hudsucker::{
    certificate_authority::RcgenAuthority,
    hyper::{Method, Request, Response, Uri},
    rcgen::{Issuer, KeyPair},
    rustls::{crypto::aws_lc_rs, ClientConfig},
    Body, HttpContext, HttpHandler, Proxy, RequestOrResponse,
};
use hyper_rustls::{ConfigBuilderExt, HttpsConnectorBuilder};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::oneshot;

/// 鳴潮國際服喚取記錄 API 的 host（精確等值；YAGNI：不預留國服）。
const TARGET_HOST: &str = "gmserver-api.aki-game2.net";

/// 鳴潮喚取記錄查詢 API 的 path（精確等值，非 ends_with）。
const TARGET_PATH: &str = "/gacha/record/query";

pub struct MitmServerGuard {
    shutdown_tx: Option<oneshot::Sender<()>>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl Drop for MitmServerGuard {
    fn drop(&mut self) {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(());
        }
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

/// 是否為要攔截的鳴潮喚取記錄查詢請求：POST + 精確 host + 精確 path。
///
/// 與前身版本差異：改用精確等值（非 `ends_with`），並加驗 method == POST，
/// 避免攔到同端點的預檢 OPTIONS 或子網域偽冒（如 `evil.gmserver-api.aki-game2.net`）。
fn is_target(method: &Method, uri: &Uri) -> bool {
    let host_ok = uri.host().map(|h| h == TARGET_HOST).unwrap_or(false);
    let path_ok = uri.path() == TARGET_PATH;
    method == Method::POST && host_ok && path_ok
}

/// 把 hudsucker `Body`（streaming）整段收齊，回 `(body 字串, 收齊的 bytes)`。
///
/// 呼叫端用回傳的 bytes 重建 `Body` 放行（漏了重建＝上游收到空 body，遊戲端載入失敗）。
/// 失敗（連線中斷等）回 `Err`，呼叫端據此放行原請求、不送事件、不 panic。
async fn read_body_string(body: Body) -> Result<(String, Bytes)> {
    let bytes = body
        .collect()
        .await
        .context("collect request body failed")?
        .to_bytes();
    let text = String::from_utf8_lossy(&bytes).into_owned();
    Ok((text, bytes))
}

#[derive(Clone)]
struct LogHandler {
    sink: StreamSink<CapturedRequest>,
    // Arc-shared across handler clones so the first hit wins for the whole proxy.
    fired: Arc<AtomicBool>,
    // 命中後 set true；handle_response 第一次看到後 swap 為 false 並 spawn delayed stop。
    // 不能在 handle_request 內直接 spawn stop：那時上游 response 還沒回來，
    // hudsucker graceful shutdown 不等 outbound in-flight request，會直接切斷 connection。
    pending_stop: Arc<AtomicBool>,
}

impl HttpHandler for LogHandler {
    async fn handle_request(
        &mut self,
        _ctx: &HttpContext,
        req: Request<Body>,
    ) -> RequestOrResponse {
        let (parts, body) = req.into_parts();

        if !is_target(&parts.method, &parts.uri) {
            return Request::from_parts(parts, body).into();
        }

        if self.fired.swap(true, Ordering::SeqCst) {
            return Request::from_parts(parts, body).into();
        }

        // 命中：讀 body（含查詢憑證）。collect 失敗則放行原請求、不送事件、不 panic。
        let (body_text, bytes) = match read_body_string(body).await {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!(target: "mitm", "read body failed, passthrough without capture: {e}");
                // 已 swap fired=true 但讀失敗：此請求放行（用空 body 重建已不可能取回原 bytes），
                // 不送 CapturedRequest；玩家重開喚取記錄頁會再觸發一次命中。
                // 不重設 fired：避免同一次 session 反覆嘗試讀同一條失敗連線。
                return Request::from_parts(parts, Body::empty()).into();
            }
        };

        let method = parts.method.to_string();
        let url = parts.uri.to_string();
        let host = parts.uri.host().unwrap_or("").to_string();
        let timestamp_ms = chrono::Utc::now().timestamp_millis();

        // 只印命中事實 + body 長度，不印 body 原文（含 playerId）。
        tracing::info!(
            target: "mitm",
            "hit convene endpoint: {} {} body_len={}",
            method,
            url,
            bytes.len()
        );

        let _ = self.sink.add(CapturedRequest {
            method,
            url,
            host,
            timestamp_ms,
            body: body_text,
        });

        // 暫不 spawn stop_capture：要等 response 從上游回來，避免 hudsucker 太早 shutdown 切斷 connection。
        self.pending_stop.store(true, Ordering::SeqCst);

        // 用收齊的 bytes 重建 body 放行（漏了＝上游收到空 body，遊戲端載入失敗）。
        Request::from_parts(parts, Body::from(bytes)).into()
    }

    async fn handle_response(&mut self, _ctx: &HttpContext, res: Response<Body>) -> Response<Body> {
        if self.pending_stop.swap(false, Ordering::SeqCst) {
            tracing::info!(target: "mitm", "handle_response after hit: status {}, scheduling stop", res.status());

            // 在 mitm runtime 之外觸發 stop，避免 self-join 死鎖。
            // 延遲 500ms 給 hudsucker 把 response body stream 完整寫回 client socket
            // （handle_response 觸發 = 上游 headers 已到，body 仍在 stream）。
            std::thread::spawn(|| {
                std::thread::sleep(std::time::Duration::from_millis(500));
                if let Err(e) = crate::api::capture::stop_capture() {
                    tracing::error!(target: "mitm", "auto-stop after match failed: {e}");
                }
            });
        }
        res
    }
}

pub fn start(
    addr: SocketAddr,
    cert_pem: &str,
    key_pem: &str,
    sink: StreamSink<CapturedRequest>,
) -> Result<MitmServerGuard> {
    let key_pair = KeyPair::from_pem(key_pem).context("rcgen KeyPair::from_pem failed")?;
    let issuer =
        Issuer::from_ca_cert_pem(cert_pem, key_pair).context("Issuer::from_ca_cert_pem failed")?;

    let provider = aws_lc_rs::default_provider();
    let ca = RcgenAuthority::new(issuer, 1_000, provider);

    // with_http_connector lets us supply a ClientConfig with ALPN h2 + http/1.1
    // (the default with_rustls_connector skips ALPN, breaking h2-only servers).
    let tls_config = ClientConfig::builder_with_provider(Arc::new(aws_lc_rs::default_provider()))
        .with_safe_default_protocol_versions()
        .context("rustls ClientConfig: no supported protocol versions")?
        .with_webpki_roots()
        .with_no_client_auth();

    let https_connector = HttpsConnectorBuilder::new()
        .with_tls_config(tls_config)
        .https_or_http()
        .enable_http1()
        .enable_http2()
        .build();

    let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();

    let handler = LogHandler {
        sink,
        fired: Arc::new(AtomicBool::new(false)),
        pending_stop: Arc::new(AtomicBool::new(false)),
    };

    let handle = std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("build tokio rt for mitm");

        rt.block_on(async move {
            let proxy = Proxy::builder()
                .with_addr(addr)
                .with_ca(ca)
                .with_http_connector(https_connector)
                .with_http_handler(handler)
                .with_graceful_shutdown(async move {
                    let _ = shutdown_rx.await;
                })
                .build()
                .expect("hudsucker proxy build failed");

            if let Err(e) = proxy.start().await {
                tracing::error!(target: "mitm", "mitm proxy stopped: {e}");
            }
        });
    });

    Ok(MitmServerGuard {
        shutdown_tx: Some(shutdown_tx),
        handle: Some(handle),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use hudsucker::hyper::{Method, Uri};

    /// 命中：POST + 精確 host + 精確 path。
    #[test]
    fn matches_wuwa_convene_post() {
        let uri: Uri = "https://gmserver-api.aki-game2.net/gacha/record/query"
            .parse()
            .unwrap();
        assert!(is_target(&Method::POST, &uri));
    }

    /// method 非 POST → 不命中（避免攔到同端點的預檢 OPTIONS / 其他 verb）。
    #[test]
    fn rejects_non_post_method() {
        let uri: Uri = "https://gmserver-api.aki-game2.net/gacha/record/query"
            .parse()
            .unwrap();
        assert!(!is_target(&Method::GET, &uri));
        assert!(!is_target(&Method::OPTIONS, &uri));
    }

    /// host 不符（含國服 host、子網域）→ 不命中（YAGNI：只支援國際服）。
    #[test]
    fn rejects_wrong_host() {
        for url in [
            "https://gmserver-api.aki-game.net/gacha/record/query", // 國服，不支援
            "https://evil.gmserver-api.aki-game2.net/gacha/record/query",
            "https://gmserver-api.aki-game2.net.evil.com/gacha/record/query",
        ] {
            let uri: Uri = url.parse().unwrap();
            assert!(!is_target(&Method::POST, &uri), "should reject {url}");
        }
    }

    /// path 不符（前後綴、別的 path）→ 不命中（精確等值，非 ends_with）。
    #[test]
    fn rejects_wrong_path() {
        for url in [
            "https://gmserver-api.aki-game2.net/gacha/record/query/extra",
            "https://gmserver-api.aki-game2.net/x/gacha/record/query",
            "https://gmserver-api.aki-game2.net/gacha/record",
            "https://gmserver-api.aki-game2.net/",
        ] {
            let uri: Uri = url.parse().unwrap();
            assert!(!is_target(&Method::POST, &uri), "should reject {url}");
        }
    }

    /// 無 host（相對 URI）→ 不 panic、回 false。
    #[test]
    fn rejects_uri_without_host() {
        let uri: Uri = "/gacha/record/query".parse().unwrap();
        assert!(!is_target(&Method::POST, &uri));
    }

    /// read_body_string：把 Body 收齊成字串並回傳同等 bytes 供重建。
    #[tokio::test]
    async fn read_body_string_collects_full_body() {
        let json = r#"{"playerId":"701","cardPoolType":1}"#;
        let body = Body::from(json.to_string());
        let (text, bytes) = read_body_string(body).await.unwrap();
        assert_eq!(text, json);
        assert_eq!(bytes.as_ref(), json.as_bytes());
    }

    /// 空 body 不報錯，回空字串。
    #[tokio::test]
    async fn read_body_string_handles_empty() {
        let (text, bytes) = read_body_string(Body::empty()).await.unwrap();
        assert_eq!(text, "");
        assert!(bytes.is_empty());
    }
}
