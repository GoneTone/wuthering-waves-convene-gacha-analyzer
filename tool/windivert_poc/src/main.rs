//! WinDivert PoC — QUIC-block 版（決定性測試）。
//!
//! 目的：證實鳴潮 `gmserver-api` 是走 QUIC（HTTP/3, UDP 443）才被我們之前的 TCP-only
//! sniff 漏掉。做法＝**攔截模式**下 **drop 掉所有出站 UDP 443（QUIC）**，把 TCP 443
//! 原樣放行並解析 SNI。QUIC 被擋後，瀏覽器/CEF 會**退回 TCP/TLS**，gmserver 的請求就
//! 會以 TCP 出現 → 我們用 TCP SNI 看到它。這正是 mitmproxy local 模式暗中做的事，也是
//! 正式版的核心機制。
//!
//! ⚠️ 與前一版（sniff、零影響）不同：本版**修改流量**——drop 全機出站 UDP 443，使所有
//! QUIC 暫時退回 TCP（無害，apps 會自動 fallback）。測完按 Ctrl-C 即還原。
//!
//! 跑法：系統管理員執行。到鳴潮開「喚取 → 喚取記錄」頁、切幾個卡池分頁，留意是否出現
//! `✅ HIT ... gmserver-api ...`。

use std::collections::HashSet;
use std::net::Ipv4Addr;

use netstat2::{get_sockets_info, AddressFamilyFlags, ProtocolFlags, ProtocolSocketInfo};
use sysinfo::{Pid, System};
use windivert::prelude::*;

fn main() {
    // 攔截模式（非 sniff）：recv 會把封包從網路堆疊取走，需 send() 重新注入才放行；
    // 不 send 即等於 drop。我們對 UDP 443 不 send（drop → 逼 QUIC 退回 TCP），
    // 對 TCP 443 一律 send（原樣放行）。
    let filter = "outbound and ((tcp and tcp.DstPort == 443) or (udp and udp.DstPort == 443))";
    let flags = WinDivertFlags::new();
    let divert = match WinDivert::network(filter, 0, flags) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("[error] 開啟 WinDivert 失敗：{e:?}");
            eprintln!("        檢查：(1) 以系統管理員執行；(2) WinDivert.dll 與 WinDivert64.sys 在 exe 同目錄。");
            std::process::exit(1);
        }
    };
    println!("WinDivert 已開啟（攔截模式：drop 出站 UDP 443 / QUIC，TCP 443 原樣放行）。");
    println!("⚠️ 全機 QUIC 會暫時退回 TCP（無害）。請到鳴潮開「喚取 → 喚取記錄」頁、切幾個卡池分頁。Ctrl-C 結束還原。\n");

    let mut buf = vec![0u8; 65535];
    let mut seen_sni: HashSet<String> = HashSet::new();
    let mut hit_count: u64 = 0;
    let mut dropped_quic: u64 = 0;
    let mut sys = System::new();
    loop {
        let packet = match divert.recv(Some(&mut buf)) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("[warn] recv 錯誤：{e:?}");
                continue;
            }
        };
        let data: &[u8] = packet.data.as_ref();
        let is_udp = data.len() >= 20 && (data[0] >> 4) == 4 && data[9] == 17;

        if is_udp {
            // DROP（不 send）→ 擋掉 QUIC，逼退回 TCP。每 200 筆印一次計數避免洗版。
            dropped_quic += 1;
            if dropped_quic % 200 == 1 {
                println!("   …已 drop {dropped_quic} 個出站 UDP 443（QUIC）封包，逼其退回 TCP…");
            }
            continue;
        }

        // TCP 443：原樣重新注入放行（務必 send，否則會切斷 TLS 連線）。
        if let Err(e) = divert.send(&packet) {
            eprintln!("[warn] send（reinject TCP）失敗：{e:?}");
        }

        // 放行後再解析 SNI 做記錄（不影響轉發延遲）。
        let Some(payload) = tcp_payload(data) else {
            continue;
        };
        let Some(sni) = parse_client_hello_sni(payload) else {
            continue;
        };
        let dst = ipv4_dst(data)
            .map(|ip| ip.to_string())
            .unwrap_or_else(|| "?".into());
        let lower = sni.to_ascii_lowercase();
        let is_hit = lower.contains("aki-game")
            || lower.contains("gmserver")
            || lower.contains("kurogame")
            || lower.contains("kurogames");
        let proc = tcp_src_port(data)
            .and_then(|port| proc_for_local_port(port, ProtocolFlags::TCP, &mut sys))
            .map(|(pid, name)| format!("{name}({pid})"))
            .unwrap_or_else(|| "?".into());
        if is_hit {
            hit_count += 1;
            println!("✅ HIT #{hit_count}  [TCP] SNI={sni}  dst={dst}  proc={proc}");
        } else if seen_sni.insert(sni.clone()) {
            println!("   [TCP] SNI={sni}  dst={dst}  proc={proc}");
        }
    }
}

/// 取 raw IPv4 封包的目的 IP（僅 IPv4）。
fn ipv4_dst(p: &[u8]) -> Option<Ipv4Addr> {
    if p.len() < 20 || (p[0] >> 4) != 4 {
        return None;
    }
    Some(Ipv4Addr::new(p[16], p[17], p[18], p[19]))
}

/// 取 IPv4 + TCP 封包的 TCP payload 切片（僅 IPv4/TCP）。
fn tcp_payload(p: &[u8]) -> Option<&[u8]> {
    if p.len() < 20 || (p[0] >> 4) != 4 || p[9] != 6 {
        return None;
    }
    let ihl = ((p[0] & 0x0f) as usize) * 4;
    if p.len() < ihl + 20 {
        return None;
    }
    let data_off = ((p[ihl + 12] >> 4) as usize) * 4;
    let start = ihl + data_off;
    if start > p.len() {
        return None;
    }
    Some(&p[start..])
}

/// 取 IPv4+TCP 封包的 TCP 來源埠（反查行程用）。
fn tcp_src_port(p: &[u8]) -> Option<u16> {
    if p.len() < 20 || (p[0] >> 4) != 4 || p[9] != 6 {
        return None;
    }
    let ihl = ((p[0] & 0x0f) as usize) * 4;
    if p.len() < ihl + 2 {
        return None;
    }
    Some(((p[ihl] as u16) << 8) | (p[ihl + 1] as u16))
}

/// 由本機埠反查擁有它的行程（PID + exe 名）；proto 指定 TCP 或 UDP。
fn proc_for_local_port(
    port: u16,
    proto: ProtocolFlags,
    sys: &mut System,
) -> Option<(u32, String)> {
    let sockets = get_sockets_info(AddressFamilyFlags::IPV4, proto).ok()?;
    for si in sockets {
        let (local_port, pids) = match &si.protocol_socket_info {
            ProtocolSocketInfo::Tcp(t) => (t.local_port, &si.associated_pids),
            ProtocolSocketInfo::Udp(u) => (u.local_port, &si.associated_pids),
        };
        if local_port == port {
            let pid = *pids.first()?;
            let spid = Pid::from_u32(pid);
            sys.refresh_processes_specifics(
                sysinfo::ProcessesToUpdate::Some(&[spid]),
                true,
                sysinfo::ProcessRefreshKind::nothing(),
            );
            let name = sys
                .process(spid)
                .map(|p| p.name().to_string_lossy().into_owned())
                .unwrap_or_else(|| "?".into());
            return Some((pid, name));
        }
    }
    None
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
