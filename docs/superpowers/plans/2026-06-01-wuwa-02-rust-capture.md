# Rust Capture POST Body Interception Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 把 `rust/` MITM 攔截從原神的 GET `*.hoyoverse.com/getGachaLog` 改為鳴潮的 POST `gmserver-api.aki-game2.net/gacha/record/query`，命中後讀取請求 body（含查詢憑證）、重建 body 放行，並把 body 經 frb sink 帶回 Dart。

**Architecture:** `mitm.rs::is_target` 抽出 `TARGET_HOST`/`TARGET_PATH` 常數並改為精確等值比對（含 `method == POST`），做成可單元測試的純函式 `is_target(method, uri)`。`handle_request` 命中分支用 `http_body_util::BodyExt::collect` 把 streaming body 收成 `Bytes`、轉成 `String`、塞進 `CapturedRequest.body`，再用同一份 bytes `Body::from(bytes)` 重建請求放行；collect 失敗則放行原請求、不送事件、不 panic。`CapturedRequest` 新增 `body: String`，改完重跑 flutter_rust_bridge codegen 讓 `lib/src/rust/api/capture.dart` 自動更新。

**Tech Stack:** Rust（hudsucker 0.24 / hyper 1 / `http-body-util` 0.1 / `bytes` 1）、flutter_rust_bridge 2.12.0、cargo test。

---

## 背景事實（實作前已查證，供 worker 對照）

- `rust/src/mitm.rs:33` 現有 `fn is_target(uri: &Uri) -> bool`，只比 host/path，**不檢查 method**；`handle_request`（`mitm.rs:55`）只讀 `parts.method/uri/host`，**完全不碰 body**。
- `rust/src/api/capture.rs:12` 的 `CapturedRequest` 目前欄位為 `method/url/host/timestamp_ms`（`#[frb]`，`#[derive(Clone)]`）。
- `hudsucker::Body`（hudsucker 0.24.1 `src/body.rs`）實作 `http_body::Body`（`type Data = Bytes; type Error = hudsucker::Error`），且有 `impl From<Bytes> for Body`、`From<Vec<u8>>`、`From<String>`。**hudsucker 不 re-export `http_body_util` / `BodyExt`**（只 re-export `hyper`/`hyper_util`），故需在 `Cargo.toml` 直接加 `http-body-util`。
- `http-body-util` 已在 `rust/Cargo.lock`（`0.1.3`，hudsucker 要求 `0.1.0`），`bytes` 已在 lock（`1.11.1`）。直接加 `http-body-util = "0.1"` 會解析到同一版本，無 hyper 版本衝突。
- 既有 Rust 測試 idiom：`#[cfg(test)] mod tests { use super::*; ... }`（見 `rust/src/cert_store.rs:137`、`rust/src/ca.rs:167`）。
- frb 設定：`flutter_rust_bridge.yaml`（`rust_input: crate::api`、`dart_output: lib/src/rust`）；改 `CapturedRequest` 後產生的綁定在 `lib/src/rust/api/capture.dart:20`。
- 本 plan **不**處理 crate 改名（`genshin_capture_core` → `gacha_capture_core`）、CA 去原神化（皆屬 plan01 改名）、Dart 端 `gacha_capture.dart` 消費 `event.body`（屬 plan04 抓取）：那些屬其他 plan。本 plan 只動 `rust/src/mitm.rs`、`rust/src/api/capture.rs`、`rust/Cargo.toml`，並重跑 frb codegen 更新 `lib/src/rust/api/capture.dart`。
- 注意 CLAUDE.md：`rust_builder/` 勿手改；Rust 邏輯改 `rust/`（crate）；frb 綁定改完重跑 codegen，不要手改 `lib/src/rust/*` 與 `rust/src/frb_generated.rs`。

---

## Task 1：`is_target` 改鳴潮 POST 端點（抽常數 + 純函式 + 單元測試，TDD）

把 `is_target` 改成可單元測試的純函式 `is_target(method, uri)`，比對 `method == POST && host == TARGET_HOST && path == TARGET_PATH`，並抽出 `TARGET_HOST`/`TARGET_PATH` 常數。先寫測試。

**Files:**
- Modify: `rust/src/mitm.rs`（常數 + `is_target` 在 `mitm.rs:33-41`；呼叫點 `mitm.rs:62`；新增檔尾 `#[cfg(test)] mod tests`）
- Test: `rust/src/mitm.rs`（同檔 `#[cfg(test)] mod tests`，沿用 `cert_store.rs:137` idiom）

