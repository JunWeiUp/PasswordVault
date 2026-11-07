//! Relay orchestration, encrypted credentials, presence and authorized replication.
#![allow(dead_code)]
mod access;
mod admission;
mod files;
#[cfg(test)]
mod group_tests;
mod groups;
mod journal;
mod protocol;
mod runtime;
mod service;
mod strict;
mod sync;
#[cfg(test)]
mod tests;
mod transport;
use nsh_core::prelude::*;
use serde_json::{Value, json};
type Result<T> = std::result::Result<T, String>;
fn invalid<T>() -> Result<T> {
    Err("InvalidData".into())
}
/// Unlocked relay operations and lock-aware connection lifecycle.
#[module]
pub struct Relay;
#[module]
impl Relay {
    /// Changes vault permission separately from membership. Revocation stops transport first.
    pub async fn authorize(
        vault: Instance<crate::Vault>,
        peer: String,
        enabled: bool,
    ) -> Result<()> {
        let (session, directory) = vault.with(|v| (v.session.clone(), v.directory.clone()));
        let session = session.ok_or("Locked")?;
        runtime::stop(&session);
        blocking(move || {
            if enabled {
                service::execute(&session, json!({"op":"refresh"}), false)?;
            }
            access::set(&session, &peer, enabled)?;
            runtime::start(session, directory, false)
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }
    /// Pauses only vault replication, preserving group presence.
    pub async fn pause(vault: Instance<crate::Vault>, paused: bool) -> Result<()> {
        let (session, directory) = vault.with(|v| (v.session.clone(), v.directory.clone()));
        let session = session.ok_or("Locked")?;
        runtime::stop(&session);
        blocking(move || {
            access::pause(&session, paused)?;
            runtime::start(session, directory, false)
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }
    /// Explicitly resumes authorized replication; durable replay IDs stay intact.
    pub fn sync_now(vault: Instance<crate::Vault>) -> Result<()> {
        let (session, directory) = vault.with(|v| (v.session.clone(), v.directory.clone()));
        let session = session.ok_or("Locked")?;
        runtime::stop(&session);
        access::resume(&session)?;
        runtime::start(session, directory, false)
    }
    /// Starts presence for an unlocked, explicitly enrolled vault.
    pub fn connect(vault: Instance<crate::Vault>) -> Result<()> {
        runtime::start(
            vault.with(|v| v.session.clone()).ok_or("Locked")?,
            vault.with(|v| v.directory.clone()),
            false,
        )
    }
    /// Synchronously interrupts the socket, including an in-progress TLS handshake.
    pub fn disconnect(vault: Instance<crate::Vault>) {
        if let Some(session) = vault.with(|v| v.session.clone()) {
            runtime::stop(&session);
        }
    }
    /// Public transport state only.
    pub fn connection_status(vault: Instance<crate::Vault>) -> String {
        vault
            .with(|v| {
                v.session
                    .as_ref()
                    .map(runtime::view)
                    .unwrap_or(json!({"transport":"disconnected","online":[]}))
            })
            .to_string()
    }
    /// Runs an explicit group operation; credentials and pending drafts stay in Rust.
    pub async fn action(vault: Instance<crate::Vault>, request: String) -> Result<String> {
        let (session, directory) = vault.with(|v| (v.session.clone(), v.directory.clone()));
        let session = session.ok_or("Locked")?;
        let request = zeroize::Zeroizing::new(request);
        let request: Value = serde_json::from_str(&request).map_err(|_| "InvalidData")?;
        blocking(move || {
            if matches!(request["op"].as_str(), Some("leave" | "disband")) {
                return runtime::exit_local(&session, directory, request["op"] == "disband", false);
            }
            runtime::stop(&session);
            let result = service::execute(&session, request, false);
            if let Err(error) = &result {
                if runtime::authentication_failure(error) {
                    runtime::block_authentication(&session, directory, error);
                    return result;
                }
            }
            let _ = runtime::start(session, directory, false);
            result
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }
    /// Decodes a picked invitation image locally and validates its link before showing it.
    pub async fn invitation_image(bytes: Vec<u8>) -> Result<String> {
        blocking(move || {
            let link = crate::qr_import::decode_bytes(&bytes, "common-relay://")
                .map_err(|_| "RelayQrInvalid".to_string())?;
            protocol::parse_link(&link).map_err(|_| "RelayQrInvalid".to_string())?;
            Ok(link)
        }).await.map_err(|_| "Storage".to_string())?
    }
    /// QR matrix includes a four-module quiet zone, rendered without external images.
    pub fn qr(text: String) -> Result<String> {
        if text.len() > 2048 {
            return invalid();
        }
        let code = qrcode::QrCode::new(text.as_bytes()).map_err(|_| "InvalidData")?;
        let n = code.width();
        let mut rows = vec![vec![false; n + 8]; n + 8];
        for y in 0..n {
            for x in 0..n {
                rows[y + 4][x + 4] = code[(x, y)] == qrcode::Color::Dark;
            }
        }
        Ok(json!(rows).to_string())
    }
    /// Returns unlocked UI state, including an issued invitation capability; identity keys and tokens stay native.
    pub async fn summary(vault: Instance<crate::Vault>) -> Result<String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || read_summary(&session))
            .await
            .map_err(|_| "Storage".to_string())?
    }
}

fn read_summary(session: &vault_core::VaultSession) -> Result<String> {
    Ok(service::display(&service::read(session)?)?.to_string())
}
