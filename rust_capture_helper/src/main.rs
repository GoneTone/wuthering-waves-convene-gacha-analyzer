//! 提權的喚取攔截 helper：由主程式（一般權限）UAC 提權 spawn（見 `rust/src/helper.rs`）。
//! WinDivert 把 `KRWebView.exe` 的 :443 透明重導向到本機 shim；shim 只對喚取記錄查詢 API
//! （`gmserver-api.aki-game2.net`）對**主程式的 hudsucker** 發 CONNECT 做 MITM（埠由 argv[1]
//! 傳入），其餘一律直連 passthrough（避免 MITM 重的圖片資源 aki-gm-resources 拖慢頁面；
//! gmserver 為獨立連線、未 coalesce，故不需 MITM 它）。
//!
//! ## 重導向配方（WinDivert issue #82 @da-kami 的 Rust+windivert 實作，已實證）
//! 正向 app→server:443：**src 與 dst 都改成 `127.0.0.1`**、dst 埠改 SHIM_PORT、**方向維持
//! OUTBOUND**。導到 loopback 不能改成 inbound（dst=127.0.0.1/src=公網的封包是 martian 會被丟
//! ——作者 basil00 證實）；src/dst 同為 127.0.0.1 且 outbound，Windows 才會送進 loopback 投遞給
//! 本機 listener。原始位址改用 conntrack（client 埠 → server/client IP + 實體網卡 ifidx）記下。
//! 反向 shim→app：src 設回原始 server:443、dst 設回原始 client、**改 inbound、清 loopback 旗標、
//! ifidx 設回實體網卡**，app 的 ESTABLISHED socket 才認得。
//!
//! ## 行程鎖定（避免 GetExtendedTcpTable 拖慢熱路徑）
//! SOCKET 層 sniff 在 CONNECT 當下（早於 SYN）把 :443 埠分類記入 tcp_ports（KRWebView→導向）
//! 或 not_target_ports（非 KRWebView，含 helper 自己的上游→跳過），用 PID 快取保持 near-instant；
//! 行程名一時讀不到則分類為 `Unknown`——不快取、不塞進任何集合，留給 NETWORK 層的 SYN fallback
//! 重新判定，避免被永久誤標成非目標。network_loop 只查 set，僅罕見 race 才 fallback 查連線表。
//!
//! ## IPv6 / QUIC
//! gmserver 偏好 v6 會繞過 v4 重導向 → 對 KRWebView 的 v6 :443 SYN 送 **RST** 逼退 v4（RST 讓
//! Happy Eyeballs 即時 fallback，不等 ~250ms timeout）；UDP 443（QUIC）靜默 drop 逼退 TCP。
//!
//! 跑法：通常由主程式 spawn。獨立除錯時以系統管理員執行：
//! `capture_helper.exe <mitm_port> [<stop_event_name> <parent_pid> [<log_port>]]`
//! （省略停止事件名/PID 則無看門狗；省略 `log_port` 則不連 log relay，只留 stderr）。

use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;

use sysinfo::{Pid, System};
use windivert::prelude::*;
use windivert_sys::ChecksumFlags;

/// 目標行程（鳴潮喚取 WebView，CEF）。
const TARGET_PROCESS: &str = "KRWebView.exe";
/// 本機 shim 監聽埠（重導向目的埠）。
const SHIM_PORT: u16 = 18081;
/// 預設 MITM proxy 埠（shim 對它發 CONNECT）。實際值由 argv[1] 覆寫（主程式傳入）。
const DEFAULT_MITM_PORT: u16 = 18080;
/// 原始目標埠（喚取 API 皆 :443）。
const TARGET_PORT: u16 = 443;
/// 唯一需要 MITM 的 host（喚取記錄查詢 API）。其餘 SNI 一律 passthrough，避免 MITM 重的
/// 圖片資源（aki-gm-resources）拖慢頁面。gmserver 為獨立連線、未 coalesce，故不需 MITM 它。
const TARGET_API_HOST: &str = "gmserver-api.aki-game2.net";
/// loopback 位址（正向把 src/dst 都改成它）。
const LOOPBACK: [u8; 4] = [127, 0, 0, 1];

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

/// 連向 app log relay 的 socket（多執行緒共享）。未連上時為 None、`hlog` 靜默略過。
static LOG_SOCK: OnceLock<Mutex<TcpStream>> = OnceLock::new();

