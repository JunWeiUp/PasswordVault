//! Unified cross-platform `Browser` NSH module contract.
//!
//! Keeping one `#[module]` definition shared by macOS and Windows prevents
//! platform stub drift (such as missing methods breaking Windows TS builds).

use crate::Vault;
use nsh_core::prelude::*;

/// Browser registration, pairing confirmation and background-grant revocation.
#[module]
pub struct Browser;

#[module]
impl Browser {
    /// Attach once after Vault has opened its session. No registrations are changed.
    pub async fn start(vault: Instance<Vault>) -> Result<(), String> {
        #[cfg(target_os = "macos")]
        {
            crate::browser::Browser::start(vault).await
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = vault;
            Err("Unsupported".into())
        }
    }

    /// Must run before every explicit or system lock to invalidate startup replies.
    pub async fn cancel_startup() {
        #[cfg(target_os = "macos")]
        crate::browser::Browser::cancel_startup().await;
    }

    /// `{"pending": <pending() text>, "revision": n}`; the revision changes after
    /// each extension save so the UI can merge new accounts. Never vault material.
    pub async fn poll() -> String {
        #[cfg(target_os = "macos")]
        {
            crate::browser::Browser::poll().await
        }
        #[cfg(not(target_os = "macos"))]
        {
            String::new()
        }
    }

    /// Returns public extension identity and a per-request approval challenge, never vault material.
    pub async fn pending() -> String {
        #[cfg(target_os = "macos")]
        {
            crate::browser::Browser::pending().await
        }
        #[cfg(not(target_os = "macos"))]
        {
            String::new()
        }
    }

    /// Native settings approval; times out without user consent.
    pub async fn approve(challenge: String, allow: bool) {
        #[cfg(target_os = "macos")]
        crate::browser::Browser::approve(challenge, allow).await;
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (challenge, allow);
        }
    }

    /// Passkey prompt answer: `{"itemId","credentialId","library","currentPassword"}`.
    /// The bridge accepts only a credential it showed for the current challenge.
    pub async fn approve_passkey(challenge: String, selection: String) {
        #[cfg(target_os = "macos")]
        crate::browser::Browser::approve_passkey(challenge, selection).await;
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (challenge, selection);
        }
    }

    /// Registration statuses for the four supported browser families.
    pub fn registrations() -> Result<String, String> {
        #[cfg(target_os = "macos")]
        {
            crate::browser::Browser::registrations()
        }
        #[cfg(not(target_os = "macos"))]
        {
            Err("Unsupported".into())
        }
    }

    /// Explicit user action only. Unregister refuses another app's registration.
    pub fn register(browser: String, install: bool) -> Result<(), String> {
        #[cfg(target_os = "macos")]
        {
            crate::browser::Browser::register(browser, install)
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (browser, install);
            Err("Unsupported".into())
        }
    }

    /// Startup policy is a non-secret marker; enabling does not create a grant.
    pub fn startup_enabled(vault: Instance<Vault>) -> bool {
        #[cfg(target_os = "macos")]
        {
            crate::browser::Browser::startup_enabled(vault)
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = vault;
            false
        }
    }

    /// Explicit desktop preference; disabling cancels any in-flight startup unlock.
    pub async fn set_startup_enabled(vault: Instance<Vault>, enabled: bool) -> Result<(), String> {
        #[cfg(target_os = "macos")]
        {
            crate::browser::Browser::set_startup_enabled(vault, enabled).await
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (vault, enabled);
            Err("Unsupported".into())
        }
    }

    /// Revoke one extension or all pairings and invalidate every background scope.
    pub async fn revoke(vault: Instance<Vault>, extension_id: String) -> Result<(), String> {
        #[cfg(target_os = "macos")]
        {
            crate::browser::Browser::revoke(vault, extension_id).await
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (vault, extension_id);
            Err("Unsupported".into())
        }
    }
}
