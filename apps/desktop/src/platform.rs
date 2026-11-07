//! Platform services consumed by the shared desktop bridge.
//! Platform-specific key storage must never fall back to plaintext storage.
#[cfg(target_os = "macos")]
#[path = "macos/mod.rs"]
mod macos;
#[cfg(target_os = "macos")]
pub use macos::*;

#[cfg(not(target_os = "macos"))]
mod unsupported {
    use std::path::Path;
    use zeroize::Zeroizing;
    pub fn available() -> bool { false }
    pub fn enabled(_: &Path) -> Result<bool, String> { Ok(false) }
    pub fn verify_enrollment(_: &vault_core::VaultSession, _: &Path, _: String) -> Result<Zeroizing<Vec<u8>>, String> { Err("Unsupported".into()) }
    pub fn enroll(_: &Path, _: &[u8]) -> Result<(), String> { Err("Unsupported".into()) }
    pub fn remove(_: &Path) -> Result<(), String> { Err("Unsupported".into()) }
    pub fn retrieve(_: &Path) -> Result<Zeroizing<Vec<u8>>, String> { Err("Unsupported".into()) }
    // System events require a native implementation before Windows distribution.
    #[cfg(not(target_os = "windows"))]
    pub fn poll() -> String { r#"{"events":0,"idleSeconds":null}"#.into() }
}
#[cfg(not(target_os = "macos"))]
pub use unsupported::*;

/// Reveal a selected file using the platform shell, without a command interpreter.
pub fn reveal(path: &str) -> bool {
    #[cfg(target_os = "macos")]
    { std::process::Command::new("/usr/bin/open").arg("-R").arg(path).status().is_ok_and(|s| s.success()) }
    #[cfg(target_os = "windows")]
    { std::process::Command::new("explorer.exe").arg(format!("/select,{path}")).spawn().is_ok() }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    { let _ = path; false }
}

pub fn open_folder(path: &std::path::Path) -> bool {
    #[cfg(target_os = "macos")]
    { std::process::Command::new("/usr/bin/open").arg(path).status().is_ok_and(|s| s.success()) }
    #[cfg(target_os = "windows")]
    { std::process::Command::new("explorer.exe").arg(path).spawn().is_ok() }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    { let _ = path; false }
}

#[cfg(target_os = "macos")]
#[path = "macos/files.rs"]
mod file_dialogs;
#[cfg(target_os = "macos")]
pub(crate) use file_dialogs::{panel, pick_device_paths};

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub(crate) fn panel(_: String, _: Option<String>, _: Vec<String>) -> Result<Option<String>, String> {
    Err("Unsupported".into())
}
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub(crate) fn pick_device_paths() -> Result<Vec<std::path::PathBuf>, String> {
    Err("Unsupported".into())
}

#[cfg(target_os = "windows")]
#[path = "windows/files.rs"]
mod windows_files;
#[cfg(target_os = "windows")]
pub(crate) use windows_files::{panel, pick_device_paths};

#[path = "platform_files.rs"]
mod safe_files;
pub(crate) use safe_files::{open_regular_readonly, replace_synced};

#[cfg(target_os = "windows")]
#[path = "windows/signals.rs"]
mod windows_signals;
#[cfg(target_os = "windows")]
pub use windows_signals::poll;