/// 連上 app 的 log relay（127.0.0.1:port）。失敗則不設，`hlog` 之後為 no-op（僅 eprintln）。
fn init_hlog(log_port: u16) {
    match TcpStream::connect(("127.0.0.1", log_port)) {
        Ok(s) => {
            let _ = LOG_SOCK.set(Mutex::new(s));
        }
        Err(e) => eprintln!("[warn] connect to log relay 127.0.0.1:{log_port} failed: {e}"),
    }
}

/// 送一行 `LEVEL\tMESSAGE\n` 給 app 的 log relay（Mutex 序列化多執行緒、poison 復原）。
/// 未連上時 no-op。同時保留 stderr 供獨立除錯。
fn hlog(level: &str, msg: &str) {
    eprintln!("[{level}] {msg}");
    if let Some(m) = LOG_SOCK.get() {
        let mut s = m.lock().unwrap_or_else(|e| e.into_inner());
        let _ = s.write_all(format!("{level}\t{msg}\n").as_bytes());
    }
}

/// 跨執行緒共享狀態。
#[derive(Default)]
struct Shared {
    /// KRWebView 的 TCP 443 本機埠（要重導向）。
    tcp_ports: HashSet<u16>,
    /// KRWebView 的 UDP 443 本機埠（要 drop / 擋 QUIC）。
    udp_ports: HashSet<u16>,
    /// conntrack：client 本機埠 → (原始 server IP, 原始 client IP, ifidx, sub_ifidx)。
    /// 正向記下原始實體網卡 ifidx，反向時用來把 loopback 回包改回實體 inbound。
    redirects: HashMap<u16, ([u8; 4], [u8; 4], u32, u32)>,
    /// KRWebView 的 IPv6 :443 本機埠（要 drop，逼退回 v4，否則 gmserver 走 v6 繞過重導向）。
    v6_drop_ports: HashSet<u16>,
    /// 已知「非 KRWebView」的 :443 本機埠（含 helper 自己的上游連線）。socket_watcher 在
    /// CONNECT 當下就記下，讓 network_loop 直接跳過、不做昂貴的 GetExtendedTcpTable 查詢。
    not_target_ports: HashSet<u16>,
}

/// 引數：`capture_helper.exe <mitm_port> [<stop_event_name> <parent_pid> [<log_port>]]`。
/// `mitm_port`＝主程式 hudsucker 監聽埠；`stop_event_name`/`parent_pid`＝看門狗（主程式設定
/// 該事件或主程式結束時，helper 自行 exit，WinDivert handle 關閉即還原重導向）；
/// `log_port`＝app 的 log relay 埠，提供時連上該埠、初始化全域 `hlog` 送 log 行給 app。
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mitm_port: u16 = args
        .get(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_MITM_PORT);
    if let (Some(ev), Some(pid)) = (
        args.get(2).cloned(),
        args.get(3).and_then(|s| s.parse::<u32>().ok()),
    ) {
        start_watchdog(ev, pid);
    }
    if let Some(port) = args.get(4).and_then(|s| s.parse::<u16>().ok()) {
        init_hlog(port);
    }
    hlog("INFO", &format!("capture_helper started, mitm_port={mitm_port}"));

    let shared = Arc::new(Mutex::new(Shared::default()));
    {
        let s = shared.clone();
        thread::spawn(move || socket_watcher(s));
    }
    {
        let s = shared.clone();
        thread::spawn(move || shim_listener(s, mitm_port));
    }
    eprintln!("capture_helper: target {TARGET_PROCESS}, shim 127.0.0.1:{SHIM_PORT} -> MITM 127.0.0.1:{mitm_port}");
    network_loop(shared);
}