**Steps:**

- [ ] 在 `rust/src/mitm.rs` 既有 `use hudsucker::{...}` 區塊內，把 `hyper::{Request, Response, Uri}` 改為 `hyper::{Method, Request, Response, Uri}`（為 `is_target` 的 method 參數型別與測試用）。將 `mitm.rs:6` 那行：
  ```rust
      hyper::{Request, Response, Uri},
  ```
  改為：
  ```rust
      hyper::{Method, Request, Response, Uri},
  ```

- [ ] 在 `rust/src/mitm.rs` 檔尾新增單元測試（先寫失敗測試），貼上：
  ```rust
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
  }
  ```

- [ ] 跑測試確認**失敗**（`is_target` 還是舊簽名 `is_target(&Uri)`，無 method 參數，編譯會錯）：
  ```
  cargo test --manifest-path rust/Cargo.toml is_target
  ```
  預期：編譯錯誤，類似 `this function takes 1 argument but 2 arguments were supplied` / `mismatched types`（測試傳了 `&Method`）。這就是預期的失敗。

- [ ] 在 `rust/src/mitm.rs` 的 `MitmServerGuard` struct 定義**之前**（約 `mitm.rs:16` 上方、`use` 區塊之後）新增兩個常數與其 dartdoc 對應的 Rust doc comment：
  ```rust
  /// 鳴潮國際服喚取記錄 API 的 host（精確等值；YAGNI：不預留國服）。
  const TARGET_HOST: &str = "gmserver-api.aki-game2.net";

  /// 鳴潮喚取記錄查詢 API 的 path（精確等值，非 ends_with）。
  const TARGET_PATH: &str = "/gacha/record/query";
  ```

- [ ] 用以下實作取代 `rust/src/mitm.rs:33-41` 既有的 `is_target`：
  ```rust
  /// 是否為要攔截的鳴潮喚取記錄查詢請求：POST + 精確 host + 精確 path。
  ///
  /// 與原神版差異：改用精確等值（非 `ends_with`），並加驗 method == POST，
  /// 避免攔到同端點的預檢 OPTIONS 或子網域偽冒（如 `evil.gmserver-api.aki-game2.net`）。
  fn is_target(method: &Method, uri: &Uri) -> bool {
      let host_ok = uri.host().map(|h| h == TARGET_HOST).unwrap_or(false);
      let path_ok = uri.path() == TARGET_PATH;
      method == Method::POST && host_ok && path_ok
  }
  ```

- [ ] 更新 `is_target` 的呼叫點。把 `rust/src/mitm.rs:62` 的：
  ```rust
          if !is_target(&parts.uri) {
  ```
  改為：
  ```rust
          if !is_target(&parts.method, &parts.uri) {
  ```

- [ ] 跑測試確認**通過**：
  ```
  cargo test --manifest-path rust/Cargo.toml is_target
  ```
  預期：`test result: ok. 5 passed; 0 failed`（5 個 is_target 測試全綠）。

- [ ] 跑全 crate 測試確認沒打壞既有測試：
  ```
  cargo test --manifest-path rust/Cargo.toml
  ```
  預期：`test result: ok.`（含 `ca`/`cert_store`/`mitm` 全部 passed）。

- [ ] commit（若無 git 則略過此步）：
  ```
  git add rust/src/mitm.rs
  git commit -m "feat(rust): retarget mitm to wuwa convene POST endpoint with exact match"
  ```
  commit message 結尾依環境規則附 `Co-Authored-By` 行。

---

## Task 2：`Cargo.toml` 加 `http-body-util` / `bytes` 依賴

`handle_request` 讀 body 需要 `http_body_util::BodyExt::collect` 與 `bytes::Bytes`。hudsucker 未 re-export 這兩者，需直接加為依賴（版本對齊既有 lock，避免 hyper 版本衝突）。

> **對 spec §A.4 的合理偏離（已註明原因）**：spec §A.4 未列出 `http-body-util` / `bytes` 為新增依賴；本 plan 直接把這兩個 crate 加進 `rust/Cargo.toml` 屬刻意偏離。原因：hudsucker 0.24 只 re-export `hyper`/`hyper_util`，**未 re-export** `http_body_util::BodyExt`（`collect`）與 `bytes::Bytes`，而讀取攔到的 POST body 必須用到這兩者。版本皆對齊既有 `Cargo.lock`（http-body-util 0.1.3 / bytes 1.11.1）、與 hudsucker 共用同一份 hyper 1，無版本衝突，故為低風險偏離。

