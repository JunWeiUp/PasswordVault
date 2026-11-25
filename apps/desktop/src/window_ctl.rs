//! Native window capture protection and clean exit helpers.
//!
//! Window close (`closePress`) and quit (`quitRequest`) interception are handled
//! directly by Native Shell 0.7's cross-platform lifecycle APIs in `App.tsx`;
//! this module keeps only OS-level capture protection and macOS background-service
//! shutdown coordination.

use nsh_core::prelude::*;

/// Capture protection and clean shutdown helpers for desktop windows.
#[module]
pub struct WindowCtl;

#[module]
impl WindowCtl {
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

    /// Cleans up temporary decrypted asset sessions before the UI exits while
    /// leaving the macOS background owner running.
    pub fn prepare_exit() {
        crate::asset_sessions::cleanup_all();
    }

    /// Full quit: lock and stop the macOS headless owner, then clean up temporary
    /// asset sessions. The caller invokes `Application.quit()` after this returns.
    pub async fn shutdown_service() -> Result<(), String> {
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
        crate::asset_sessions::cleanup_all();
        Ok(())
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2::MainThreadMarker;
    use objc2_app_kit::NSApplication;
    use objc2_foundation::NSOperationQueue;
    use std::sync::atomic::{AtomicBool, Ordering};

    static CAPTURE_PROTECTED: AtomicBool = AtomicBool::new(false);

    /// Applies the sharing type to every open window.
    pub fn set_capture_protection(on: bool) {
        CAPTURE_PROTECTED.store(on, Ordering::SeqCst);
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
}