/// 看門狗：等待「停止事件被設定」或「父行程（主程式）結束」任一發生，即 `exit(0)`。
/// helper 一退出，WinDivert handle 由 OS 關閉，重導向自動還原（主程式無法跨權限 TerminateProcess
/// 提權的 helper，故用此協作式停止）。
fn start_watchdog(event_name: String, parent_pid: u32) {
    use windows::core::HSTRING;
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::System::Threading::{
        OpenEventW, OpenProcess, WaitForMultipleObjects, INFINITE, PROCESS_SYNCHRONIZE,
        SYNCHRONIZATION_ACCESS_RIGHTS,
    };
    const SYNCHRONIZE: SYNCHRONIZATION_ACCESS_RIGHTS = SYNCHRONIZATION_ACCESS_RIGHTS(0x0010_0000);
    thread::spawn(move || unsafe {
        let mut handles: Vec<HANDLE> = Vec::new();
        if let Ok(ev) = OpenEventW(SYNCHRONIZE, false, &HSTRING::from(event_name)) {
            handles.push(ev);
        }
        if let Ok(proc) = OpenProcess(PROCESS_SYNCHRONIZE, false, parent_pid) {
            handles.push(proc);
        }
        if handles.is_empty() {
            return; // 兩者都打不開：無看門狗（不主動退出）
        }
        WaitForMultipleObjects(&handles, false, INFINITE);
        std::process::exit(0);
    });
}

// ── SOCKET 層：追蹤 KRWebView 的 :443 本機埠 ───────────────────────────────

/// WinDivert open 冷開機重試。剛開機後首次 `WinDivertOpen` 常撞 os error 1058
/// （ERROR_SERVICE_DISABLED）：WinDivert 的核心驅動服務在上次關機時留下 pending-delete／停用
/// 殘留，首次開啟要現場重裝會失敗——但**失敗那次通常已把服務重建好**，故退避重試即可成功。
/// 回傳 `Some(handle)` 成功、`None` 表示重試耗盡。每次嘗試都經 [`hlog`] 送回 app 以利診斷。
fn open_windivert_with_retry<T, E: std::fmt::Debug>(
    what: &str,
    mut open: impl FnMut() -> Result<T, E>,
) -> Option<T> {
    const ATTEMPTS: u32 = 8;
    const DELAY_MS: u64 = 400;
    for attempt in 1..=ATTEMPTS {
        match open() {
            Ok(h) => {
                if attempt > 1 {
                    hlog(
                        "INFO",
                        &format!("{what} layer WinDivert open succeeded on attempt {attempt} (driver reinstalled after cold boot)"),
                    );
                }
                return Some(h);
            }
            Err(e) => {
                hlog(
                    "WARNING",
                    &format!("{what} layer WinDivert open attempt {attempt}/{ATTEMPTS} failed: {e:?}"),
                );
                if attempt < ATTEMPTS {
                    std::thread::sleep(std::time::Duration::from_millis(DELAY_MS));
                }
            }
        }
    }
    None
}

