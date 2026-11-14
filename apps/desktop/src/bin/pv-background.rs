#![cfg_attr(not(target_os = "macos"), allow(dead_code))]
#[cfg(target_os = "macos")]
#[path = "../browser/mod.rs"]
mod browser;
#[cfg(target_os = "macos")]
#[path = "../relay/mod.rs"]
mod relay;
#[cfg(target_os = "macos")]
#[path = "../macos/services.rs"]
mod signals;
#[cfg(target_os = "macos")]
mod platform {
    pub use crate::signals::*;
    pub use vault_core::native_file_ops::replace_synced;
}
#[cfg(target_os = "macos")]
#[path = "../background.rs"]
mod background;
#[cfg(target_os = "macos")]
#[path = "../hotkey.rs"]
mod hotkey;
#[cfg(target_os = "macos")]
#[path = "../service_ipc.rs"]
mod service_ipc;
#[cfg(target_os = "macos")]
#[path = "../session.rs"]
mod session;
#[cfg(target_os = "macos")]
fn error_code(error: vault_core::VaultError) -> String {
    format!("{error:?}")
}
#[cfg(target_os = "macos")]
fn main() {
    if background::run().is_err() {
        std::process::exit(1);
    }
}
#[cfg(not(target_os = "macos"))]
fn main() {
    std::process::exit(2);
}
