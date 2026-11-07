//! Windows session and sleep notifications; no vault access on the event thread.
use std::sync::{Once, atomic::{AtomicU32, Ordering}};
use windows_sys::Win32::{
    Foundation::*,
    System::{LibraryLoader::GetModuleHandleW, RemoteDesktop::*, SystemInformation::GetTickCount},
    UI::{Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO}, WindowsAndMessaging::*},
};
static START: Once = Once::new();
static EVENTS: AtomicU32 = AtomicU32::new(0);

unsafe extern "system" fn window_proc(hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let bit = match (message, wparam as u32) {
        (WM_WTSSESSION_CHANGE, WTS_SESSION_LOCK) => 4,
        (WM_WTSSESSION_CHANGE, WTS_CONSOLE_DISCONNECT | WTS_REMOTE_DISCONNECT) => 2,
        (WM_POWERBROADCAST, PBT_APMSUSPEND) => 1,
        _ => 0,
    };
    EVENTS.fetch_or(bit, Ordering::SeqCst);
    unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
}

fn listen() {
    // This dedicated thread owns its hidden top-level window and message pump.
    // A top-level window also receives power broadcasts; a message-only one does not.
    unsafe {
        let instance = GetModuleHandleW(std::ptr::null());
        let name: Vec<u16> = "PasswordVaultSessionEvents\0".encode_utf16().collect();
        let class = WNDCLASSW { lpfnWndProc: Some(window_proc), hInstance: instance, lpszClassName: name.as_ptr(), ..std::mem::zeroed() };
        if RegisterClassW(&class) == 0 { return; }
        let hwnd = CreateWindowExW(0, name.as_ptr(), name.as_ptr(), 0, 0, 0, 0, 0,
            std::ptr::null_mut(), std::ptr::null_mut(), instance, std::ptr::null());
        if hwnd.is_null() { UnregisterClassW(name.as_ptr(), instance); return; }
        if WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION) == 0 {
            DestroyWindow(hwnd); UnregisterClassW(name.as_ptr(), instance); return;
        }
        let mut message: MSG = std::mem::zeroed();
        while GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        WTSUnRegisterSessionNotification(hwnd);
        DestroyWindow(hwnd);
        UnregisterClassW(name.as_ptr(), instance);
    }
}

pub fn poll() -> String {
    START.call_once(|| { std::thread::spawn(listen); });
    let mut input = LASTINPUTINFO { cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32, dwTime: 0 };
    let idle = unsafe {
        (GetLastInputInfo(&mut input) != 0).then(|| GetTickCount().wrapping_sub(input.dwTime) as f64 / 1000.0)
    };
    serde_json::json!({"events":EVENTS.swap(0, Ordering::SeqCst),"idleSeconds":idle}).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn receives_and_drains_a_session_message_without_locking_windows() {
        let _ = poll();
        let name: Vec<u16> = "PasswordVaultSessionEvents\0".encode_utf16().collect();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let hwnd = loop {
            let hwnd = unsafe { FindWindowW(name.as_ptr(), name.as_ptr()) };
            if !hwnd.is_null() { break hwnd; }
            assert!(std::time::Instant::now() < deadline, "event window did not initialize");
            std::thread::sleep(std::time::Duration::from_millis(20));
        };
        // Only our hidden observer receives this synthetic message. The workstation
        // stays unlocked and no user settings or real vault data are touched.
        assert_ne!(unsafe { PostMessageW(hwnd, WM_WTSSESSION_CHANGE, WTS_SESSION_LOCK as usize, 0) }, 0);
        loop {
            let state: serde_json::Value = serde_json::from_str(&poll()).unwrap();
            if state["events"].as_u64().unwrap() & 4 != 0 { break; }
            assert!(std::time::Instant::now() < deadline, "session event not delivered");
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let drained: serde_json::Value = serde_json::from_str(&poll()).unwrap();
        assert_eq!(drained["events"], 0);
        assert!(drained["idleSeconds"].is_null() || drained["idleSeconds"].as_f64().unwrap() >= 0.0);
    }
}