/// 在 SOCKET 層 CONNECT 當下就記下 :443 連線屬於哪個行程（KRWebView 或非），供 NETWORK 層
/// O(1) 判斷、不必做昂貴的 GetExtendedTcpTable。CONNECT 事件時間上早於 SYN，故能在 SYN 前記好。
/// 用 PID 快取避免每個事件都 `proc_name`（那會拖慢、輸掉與 SYN 的競態）。
fn socket_watcher(shared: Arc<Mutex<Shared>>) {
    let divert = match open_windivert_with_retry("SOCKET", || {
        WinDivert::socket("true", 0, WinDivertFlags::new().set_sniff().set_recv_only())
    }) {
        Some(d) => d,
        None => {
            hlog(
                "SEVERE",
                "SOCKET layer open failed after exhausting retries, helper exiting (needs admin + dll/sys alongside)",
            );
            std::thread::sleep(std::time::Duration::from_millis(250)); // 讓錯誤送達 relay 再退出
            std::process::exit(1);
        }
    };
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

// ── NETWORK 層：正向重導向 / UDP drop / 反向改寫 ───────────────────────────

/// 攔截：KRWebView UDP 443 drop、TCP 443 重導向到 shim（loopback）、shim 回程改回真實 server。
fn network_loop(shared: Arc<Mutex<Shared>>) {
    let filter = format!(
        "outbound and ((ip and ((tcp and tcp.DstPort == {TARGET_PORT}) or (tcp and tcp.SrcPort == {SHIM_PORT}) or (udp and udp.DstPort == {TARGET_PORT}))) or (ipv6 and ((tcp and tcp.DstPort == {TARGET_PORT}) or (udp and udp.DstPort == {TARGET_PORT}))))"
    );
    let divert = match open_windivert_with_retry("NETWORK", || {
        WinDivert::network(&filter, 0, WinDivertFlags::new())
    }) {
        Some(d) => d,
        None => {
            hlog("SEVERE", "NETWORK layer open failed after exhausting retries, helper exiting");
            std::thread::sleep(std::time::Duration::from_millis(250)); // 讓錯誤送達 relay 再退出
            std::process::exit(1);
        }
    };

    let mut buf = vec![0u8; 65535];
    let mut sys = System::new();
    loop {
        let mut packet = match divert.recv(Some(&mut buf)) {
            Ok(p) => p,
            Err(_) => continue,
        };

        // IPv6 分支：擋 KRWebView 的 v6 :443 逼退回 v4。TCP 用 RST 讓它「即時失敗」（不是
        // silent drop——後者要等 ~250ms Happy Eyeballs timeout，頁面會很慢）；UDP/QUIC 靜默 drop。
        if packet.data.as_ref().first().map(|b| b >> 4) == Some(6) {
            match v6_drop_decision(packet.data.as_ref(), &shared, &mut sys) {
                Some(6) => send_v6_rst(&divert, &mut packet),
                Some(_) => {} // UDP：靜默 drop
                None => {
                    let _ = divert.send(&packet);
                }
            }
            continue;
        }

        let Some(p) = parse_ipv4(packet.data.as_ref()) else {
            let _ = divert.send(&packet); // 非 IPv4/TCP·UDP 原樣放行
            continue;
        };

        let is_kr_udp = p.proto == 17
            && p.dst_port == TARGET_PORT
            && shared.lock().unwrap().udp_ports.contains(&p.src_port);
        let is_reverse = p.proto == 6 && p.src_port == SHIM_PORT;

        // TCP :443 是否屬 KRWebView：socket_watcher 多半已在 CONNECT 當下把埠記入
        // tcp_ports（→導向）或 not_target_ports（→跳過）；只有罕見 race 才 fallback 查 OS 連線表。
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

        if is_kr_udp {
            continue; // drop（擋 QUIC）：不 send。
        }

        if is_kr_tcp {
            // 記 conntrack（含原始實體網卡 ifidx），供反向腿與 shim 還原。
            let (client_ip, server_ip) = {
                let b = packet.data.as_ref();
                ([b[12], b[13], b[14], b[15]], [b[16], b[17], b[18], b[19]])
            };
            let ifidx = packet.address.interface_index();
            let sub = packet.address.subinterface_index();
            shared
                .lock()
                .unwrap()
                .redirects
                .insert(p.src_port, (server_ip, client_ip, ifidx, sub));
            // 正向：src/dst 都改 127.0.0.1、dst 埠 → SHIM_PORT、**方向維持 outbound**。
            let m = packet.data.to_mut();
            set_ipv4_src(m, LOOPBACK);
            set_ipv4_dst(m, LOOPBACK);
            set_l4_dst_port(m, p.ihl, SHIM_PORT);
            reinject(&divert, &mut packet, "redirect");
            continue;
        }

        if is_reverse {
            let entry = shared.lock().unwrap().redirects.get(&p.dst_port).copied();
            let Some((server_ip, client_ip, ifidx, sub)) = entry else {
                let _ = divert.send(&packet); // 查不到 conntrack：原樣放行
                continue;
            };
            // 反向：src 設回原始 server:443、dst 設回原始 client、方向改 inbound、清 loopback
            // 旗標、ifidx 改回原始實體網卡，讓 app 的 ESTABLISHED socket 認得這個回包。
            let m = packet.data.to_mut();
            set_ipv4_src(m, server_ip);
            set_ipv4_dst(m, client_ip);
            set_l4_src_port(m, p.ihl, TARGET_PORT);
            packet.address.set_outbound(false);
            packet.address.as_mut().set_loopback(false);
            packet.address.set_interface_index(ifidx);
            packet.address.set_subinterface_index(sub);
            reinject(&divert, &mut packet, "reverse");
            continue;
        }

        let _ = divert.send(&packet); // 其餘原樣放行
    }
}

/// 重算 checksum 後送出，失敗印 warning。
fn reinject(
    divert: &WinDivert<NetworkLayer>,
    packet: &mut WinDivertPacket<NetworkLayer>,
    what: &str,
) {
    if let Err(e) = packet.recalculate_checksums(ChecksumFlags::default()) {
        eprintln!("[warn] {what} checksum recalculation failed: {e:?}");
    }
    if let Err(e) = divert.send(packet) {
        eprintln!("[warn] {what} send failed: {e:?}");
    }
}

// ── shim：peek SNI → 只對 convene API MITM，其餘直連原始 server passthrough ──────

/// 監聽 127.0.0.1:SHIM_PORT。每條連線先 peek ClientHello 的 SNI：
/// SNI == convene API host → 對本機 MITM 發 `CONNECT` 走 MITM；
/// 其餘（含無 SNI / 非 TLS）→ 直連原始 server passthrough（不解密，避免拖慢）。
fn shim_listener(shared: Arc<Mutex<Shared>>, mitm_port: u16) {
    let listener = match TcpListener::bind(("127.0.0.1", SHIM_PORT)) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("[error] shim listen on 127.0.0.1:{SHIM_PORT} failed: {e:?}");
            std::process::exit(1);
        }
    };
    for conn in listener.incoming() {
        let mut client = match conn {
            Ok(c) => c,
            Err(e) => {
                eprintln!("[shim] accept failed: {e:?}");
                continue;
            }
        };
        let cport = match client.peer_addr() {
            Ok(p) => p.port(),
            Err(e) => {
                eprintln!("[shim] peer_addr failed: {e:?} (socket may already be RST)");
                continue;
            }
        };
        let shared = shared.clone();
        thread::spawn(move || {
            // peek ClientHello SNI（已讀走的位元組存 head，後續補送上游）。
            let mut head = Vec::new();
            let sni = peek_sni(&mut client, &mut head);
            if sni.as_deref() == Some(TARGET_API_HOST) {
                let host = sni.unwrap();
                hlog("INFO", &format!("shim cport={cport} sni={host} -> mitm"));
                match connect_via_mitm(&host, &head, mitm_port) {
                    Ok(up) => {
                        let _ = splice(client, up);
                    }
                    Err(e) => eprintln!("[shim] {cport} ({host}) CONNECT to MITM failed: {e}"),
                }
            } else {
                hlog("INFO", &format!("shim cport={cport} sni=(other) -> passthrough"));
                // 其餘一律直連原始 server passthrough（conntrack 查 IP，head 先補送）。
                let server_ip = shared
                    .lock()
                    .unwrap()
                    .redirects
                    .get(&cport)
                    .map(|(s, ..)| *s);
                let Some(sip) = server_ip else {
                    eprintln!("[shim] {cport} no conntrack entry, giving up");
                    return;
                };
                let server = (Ipv4Addr::from(sip), TARGET_PORT);
                match TcpStream::connect(server) {
                    Ok(mut up) => {
                        let _ = up.write_all(&head);
                        let _ = splice(client, up);
                    }
                    Err(e) => eprintln!(
                        "[shim] {cport} passthrough to {}:{} failed: {e:?}",
                        server.0, server.1
                    ),
                }
            }
        });
    }
}

