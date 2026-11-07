//! Global Quick Access shortcut (Carbon `RegisterEventHotKey`), matching the
//! SwiftUI app's choices: "command-shift-space" (default), "command-option-p",
//! "disabled". The handler only raises a flag and activates the app; TSX polls
//! `Hotkey.poll()` and opens Quick Access when the vault is unlocked.
//! Disabled under tests (`PV_DISABLE_HOTKEY`) so test hosts never take the
//! installed application's shortcut.

use nsh_core::prelude::*;

/// The global Quick Access shortcut.
#[module]
pub struct Hotkey;

#[module]
impl Hotkey {
    /// Registers `choice` ("command-shift-space", "command-option-p" or
    /// "disabled"); resolves false when another app already holds it.
    pub async fn configure(choice: String) -> bool {
        imp::configure(choice).await
    }

    /// Whether the shortcut was pressed since the last call.
    pub fn poll() -> bool {
        imp::PRESSED.swap(false, std::sync::atomic::Ordering::SeqCst)
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use std::ffi::c_void;
    use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};

    pub static PRESSED: AtomicBool = AtomicBool::new(false);
    static HOTKEY: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
    static HANDLER: AtomicBool = AtomicBool::new(false);

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct EventHotKeyID {
        signature: u32,
        id: u32,
    }
    #[repr(C)]
    struct EventTypeSpec {
        event_class: u32,
        event_kind: u32,
    }
    type Handler = extern "C" fn(*mut c_void, *mut c_void, *mut c_void) -> i32;

    #[link(name = "Carbon", kind = "framework")]
    unsafe extern "C" {
        fn GetApplicationEventTarget() -> *mut c_void;
        fn InstallEventHandler(target: *mut c_void, handler: Handler, count: usize, list: *const EventTypeSpec, data: *mut c_void, out: *mut *mut c_void) -> i32;
        fn RegisterEventHotKey(code: u32, modifiers: u32, id: EventHotKeyID, target: *mut c_void, options: u32, out: *mut *mut c_void) -> i32;
        fn UnregisterEventHotKey(hotkey: *mut c_void) -> i32;
        fn GetEventParameter(event: *mut c_void, name: u32, kind: u32, actual: *mut u32, size: usize, actual_size: *mut usize, data: *mut c_void) -> i32;
    }

    const SIGNATURE: u32 = u32::from_be_bytes(*b"PVQA"); // as in the SwiftUI app
    const KEYBOARD: u32 = u32::from_be_bytes(*b"keyb");
    const HOTKEY_PRESSED: u32 = 5;
    const DIRECT_OBJECT: u32 = u32::from_be_bytes(*b"----");
    const HOTKEY_ID: u32 = u32::from_be_bytes(*b"hkid");
    const SPACE: u32 = 49;
    const P: u32 = 35;
    const CMD: u32 = 1 << 8;
    const SHIFT: u32 = 1 << 9;
    const OPTION: u32 = 1 << 11;

    extern "C" fn on_hotkey(_: *mut c_void, event: *mut c_void, _: *mut c_void) -> i32 {
        let mut id = EventHotKeyID { signature: 0, id: 0 };
        // SAFETY: reads the hot key ID of a Carbon keyboard event into a local of its size.
        let status = unsafe {
            GetEventParameter(event, DIRECT_OBJECT, HOTKEY_ID, std::ptr::null_mut(), std::mem::size_of::<EventHotKeyID>(), std::ptr::null_mut(), (&mut id as *mut EventHotKeyID).cast())
        };
        if status != 0 || id.signature != SIGNATURE || id.id != 1 {
            return -9874; // eventNotHandledErr
        }
        PRESSED.store(true, Ordering::SeqCst);
        if let Some(mtm) = objc2::MainThreadMarker::new() {
            #[allow(deprecated)]
            objc2_app_kit::NSApplication::sharedApplication(mtm).activateIgnoringOtherApps(true);
        }
        0
    }

    pub async fn configure(choice: String) -> bool {
        if std::env::var_os("PV_DISABLE_HOTKEY").is_some() {
            return true;
        }
        let (tx, rx) = std::sync::mpsc::channel();
        let block = block2::RcBlock::new(move || {
            let _ = tx.send(register(&choice));
        });
        // SAFETY: Carbon registration runs on the main thread inside the block.
        unsafe { objc2_foundation::NSOperationQueue::mainQueue().addOperationWithBlock(&block) };
        nsh_core::prelude::blocking(move || rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap_or(false))
            .await
            .unwrap_or(false)
    }

    fn register(choice: &str) -> bool {
        // SAFETY: Carbon calls on the main thread with valid pointers to locals/statics.
        unsafe {
            let old = HOTKEY.swap(std::ptr::null_mut(), Ordering::SeqCst);
            if !old.is_null() {
                UnregisterEventHotKey(old);
            }
            if choice == "disabled" {
                return true;
            }
            if !HANDLER.load(Ordering::SeqCst) {
                let spec = EventTypeSpec { event_class: KEYBOARD, event_kind: HOTKEY_PRESSED };
                let mut handler = std::ptr::null_mut();
                if InstallEventHandler(GetApplicationEventTarget(), on_hotkey, 1, &spec, std::ptr::null_mut(), &mut handler) != 0 {
                    return false;
                }
                HANDLER.store(true, Ordering::SeqCst);
            }
            let (code, modifiers) = if choice == "command-option-p" { (P, CMD | OPTION) } else { (SPACE, CMD | SHIFT) };
            let mut hotkey = std::ptr::null_mut();
            let ok = RegisterEventHotKey(code, modifiers, EventHotKeyID { signature: SIGNATURE, id: 1 }, GetApplicationEventTarget(), 0, &mut hotkey) == 0;
            if ok {
                HOTKEY.store(hotkey, Ordering::SeqCst);
            }
            ok
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    pub static PRESSED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    pub async fn configure(_: String) -> bool {
        false
    }
}
