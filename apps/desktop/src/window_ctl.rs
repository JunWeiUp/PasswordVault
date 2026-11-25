//! Closing saves drafts before exiting the UI; the headless owner stays alive.
//! AppKit quit requests are deferred until the same save barrier completes.

use nsh_core::prelude::*;

/// The main window: hide instead of close, and its visibility.
#[module]
pub struct WindowCtl;

#[module]
impl WindowCtl {
    /// Routes the window's close button to hiding the window (once per launch).
    pub fn install() {
        imp::install();
    }
    /// Keeps every app window out of screenshots, screen recording and screen sharing
    /// (macOS `NSWindowSharingNone`). Windows reports false until it is verified there.
    pub fn set_capture_protection(on: bool) -> bool {
        #[cfg(target_os = "macos")]
        {
            imp::set_capture_protection(on);
            true
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = on;
            false
        }
    }
    /// Hides the main window (⌘W).
    pub fn hide() {
        #[cfg(target_os = "macos")]
        imp::on_main(|window| window.orderOut(None));
    }
    /// Shows the main window and brings the app forward.
    pub fn show() {
        #[cfg(target_os = "macos")]
        imp::on_main(|window| {
            if let Some(mtm) = objc2::MainThreadMarker::new() {
                #[allow(deprecated)]
                objc2_app_kit::NSApplication::sharedApplication(mtm)
                    .activateIgnoringOtherApps(true);
            }
            window.makeKeyAndOrderFront(None);
            imp::refresh_capture_protection();
        });
    }
    /// Called only after the interface confirms all drafts were saved.
    pub fn quit_requested() -> bool {
        #[cfg(target_os = "macos")]
        {
            return imp::QUIT_REQUESTED.swap(false, std::sync::atomic::Ordering::SeqCst);
        }
        #[cfg(not(target_os = "macos"))]
        false
    }
    /// Exits only the interface after its drafts have been saved.
    pub fn finish_close() {
        crate::asset_sessions::cleanup_all();
        #[cfg(target_os = "macos")]
        imp::on_main(|_| {
            imp::ALLOW_TERMINATION.store(true, std::sync::atomic::Ordering::SeqCst);
            if let Some(mtm) = objc2::MainThreadMarker::new() {
                objc2_app_kit::NSApplication::sharedApplication(mtm).terminate(None);
            }
        });
    }
    /// Full quit: lock and stop the headless owner before terminating the UI.
    pub async fn quit() -> Result<(), String> {
        #[cfg(target_os = "macos")]
        {
            let directory = crate::vault_directory();
            crate::service_ipc::begin_shutdown(&directory)?;
            let result = blocking(move || {
                crate::service_ipc::control(&directory, "shutdown", serde_json::json!({}))
            })
            .await;
            if !matches!(&result, Ok(Ok(_))) {
                crate::service_ipc::cancel_shutdown(&crate::vault_directory());
                return Err("Storage".into());
            }
        }
        Self::finish_close();
        Ok(())
    }
    /// Whether the main window is currently shown (also true while minimized).
    pub fn visible() -> bool {
        imp::VISIBLE.load(std::sync::atomic::Ordering::SeqCst)
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2::{MainThreadMarker, rc::Retained, sel};
    use objc2_app_kit::{NSApplication, NSWindow, NSWindowButton};
    use objc2_foundation::NSOperationQueue;
    use std::sync::Once;
    use std::sync::atomic::{AtomicBool, Ordering};

    pub static VISIBLE: AtomicBool = AtomicBool::new(true);
    static INSTALL: Once = Once::new();
    pub static QUIT_REQUESTED: AtomicBool = AtomicBool::new(false);
    pub static ALLOW_TERMINATION: AtomicBool = AtomicBool::new(false);
    static ORIGINAL_TERMINATE: std::sync::atomic::AtomicPtr<std::ffi::c_void> =
        std::sync::atomic::AtomicPtr::new(std::ptr::null_mut());
    unsafe extern "C" {
        fn class_getInstanceMethod(
            class: *const std::ffi::c_void,
            selector: objc2::runtime::Sel,
        ) -> *mut std::ffi::c_void;
        fn method_setImplementation(
            method: *mut std::ffi::c_void,
            implementation: *mut std::ffi::c_void,
        ) -> *mut std::ffi::c_void;
    }
    unsafe extern "C" fn defer_terminate(
        app: *mut objc2::runtime::AnyObject,
        selector: objc2::runtime::Sel,
        sender: *mut objc2::runtime::AnyObject,
    ) {
        if ALLOW_TERMINATION.load(Ordering::SeqCst) {
            let original = ORIGINAL_TERMINATE.load(Ordering::SeqCst);
            if !original.is_null() {
                let call: unsafe extern "C" fn(
                    *mut objc2::runtime::AnyObject,
                    objc2::runtime::Sel,
                    *mut objc2::runtime::AnyObject,
                ) = unsafe { std::mem::transmute(original) };
                unsafe { call(app, selector, sender) };
            }
        } else {
            QUIT_REQUESTED.store(true, Ordering::SeqCst);
        }
    }

    static MAIN_WINDOW: std::sync::atomic::AtomicPtr<NSWindow> =
        std::sync::atomic::AtomicPtr::new(std::ptr::null_mut());
    static CLOSE_WIRED: AtomicBool = AtomicBool::new(false);
    fn wire_close_button(window: &NSWindow) {
        if CLOSE_WIRED
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return;
        }
        if let Some(button) = window.standardWindowButton(NSWindowButton::CloseButton) {
            // SAFETY: NSWindow responds to orderOut:; the button keeps a weak target.
            unsafe {
                button.setTarget(Some(window));
                button.setAction(Some(sel!(orderOut:)));
            }
        }
    }
    fn main_window(mtm: MainThreadMarker) -> Option<Retained<NSWindow>> {
        // A hidden window may no longer be eligible to become the main window.
        // Keep this application's original window alive for visibility polling,
        // but only latch onto it once it has actually been shown on screen so
        // pre-display/hidden windows during NSH startup never trigger close.
        let stored = MAIN_WINDOW.load(Ordering::SeqCst);
        if !stored.is_null() {
            return unsafe { Retained::retain(stored) };
        }
        let app = NSApplication::sharedApplication(mtm);
        let window = app
            .windows()
            .iter()
            .find(|w| w.canBecomeMainWindow() && (w.isVisible() || w.isMiniaturized()))?;
        MAIN_WINDOW.store(Retained::into_raw(window.clone()), Ordering::SeqCst);
        wire_close_button(&window);
        Some(window)
    }