/// 從 client 讀取直到能解析出 ClientHello 的 SNI；非 TLS（首位元組非 0x16）即放棄。
/// 已讀走的位元組全存入 `head` 供後續補送上游（不可遺失）。
fn peek_sni(client: &mut TcpStream, head: &mut Vec<u8>) -> Option<String> {
    let mut buf = [0u8; 4096];
    for _ in 0..4 {
        let n = client.read(&mut buf).ok()?;
        if n == 0 {
            return None;
        }
        head.extend_from_slice(&buf[..n]);
        if head[0] != 0x16 {
            return None; // 非 TLS handshake record
        }
        if let Some(sni) = parse_client_hello_sni(head) {
            return Some(sni);
        }
    }
    None
}

/// 連到本機 MITM 發 `CONNECT <host>:443`、收完回應 headers 後補送 peek 走的 ClientHello。
fn connect_via_mitm(host: &str, head: &[u8], mitm_port: u16) -> std::io::Result<TcpStream> {
    let mut up = TcpStream::connect(("127.0.0.1", mitm_port))?;
    let req =
        format!("CONNECT {host}:{TARGET_PORT} HTTP/1.1\r\nHost: {host}:{TARGET_PORT}\r\n\r\n");
    up.write_all(req.as_bytes())?;
    read_until_headers_end(&mut up)?;
    up.write_all(head)?;
    Ok(up)
}