**Files:**
- Modify: `rust/Cargo.toml`（`[dependencies]` 區塊，`Cargo.toml:10-24`）

**Steps:**

- [ ] 在 `rust/Cargo.toml` 的 `[dependencies]` 區塊（`hudsucker`/`hyper-rustls` 那幾行附近，`Cargo.toml:18-19` 之後）新增兩行依賴。把：
  ```toml
  hudsucker = { version = "0.24", default-features = false, features = ["decoder", "rcgen-ca", "rustls-client", "http2"] }
  hyper-rustls = { version = "0.27", default-features = false, features = ["http1", "http2", "tls12", "webpki-tokio"] }
  ```
  改為：
  ```toml
  hudsucker = { version = "0.24", default-features = false, features = ["decoder", "rcgen-ca", "rustls-client", "http2"] }
  hyper-rustls = { version = "0.27", default-features = false, features = ["http1", "http2", "tls12", "webpki-tokio"] }
  # 讀取攔到的 POST body 需要：BodyExt::collect（http-body-util）與 Bytes（bytes）。
  # hudsucker 0.24 未 re-export 這兩者；版本對齊既有 Cargo.lock（http-body-util 0.1.3 / bytes 1.11.1），
  # 與 hudsucker 共用同一份 hyper 1，無版本衝突。
  http-body-util = "0.1"
  bytes = "1"
  ```

- [ ] 確認依賴可解析、版本未被升級（沿用既有 lock 內版本）：
  ```
  cargo update --manifest-path rust/Cargo.toml -p http-body-util --dry-run
  ```
  預期：無變更或維持 `http-body-util v0.1.3`（不應出現意外的大版本跳動）。

- [ ] 確認整個 crate 仍可編譯（含新依賴）：
  ```
  cargo build --manifest-path rust/Cargo.toml
  ```
  預期：`Finished` 無錯（此時尚未用到 `http_body_util`，可能有 unused dependency 警告，於 Task 3 用到後消失，可忽略此暫態警告）。

- [ ] commit（若無 git 則略過）：
  ```
  git add rust/Cargo.toml rust/Cargo.lock
  git commit -m "build(rust): add http-body-util and bytes for reading captured POST body"
  ```

---

## Task 3：`CapturedRequest` 新增 `body: String` + `handle_request` 讀 body 並重建放行

`handle_request` 命中分支：用 `BodyExt::collect` 把 streaming body 收成 `Bytes` → `String::from_utf8_lossy` 放進 `CapturedRequest.body`；用同一份 bytes `Body::from(bytes)` 重建請求放行。collect 失敗 → 放行原請求、不送事件、不 panic。Rust log 只印命中事實 + body 長度（不印 body 原文，含 playerId）。

> **守則（不得更動）**：本 Task 只改寫 `handle_request` 的命中分支（`mitm.rs:66-87`），讀 body 並重建放行。**不得更動** `handle_response`（`mitm.rs:90-105`）的「延遲 500ms 後自動 `stop_capture`」邏輯，也**不得更動** `fired`（`Arc<AtomicBool>`）的一次性命中語意（`fired.swap(true, ...)` 確保整個 proxy 只攔第一筆、後續請求零拷貝放行）。`pending_stop`／延遲停止仍由 `handle_response` 在上游 response 回來後觸發（不可改成在 `handle_request` 內直接 spawn stop，否則 hudsucker graceful shutdown 不等 outbound in-flight request 會切斷 connection）。本 Task 只新增「讀 body + 重建 body」，這些既有時序契約一律原樣保留。

**Files:**
- Modify: `rust/src/api/capture.rs`（`CapturedRequest` struct，`capture.rs:10-17`）
- Modify: `rust/src/mitm.rs`（`use` 區塊；`handle_request` 命中分支，`mitm.rs:66-87`）
- Test: `rust/src/mitm.rs`（`#[cfg(test)] mod tests` 新增 `read_body_string` 的 async 測試）

**Steps:**

- [ ] 在 `rust/src/api/capture.rs` 的 `CapturedRequest`（`capture.rs:12-17`）新增 `body` 欄位。把：
  ```rust
  #[derive(Clone)]
  #[frb]
  pub struct CapturedRequest {
      pub method: String,
      pub url: String,
      pub host: String,
      pub timestamp_ms: i64,
  }
  ```
  改為：
  ```rust
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
  ```