    pub fn on_main(f: impl Fn(&NSWindow) + 'static) {
        let block = block2::RcBlock::new(move || {
            let Some(mtm) = MainThreadMarker::new() else {
                return;
            };
            if let Some(window) = main_window(mtm) {
                f(&window);
            }
        });
        // SAFETY: the block touches AppKit only after checking it runs on the main thread.
        unsafe { NSOperationQueue::mainQueue().addOperationWithBlock(&block) };
    }

    static CAPTURE_PROTECTED: AtomicBool = AtomicBool::new(false);

    /// Applies the sharing type to every window now; windows opened later get it from
    /// `refresh_capture_protection`, which `show` calls.
    pub fn set_capture_protection(on: bool) {
        CAPTURE_PROTECTED.store(on, Ordering::SeqCst);
        refresh_capture_protection();
    }

    pub fn refresh_capture_protection() {
        let block = block2::RcBlock::new(|| {
            let Some(mtm) = MainThreadMarker::new() else {
                return;
            };
            let sharing = if CAPTURE_PROTECTED.load(Ordering::SeqCst) {
                objc2_app_kit::NSWindowSharingType::None
            } else {
                objc2_app_kit::NSWindowSharingType::ReadOnly
            };
            for window in NSApplication::sharedApplication(mtm).windows().iter() {
                window.setSharingType(sharing);
            }
        });
        // SAFETY: the block touches AppKit only after checking it runs on the main thread.
        unsafe { NSOperationQueue::mainQueue().addOperationWithBlock(&block) };
    }

    pub fn install() {
        // Test hosts keep the runner's default close behavior.
        if std::env::var_os("PV_DISABLE_HOTKEY").is_some() {
            return;
        }
        INSTALL.call_once(|| {
            // Interpose only this process's AppKit quit entry point. The original
            // implementation runs after the native/UI save barrier acknowledges.
            unsafe {
                let method = class_getInstanceMethod(
                    objc2::class!(NSApplication) as *const _ as *const std::ffi::c_void,
                    sel!(terminate:),
                );
                if !method.is_null() {
                    ORIGINAL_TERMINATE.store(
                        method_setImplementation(method, defer_terminate as *mut std::ffi::c_void),
                        Ordering::SeqCst,
                    );
                }
            }

            // Route the red close button to `orderOut:` once the main window is shown.
            on_main(|window| wire_close_button(window));
            // Track visibility for the interface (Dock reopen shows the window again).
            std::thread::spawn(|| {
                loop {
                    std::thread::sleep(std::time::Duration::from_millis(400));
                    on_main(|window| {
                        VISIBLE.store(
                            window.isVisible() || window.isMiniaturized(),
                            Ordering::SeqCst,
                        )
                    });
                }
            });
        });
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    pub static VISIBLE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);
    pub fn install() {}
}