/// 讀取直到遇到 `\r\n\r\n`（HTTP headers 結尾）；用於吞掉 MITM 對 CONNECT 的 200 回應。
fn read_until_headers_end(s: &mut TcpStream) -> std::io::Result<()> {
    let mut one = [0u8; 1];
    let mut acc = Vec::new();
    loop {
        if s.read(&mut one)? == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "CONNECT response truncated",
            ));
        }
        acc.push(one[0]);
        if acc.ends_with(b"\r\n\r\n") {
            return Ok(());
        }
        if acc.len() > 16384 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "CONNECT response too long",
            ));
        }
    }
}

/// 從 TLS ClientHello（單一封包內）解析 SNI 主機名；非 ClientHello / 解析失敗回 None。
fn parse_client_hello_sni(b: &[u8]) -> Option<String> {
    if b.len() < 6 || b[0] != 0x16 || b[5] != 0x01 {
        return None;
    }
    let mut p = 9usize; // record(5) + handshake type(1) + handshake len(3)
    p += 2; // client_version
    p += 32; // random
    let sid_len = *b.get(p)? as usize;
    p += 1 + sid_len;
    let cs_len = ((*b.get(p)? as usize) << 8) | (*b.get(p + 1)? as usize);
    p += 2 + cs_len;
    let comp_len = *b.get(p)? as usize;
    p += 1 + comp_len;
    p += 2; // extensions length
    while p + 4 <= b.len() {
        let ext_type = ((b[p] as usize) << 8) | (b[p + 1] as usize);
        let ext_len = ((b[p + 2] as usize) << 8) | (b[p + 3] as usize);
        let ext_data_start = p + 4;
        let ext_data_end = ext_data_start + ext_len;
        if ext_data_end > b.len() {
            return None;
        }
        if ext_type == 0x0000 {
            let d = &b[ext_data_start..ext_data_end];
            if d.len() < 5 || d[2] != 0x00 {
                return None;
            }
            let name_len = ((d[3] as usize) << 8) | (d[4] as usize);
            let name = d.get(5..5 + name_len)?;
            return String::from_utf8(name.to_vec()).ok();
        }
        p = ext_data_end;
    }
    None
}

/// 雙向轉送兩個 TcpStream，回傳 (client→upstream, upstream→client) 位元組數。
fn splice(a: TcpStream, b: TcpStream) -> (u64, u64) {
    let (Ok(a2), Ok(b2)) = (a.try_clone(), b.try_clone()) else {
        return (0, 0);
    };
    let t = thread::spawn(move || std::io::copy(&mut { a }, &mut { b }).unwrap_or(0));
    let up_to_client = std::io::copy(&mut { b2 }, &mut { a2 }).unwrap_or(0);
    let client_to_up = t.join().unwrap_or(0);
    (client_to_up, up_to_client)
}

// ── 解析 / 改寫工具 ─────────────────────────────────────────────────────────

/// IPv4 + TCP/UDP 標頭關鍵欄位。
struct Ipv4Info {
    ihl: usize,
    proto: u8,
    src_port: u16,
    dst_port: u16,
}

/// 解析 IPv4 + TCP/UDP；非 IPv4/非 TCP·UDP 回 None。
fn parse_ipv4(p: &[u8]) -> Option<Ipv4Info> {
    if p.len() < 20 || (p[0] >> 4) != 4 {
        return None;
    }
    let proto = p[9];
    if proto != 6 && proto != 17 {
        return None;
    }
    let ihl = ((p[0] & 0x0f) as usize) * 4;
    if p.len() < ihl + 4 {
        return None;
    }
    Some(Ipv4Info {
        ihl,
        proto,
        src_port: ((p[ihl] as u16) << 8) | p[ihl + 1] as u16,
        dst_port: ((p[ihl + 2] as u16) << 8) | p[ihl + 3] as u16,
    })
}

/// 是否為純 SYN（SYN 設、ACK 未設）＝連線初始封包。
fn is_syn_only(p: &[u8], ihl: usize) -> bool {
    if p.len() < ihl + 14 || p[9] != 6 {
        return false;
    }
    let f = p[ihl + 13];
    (f & 0x02) != 0 && (f & 0x10) == 0
}

