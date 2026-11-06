//! Closing the window hides it instead of ending the app (Native Shell 0.3.0's
//! packaged runner has no keep-alive option): the close button and ⌘W order the
//! window out; the Dock icon brings the same window back (the runner already
//! handles reopen). The interface polls `Window.visible()` to release and
//! restore its content.

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
    /// Hides the main window (⌘W).
    pub fn hide() {
        imp::on_main(|window| window.orderOut(None));
    }
    /// Shows the main window and brings the app forward.
    pub fn show() {
        imp::on_main(|window| {
            if let Some(mtm) = objc2::MainThreadMarker::new() {
                #[allow(deprecated)]
                objc2_app_kit::NSApplication::sharedApplication(mtm).activateIgnoringOtherApps(true);
            }
            window.makeKeyAndOrderFront(None);
        });
    }
    /// Whether the main window is currently shown (also true while minimized).
    pub fn visible() -> bool {
        imp::VISIBLE.load(std::sync::atomic::Ordering::SeqCst)
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2::{rc::Retained, sel, MainThreadMarker};
    use objc2_app_kit::{NSApplication, NSWindow, NSWindowButton};
    use objc2_foundation::NSOperationQueue;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Once;

    pub static VISIBLE: AtomicBool = AtomicBool::new(true);
    static INSTALL: Once = Once::new();

    fn main_window(mtm: MainThreadMarker) -> Option<Retained<NSWindow>> {
        let app = NSApplication::sharedApplication(mtm);
        let windows = app.windows();
        windows.iter().find(|w| w.canBecomeMainWindow())
    }

    pub fn on_main(f: impl Fn(&NSWindow) + 'static) {
        let block = block2::RcBlock::new(move || {
            let Some(mtm) = MainThreadMarker::new() else { return };
            if let Some(window) = main_window(mtm) {
                f(&window);
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
            // Route the red close button to `orderOut:` on the window itself.
            on_main(|window| {
                if let Some(button) = window.standardWindowButton(NSWindowButton::CloseButton) {
                    // SAFETY: NSWindow responds to orderOut:; the button keeps a weak target.
                    unsafe {
                        button.setTarget(Some(window));
                        button.setAction(Some(sel!(orderOut:)));
                    }
                }
            });
            // Track visibility for the interface (Dock reopen shows the window again).
            std::thread::spawn(|| loop {
                std::thread::sleep(std::time::Duration::from_millis(400));
                on_main(|window| VISIBLE.store(window.isVisible() || window.isMiniaturized(), Ordering::SeqCst));
            });
        });
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    pub static VISIBLE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);
    pub fn install() {}
    pub fn on_main(_: impl Fn(&()) + 'static) {}
}