- [ ] 在 `rust/src/mitm.rs` 的 `use hudsucker::{...}` 區塊（`mitm.rs:4-10`）尾端新增 `http_body_util::BodyExt` 與 `bytes::Bytes` 的引用。在 `use hyper_rustls::{ConfigBuilderExt, HttpsConnectorBuilder};`（`mitm.rs:11`）之後新增兩行：
  ```rust
  use http_body_util::BodyExt;
  use bytes::Bytes;
  ```

- [ ] 在 `rust/src/mitm.rs` 的 `is_target` 函式**之後**（`MitmServerGuard`/`LogHandler` 區塊附近，free function 位置）新增可測試的純讀取函式 `read_body_string`：
  ```rust
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
  ```

- [ ] 用以下實作取代 `rust/src/mitm.rs:66-87`（從 `if self.fired.swap(...)` 到命中分支結尾 `Request::from_parts(parts, body).into()`）。注意命中分支內 body 已被 `read_body_string` 消費，需用重建的 `Body::from(bytes)` 放行；非命中與 `fired` 已觸發分支維持零拷貝放行原 body：
  ```rust
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
  ```

- [ ] 移除舊的 `tracing::info!(target: "mitm", "hit gacha endpoint: {} {}", method, url);` 行——確認 `rust/src/mitm.rs` 內**只**剩上一步新增的 `hit convene endpoint` log（舊的 `hit gacha endpoint` 應已在取代範圍內被移除；若殘留則手動刪除）。

- [ ] 確認**未誤動** `handle_response` 與 `fired` 既有時序契約（守則）：`handle_response`（`mitm.rs:90-105`）仍維持「`pending_stop.swap(false)` 命中後延遲 500ms 才 `stop_capture()`」原狀；`fired.swap(true, Ordering::SeqCst)` 的一次性命中語意未改（整個 proxy 只攔第一筆）。本 Task 的取代範圍僅限 `handle_request` 命中分支，不得波及這兩處。

- [ ] 在 `rust/src/mitm.rs` 檔尾 `#[cfg(test)] mod tests` 內，於 `use super::*;` 之後補上 `read_body_string` 的測試（先寫，確認失敗/通過）。在 `mod tests` 內 `rejects_uri_without_host` 測試之後新增：
  ```rust
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
  ```

- [ ] `#[tokio::test]` 需要 `tokio` 的 `macros` + `rt` feature（`rt-multi-thread` 已含 `rt`，`macros` 已在 `Cargo.toml:17` features 內）。確認 `rust/Cargo.toml:17` 的 tokio features 含 `"macros"`（現況：`features = ["rt-multi-thread", "macros", "sync", "net"]` ✓，無需改動）。

- [ ] 跑 body 相關測試確認**通過**：
  ```
  cargo test --manifest-path rust/Cargo.toml read_body_string
  ```
  預期：`test result: ok. 2 passed; 0 failed`。

- [ ] 跑全 crate 測試確認整體綠（含 Task 1 的 is_target 測試）：
  ```
  cargo test --manifest-path rust/Cargo.toml
  ```
  預期：`test result: ok.`（所有 mitm/ca/cert_store 測試 passed，無 failed）。

- [ ] 確認整個 crate 編譯無警告殘留（`http-body-util`/`bytes` 此時已被使用，unused dependency 警告應消失）：
  ```
  cargo build --manifest-path rust/Cargo.toml
  ```
  預期：`Finished` 無 error、無 unused-crate 警告。

- [ ] commit（若無 git 則略過）：
  ```
  git add rust/src/api/capture.rs rust/src/mitm.rs
  git commit -m "feat(rust): capture POST body and rebuild request before forwarding"
  ```

---

## Task 4：重跑 flutter_rust_bridge codegen 更新 Dart 綁定

`CapturedRequest` 改了欄位，必須重跑 frb codegen，讓 `lib/src/rust/api/capture.dart` 的 `CapturedRequest` 自動加上 `body`（**勿手改**生成檔）。

> **codegen 順序註記**：實際執行順序為 plan01（crate 改名 `genshin_capture_core` → `gacha_capture_core` + 重跑 codegen）在前、本 plan02（`CapturedRequest.body` + 重跑 codegen）在後。因此**本 plan02 的這次 codegen 是最終一次**，產生的 `rust/src/frb_generated.rs` 與 `lib/src/rust/*` 需同時反映改名後的 crate stem（plan01 已落地）**與**本 plan 新增的 `body` 欄位。重跑前先確認 `rust/Cargo.toml` 的 crate name 已是 plan01 改名後的值、`flutter_rust_bridge.yaml` 的 `rust_input` 指向改名後的 crate；若 plan01 尚未落地，先完成 plan01 再回到本步，避免生成出指向舊 crate stem 的綁定。