/// 查 TCP 本機埠是否屬於目標行程（KRWebView）。socket_watcher 競態 fallback 用（罕見）。
/// raw `GetExtendedTcpTable` 掃描，找到即返回。
fn tcp_port_is_target(port: u16, v6: bool, sys: &mut System) -> bool {
    find_tcp_pid(port, v6)
        .map(|pid| proc_name(pid, sys).eq_ignore_ascii_case(TARGET_PROCESS))
        .unwrap_or(false)
}

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

/// 掃 TCP（v4/v6）連線表找指定本機埠的擁有者 PID。raw `GetExtendedTcpTable`，零配置線性掃描。
fn find_tcp_pid(port: u16, v6: bool) -> Option<u32> {
    use windows::Win32::NetworkManagement::IpHelper::{
        GetExtendedTcpTable, MIB_TCP6TABLE_OWNER_PID, MIB_TCPTABLE_OWNER_PID,
        TCP_TABLE_OWNER_PID_ALL,
    };
    const AF_INET: u32 = 2;
    const AF_INET6: u32 = 23;
    let af = if v6 { AF_INET6 } else { AF_INET };
    unsafe {
        let mut size: u32 = 0;
        // 第一次傳 null 探詢所需大小（回 ERROR_INSUFFICIENT_BUFFER 並填 size）。
        let _ = GetExtendedTcpTable(None, &mut size, false, af, TCP_TABLE_OWNER_PID_ALL, 0);
        if size == 0 {
            return None;
        }
        let mut buf = vec![0u8; size as usize];
        let r = GetExtendedTcpTable(
            Some(buf.as_mut_ptr() as *mut core::ffi::c_void),
            &mut size,
            false,
            af,
            TCP_TABLE_OWNER_PID_ALL,
            0,
        );
        if r != 0 {
            return None; // 非 NO_ERROR
        }
        if v6 {
            let table = &*(buf.as_ptr() as *const MIB_TCP6TABLE_OWNER_PID);
            let rows =
                std::slice::from_raw_parts(table.table.as_ptr(), table.dwNumEntries as usize);
            rows.iter()
                .find(|row| be16(row.dwLocalPort) == port)
                .map(|row| row.dwOwningPid)
        } else {
            let table = &*(buf.as_ptr() as *const MIB_TCPTABLE_OWNER_PID);
            let rows =
                std::slice::from_raw_parts(table.table.as_ptr(), table.dwNumEntries as usize);
            rows.iter()
                .find(|row| be16(row.dwLocalPort) == port)
                .map(|row| row.dwOwningPid)
        }
    }
}

/// MIB 的 dwLocalPort 把 port 以 network byte order 存在低 word，轉回主機序 u16。
fn be16(dw: u32) -> u16 {
    (((dw & 0xff) << 8) | ((dw >> 8) & 0xff)) as u16
}

/// IPv6 出站 :443 是否要擋（KRWebView 的，逼退回 v4）。回傳要擋的 proto（6=TCP→RST、
/// 17=UDP→靜默 drop），不擋回 None。已知埠直接擋；未知 TCP 埠且是 SYN 時查 PID 判斷並記錄；
/// UDP 沿用 socket_watcher 的 udp_ports（QUIC，容忍競態）。
fn v6_drop_decision(p: &[u8], shared: &Arc<Mutex<Shared>>, sys: &mut System) -> Option<u8> {
    let (proto, src_port, dst_port) = parse_ipv6(p)?;
    if dst_port != TARGET_PORT {
        return None;
    }
    {
        let g = shared.lock().unwrap();
        if g.v6_drop_ports.contains(&src_port) {
            return Some(proto);
        }
        if proto == 17 && g.udp_ports.contains(&src_port) {
            return Some(17);
        }
        if g.not_target_ports.contains(&src_port) {
            return None; // socket_watcher 已判定非 KRWebView，跳過查表
        }
    }
    if proto == 6 && is_syn_only_v6(p) && tcp_port_is_target(src_port, true, sys) {
        shared.lock().unwrap().v6_drop_ports.insert(src_port);
        return Some(6);
    }
    None
}

