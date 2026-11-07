//! Browser transport is disabled until authenticated Windows IPC is implemented.
use nsh_core::prelude::*;
use crate::Vault;
/// Unavailable Windows browser transport; no registration or authorization is performed.
#[module]
pub struct Browser;
#[module]
impl Browser {
    /// Windows transport is not enabled in this preview.
    pub fn start(_vault: Instance<Vault>) -> Result<(), String> { Err("Unsupported".into()) }
    /// Windows transport is not enabled in this preview.
    pub fn cancel_startup() {}
    /// Windows transport is not enabled in this preview.
    pub fn pending() -> String { String::new() }
    /// Windows transport is not enabled in this preview.
    pub fn approve(_challenge: String, _allow: bool) {}
    /// Windows transport is not enabled in this preview.
    pub fn registrations() -> Result<String, String> { Err("Unsupported".into()) }
    /// Windows transport is not enabled in this preview.
    pub fn register(_browser: String, _install: bool) -> Result<(), String> { Err("Unsupported".into()) }
    /// Windows transport is not enabled in this preview.
    pub fn startup_enabled(_vault: Instance<Vault>) -> bool { false }
    /// Windows transport is not enabled in this preview.
    pub fn set_startup_enabled(_vault: Instance<Vault>, _enabled: bool) -> Result<(), String> { Err("Unsupported".into()) }
    /// Windows transport is not enabled in this preview.
    pub async fn revoke(_vault: Instance<Vault>, _extension_id: String) -> Result<(), String> { Err("Unsupported".into()) }
}
