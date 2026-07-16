//! 提權的攔截 helper（`capture_helper.exe`）的生命週期管理。
//!
//! 主程式為一般權限、helper 需系統管理員（WinDivert 要 admin），故用 `ShellExecuteExW` "runas"
//! 提權 spawn。停止時主程式**無法**跨權限 `TerminateProcess` 提權的 helper，改用協作式停止：
//! 主程式建一個具名事件、把「事件名 + 自己的 PID」傳給 helper；helper 看門狗等到「事件被設定
//! （停止）或父行程結束（主程式關閉/崩潰）」任一發生即自行 `exit`，WinDivert handle 一關閉、
//! 重導向自動還原。如此「停止擷取」與「孤兒 helper」皆解決。

use anyhow::{anyhow, Context, Result};
use std::path::PathBuf;
use windows::core::{HSTRING, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::System::Threading::{CreateEventW, SetEvent, WaitForSingleObject};
use windows::Win32::UI::Shell::{ShellExecuteExW, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW};
use windows::Win32::UI::WindowsAndMessaging::SW_HIDE;

/// 提權 helper 行程的 RAII guard：drop 時設定停止事件、等 helper 退出（還原重導向）、關 handle。
pub struct HelperHandle {
    process: HANDLE,
    stop_event: HANDLE,
}

// HANDLE 內含裸指標故非自動 Send；本 guard 的 handle 僅在持有它的執行緒/drop 使用，安全。
unsafe impl Send for HelperHandle {}

impl Drop for HelperHandle {
    fn drop(&mut self) {
        unsafe {
            let _ = SetEvent(self.stop_event);
            // 等 helper 收尾退出（WinDivert handle 關閉→重導向還原），最多 3 秒。
            let _ = WaitForSingleObject(self.process, 3000);
            let _ = CloseHandle(self.process);
            let _ = CloseHandle(self.stop_event);
        }
    }
}

/// UAC 提權 spawn `capture_helper.exe`，傳入 hudsucker 監聽埠 + 停止事件名 + 主程式 PID +
/// （第 4 個 argv）log relay 埠，供 helper 連本機 TCP 把分類決策送回 app 轉發進當天主 log 檔。
/// UAC 被取消會回 `Err`。
pub fn spawn(mitm_port: u16, log_port: u16) -> Result<HelperHandle> {
    let exe = helper_exe_path()?;
    let dir = exe
        .parent()
        .ok_or_else(|| anyhow!("helper 路徑無上層目錄"))?
        .to_string_lossy()
        .into_owned();
    let event_name = format!("capture_helper_stop_{}", std::process::id());

    let stop_event = unsafe {
        CreateEventW(None, true, false, &HSTRING::from(&event_name))
            .context("CreateEventW 建立停止事件失敗")?
    };

    let params = format!("{mitm_port} {event_name} {} {log_port}", std::process::id());
    let verb = HSTRING::from("runas");
    let file = HSTRING::from(exe.to_string_lossy().as_ref());
    let parameters = HSTRING::from(params);
    let directory = HSTRING::from(dir.as_str());

    let mut info = SHELLEXECUTEINFOW {
        cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS,
        lpVerb: PCWSTR(verb.as_ptr()),
        lpFile: PCWSTR(file.as_ptr()),
        lpParameters: PCWSTR(parameters.as_ptr()),
        lpDirectory: PCWSTR(directory.as_ptr()),
        nShow: SW_HIDE.0,
        ..Default::default()
    };

    unsafe {
        if let Err(e) = ShellExecuteExW(&mut info) {
            let _ = CloseHandle(stop_event);
            return Err(anyhow!("提權啟動 helper 失敗（UAC 取消？）：{e}"));
        }
    }
    if info.hProcess.is_invalid() {
        unsafe {
            let _ = CloseHandle(stop_event);
        }
        return Err(anyhow!("ShellExecuteExW 未回傳 helper 行程 handle"));
    }

    Ok(HelperHandle {
        process: info.hProcess,
        stop_event,
    })
}

/// helper exe 路徑：與主程式 exe 同目錄（build 時 bundle 進去）。
fn helper_exe_path() -> Result<PathBuf> {
    let exe = std::env::current_exe().context("取得主程式 exe 路徑失敗")?;
    let helper = exe
        .parent()
        .ok_or_else(|| anyhow!("主程式 exe 無上層目錄"))?
        .join("capture_helper.exe");
    if !helper.exists() {
        return Err(anyhow!("找不到 capture_helper.exe：{}", helper.display()));
    }
    Ok(helper)
}