/// 把攔到的 v6 TCP SYN 原地改寫成 inbound 的 `RST|ACK` 回送給 client，使其 v6 連線即時失敗
/// （Happy Eyeballs 立刻轉 v4，不等 timeout）。SYN-SENT 狀態下，ack==seq+1 的 RST 即可中止。
fn send_v6_rst(divert: &WinDivert<NetworkLayer>, packet: &mut WinDivertPacket<NetworkLayer>) {
    {
        let v = packet.data.to_mut();
        if v.len() < 60 {
            return; // 不足 40(v6)+20(tcp)
        }
        let seq = u32::from_be_bytes([v[44], v[45], v[46], v[47]]);
        let ack = seq.wrapping_add(1);
        // 對調 IPv6 src/dst（8..24 ↔ 24..40），讓 RST 看似來自 server。
        let mut src = [0u8; 16];
        let mut dst = [0u8; 16];
        src.copy_from_slice(&v[8..24]);
        dst.copy_from_slice(&v[24..40]);
        v[8..24].copy_from_slice(&dst);
        v[24..40].copy_from_slice(&src);
        // 對調 TCP src/dst port（40..42 ↔ 42..44）。
        v.swap(40, 42);
        v.swap(41, 43);
        v[44..48].copy_from_slice(&[0, 0, 0, 0]); // seq = 0
        v[48..52].copy_from_slice(&ack.to_be_bytes()); // ack = seq+1
        v[52] = 5 << 4; // data offset 5（20 bytes）、reserved 0
        v[53] = 0x14; // flags = RST|ACK
        v[54] = 0; // window = 0
        v[55] = 0;
        v[56..60].copy_from_slice(&[0, 0, 0, 0]); // checksum + urgent（checksum 由 recalc 填）
        v.truncate(60); // 去掉 SYN 的 TCP options
        v[4] = 0; // IPv6 payload length = 20
        v[5] = 20;
    }
    packet.address.set_outbound(false); // inbound 注入給 client
    packet.address.as_mut().set_loopback(false);
    if let Err(e) = packet.recalculate_checksums(ChecksumFlags::default()) {
        eprintln!("[warn] v6 RST checksum recalculation failed: {e:?}");
    }
    let _ = divert.send(packet);
}

/// 解析 IPv6 base header + TCP/UDP，回 (next_header_proto, src_port, dst_port)。
/// 不處理 IPv6 extension header（next header 非 TCP/UDP 即回 None → 放行）。
fn parse_ipv6(p: &[u8]) -> Option<(u8, u16, u16)> {
    if p.len() < 44 || (p[0] >> 4) != 6 {
        return None;
    }
    let proto = p[6]; // next header
    if proto != 6 && proto != 17 {
        return None;
    }
    let src_port = ((p[40] as u16) << 8) | p[41] as u16;
    let dst_port = ((p[42] as u16) << 8) | p[43] as u16;
    Some((proto, src_port, dst_port))
}

/// IPv6 TCP 是否為純 SYN（base header 40 bytes，flags 在 offset 53）。
fn is_syn_only_v6(p: &[u8]) -> bool {
    if p.len() < 54 || p[6] != 6 {
        return false;
    }
    let f = p[53];
    (f & 0x02) != 0 && (f & 0x10) == 0
}

/// 改寫 IPv4 目的位址。
fn set_ipv4_dst(p: &mut [u8], ip: [u8; 4]) {
    p[16..20].copy_from_slice(&ip);
}

/// 改寫 IPv4 來源位址。
fn set_ipv4_src(p: &mut [u8], ip: [u8; 4]) {
    p[12..16].copy_from_slice(&ip);
}

/// 改寫 L4（TCP/UDP）目的埠。
fn set_l4_dst_port(p: &mut [u8], ihl: usize, port: u16) {
    p[ihl + 2] = (port >> 8) as u8;
    p[ihl + 3] = (port & 0xff) as u8;
}

/// 改寫 L4（TCP/UDP）來源埠。
fn set_l4_src_port(p: &mut [u8], ihl: usize, port: u16) {
    p[ihl] = (port >> 8) as u8;
    p[ihl + 1] = (port & 0xff) as u8;
}

/// 由 PID 查行程 exe 名（查不到回空字串）。
fn proc_name(pid: u32, sys: &mut System) -> String {
    let spid = Pid::from_u32(pid);
    sys.refresh_processes_specifics(
        sysinfo::ProcessesToUpdate::Some(&[spid]),
        true,
        sysinfo::ProcessRefreshKind::nothing(),
    );
    sys.process(spid)
        .map(|p| p.name().to_string_lossy().into_owned())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