**Files:**
- Generated (勿手改，由 codegen 產生): `lib/src/rust/api/capture.dart`（`CapturedRequest` class，`capture.dart:20-46`）、`lib/src/rust/frb_generated.dart`、`lib/src/rust/frb_generated.io.dart`、`rust/src/frb_generated.rs`

**Steps:**

- [ ] 確認 frb codegen 工具可用（版本須對齊 `Cargo.toml:11` 的 `flutter_rust_bridge = "=2.12.0"`）：
  ```
  flutter_rust_bridge_codegen --version
  ```
  預期：輸出 `2.12.0`。若版本不符或指令不存在，先安裝對齊版本：
  ```
  cargo install flutter_rust_bridge_codegen --version 2.12.0 --locked
  ```

- [ ] 在專案根目錄重跑 codegen（讀 `flutter_rust_bridge.yaml`）：
  ```
  flutter_rust_bridge_codegen generate
  ```
  預期：成功、回報更新 `lib/src/rust/*` 與 `rust/src/frb_generated.rs`。

- [ ] 確認 `lib/src/rust/api/capture.dart` 的 `CapturedRequest` 已新增 `body`。預期生成結果（人工檢視，勿手改）含：
  ```dart
  class CapturedRequest {
    final String method;
    final String url;
    final String host;
    final PlatformInt64 timestampMs;
    final String body;
    // ... const constructor 含 required this.body；hashCode / operator== 含 body
  }
  ```
  若 `body` 未出現，回 Task 3 確認 `pub body: String` 已加且 `#[frb]` 標註未動，再重跑 codegen。

- [ ] 重跑 Rust 測試確認 frb 重生成的 `frb_generated.rs` 未破壞編譯：
  ```
  cargo test --manifest-path rust/Cargo.toml
  ```
  預期：`test result: ok.`。

- [ ] 跑 Dart 靜態分析確認生成綁定合法（**整體遷移期間其他 Dart 檔可能因型別替換短暫紅燈，屬預期**；本步只需確認 `lib/src/rust/api/capture.dart` 本身無語法/型別錯誤，不要求全庫 `No issues found!`）：
  ```
  flutter analyze lib/src/rust/api/capture.dart
  ```
  預期：針對該檔無 error（允許 info/warning）。

- [ ] commit（若無 git 則略過；生成檔一併納入）：
  ```
  git add lib/src/rust/ rust/src/frb_generated.rs
  git commit -m "chore(frb): regenerate bindings for CapturedRequest.body"
  ```

---

## 驗收（本 plan 完成判準）

- [ ] Rust 測試全綠：
  ```
  cargo test --manifest-path rust/Cargo.toml
  ```
  預期：`test result: ok.`（含 is_target ×5、read_body_string ×2，及既有 ca/cert_store 測試）。
- [ ] Rust 編譯無 error、無 unused-crate 警告：
  ```
  cargo build --manifest-path rust/Cargo.toml
  ```
  預期：`Finished`。
- [ ] `lib/src/rust/api/capture.dart` 的 `CapturedRequest` 含 `body: String`（由 codegen 產生，未手改）。
- [ ] `rust/src/mitm.rs` 內已無 `hoyoverse` / `getGachaLog` / `getBeyondGachaLog` 字串、無 `hit gacha endpoint` 舊 log；`is_target` 為精確等值且驗 `method == POST`。

> **跨 plan 註記**：Dart 端 `gacha_capture.dart` 消費 `event.body`（`Future<GachaCredential?>`，其中 `GachaCredential` 由 plan03 資料層定義）與 `sanitizeCredential` log 改寫屬 plan04 抓取、crate 改名（`gacha_capture_core`）與 CA 去原神化屬 plan01 改名，皆不在本 plan 範圍。本 plan 完成後 `flutter test` / 全庫 `flutter analyze` 可能因下游型別尚未遷移而短暫紅燈，**屬整體遷移預期**，待後續 plan 收斂；本 plan 的驗收以上列 Rust 與 capture.dart 綁定為準。標準三檢查（`dart format lib/ test/` → `flutter analyze` 期望 `No issues found!` → `flutter test` 期望 `All tests passed!`）在**全部 plan 完成**後執行。