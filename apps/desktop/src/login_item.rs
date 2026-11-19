//! Launch at login. macOS registers the app itself with `SMAppService`; the user can
//! still approve or remove it in System Settings › Login Items. Other platforms report
//! "unsupported" until a native implementation is verified there.

use nsh_core::prelude::*;

/// Launch-at-login registration backed by macOS SMAppService.
#[module]
pub struct LoginItem;

#[module]
impl LoginItem {
    /// "enabled", "requiresApproval", "notRegistered", "notFound" or "unsupported".
    pub fn status() -> String {
        imp::status()
    }
    /// Registers or unregisters the app and returns the resulting status.
    pub fn set(on: bool) -> Result<String, String> {
        imp::set(on)
    }
    /// Opens System Settings › Login Items so the user can approve the app.
    pub fn open_settings() {
        imp::open_settings();
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2_service_management::{SMAppService, SMAppServiceStatus};

    fn name(status: SMAppServiceStatus) -> String {
        match status {
            SMAppServiceStatus::Enabled => "enabled",
            SMAppServiceStatus::RequiresApproval => "requiresApproval",
            SMAppServiceStatus::NotFound => "notFound",
            _ => "notRegistered",
        }
        .to_owned()
    }

    pub fn status() -> String {
        // SAFETY: mainAppService describes this bundle; reading its status has no side effects.
        name(unsafe { SMAppService::mainAppService().status() })
    }

    pub fn set(on: bool) -> Result<String, String> {
        // SAFETY: registering or unregistering only affects this app's own login item.
        let service = unsafe { SMAppService::mainAppService() };
        let result = if on {
            unsafe { service.registerAndReturnError() }
        } else {
            unsafe { service.unregisterAndReturnError() }
        };
        let status = name(unsafe { service.status() });
        match result {
            Ok(()) => Ok(status),
            // Approval pending in System Settings is not a failure.
            Err(_) if on && status == "requiresApproval" => Ok(status),
            Err(_) if !on && status == "notRegistered" => Ok(status),
            Err(error) => Err(error.localizedDescription().to_string()),
        }
    }

    pub fn open_settings() {
        // SAFETY: opens System Settings; no app state is changed.
        unsafe { SMAppService::openSystemSettingsLoginItems() };
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    pub fn status() -> String {
        "unsupported".to_owned()
    }
    pub fn set(_on: bool) -> Result<String, String> {
        Err("unsupported".to_owned())
    }
    pub fn open_settings() {}
}
