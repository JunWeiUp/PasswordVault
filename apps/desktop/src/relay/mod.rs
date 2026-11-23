//! Relay orchestration, encrypted credentials, presence and symmetric group sync.
#![allow(dead_code)]
mod files;
#[cfg(test)]
mod group_tests;
mod groups;
mod journal;
mod mesh;
mod protocol;
mod runtime;
mod service;
#[cfg(test)]
mod tests;
mod transport;
#[cfg(feature = "ui")]
use nsh_core::prelude::*;
use serde_json::Value;
#[cfg(feature = "ui")]
use serde_json::json;
type Result<T> = std::result::Result<T, String>;
fn invalid<T>() -> Result<T> {
    Err("InvalidData".into())
}
#[cfg(all(feature = "ui", target_os = "macos", not(test)))]
async fn remote(vault: Instance<crate::Vault>, request: Value) -> Result<Value> {
    let directory = vault.with(|v| v.directory.clone());
    crate::service_ipc::control_async(directory, "relay", request).await
}
/// Unlocked relay operations and lock-aware connection lifecycle.
#[cfg(feature = "ui")]
#[module]
pub struct Relay;
#[cfg(feature = "ui")]
#[module]
impl Relay {
    /// Restarts the sync loop so pending changes go out immediately.
    pub async fn sync_now(vault: Instance<crate::Vault>) -> Result<()> {
        #[cfg(all(target_os = "macos", not(test)))]
        {
            return remote(vault, json!({"method":"sync"})).await.map(|_| ());
        }
        #[allow(unreachable_code)]
        let (session, directory) = vault.with(|v| (v.session.clone(), v.directory.clone()));
        let session = session.ok_or("Locked")?;
        runtime::stop(&session);
        runtime::start(session, directory, false)
    }
    /// Starts presence for an unlocked, explicitly enrolled vault.
    pub async fn connect(vault: Instance<crate::Vault>) -> Result<()> {
        #[cfg(all(target_os = "macos", not(test)))]
        {
            return remote(vault, json!({"method":"connect"})).await.map(|_| ());
        }
        #[allow(unreachable_code)]
        runtime::start(
            vault.with(|v| v.session.clone()).ok_or("Locked")?,
            vault.with(|v| v.directory.clone()),
            false,
        )
    }
    /// Synchronously interrupts the socket, including an in-progress TLS handshake.
    pub async fn disconnect(vault: Instance<crate::Vault>) {
        #[cfg(all(target_os = "macos", not(test)))]
        {
            let _ = remote(vault, json!({"method":"disconnect"})).await;
            return;
        }
        #[allow(unreachable_code)]
        if let Some(session) = vault.with(|v| v.session.clone()) {
            runtime::stop(&session);
        }
    }
    /// Public transport state only.
    pub async fn connection_status(vault: Instance<crate::Vault>) -> String {
        #[cfg(all(target_os = "macos", not(test)))]
        {
            return remote(vault, json!({"method":"status"}))
                .await
                .map(|v| v.to_string())
                .unwrap_or_else(|_| "{}".into());
        }
        #[allow(unreachable_code)]
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
        #[cfg(all(target_os = "macos", not(test)))]
        {
            return remote(vault, json!({"method":"action","request":request}))
                .await
                .and_then(|v| v.as_str().map(str::to_owned).ok_or("InvalidData".into()));
        }
        #[allow(unreachable_code)]
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
        })
        .await
        .map_err(|_| "Storage".to_string())?
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
    /// Queues an on-demand L3 attachment download from an online mesh peer.
    pub async fn request_blob(
        vault: Instance<crate::Vault>,
        note_id: String,
        attachment_id: String,
        source_device: Option<String>,
    ) -> Result<String> {
        #[cfg(all(target_os = "macos", not(test)))]
        {
            return remote(
                vault,
                json!({
                    "method": "request_blob",
                    "noteId": note_id,
                    "attachmentId": attachment_id,
                    "sourceDevice": source_device,
                }),
            )
            .await
            .map(|v| v.to_string());
        }
        #[allow(unreachable_code)]
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            runtime::request_blob(&session, &note_id, &attachment_id, source_device.as_deref())
                .map(|v| v.to_string())
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }
    /// Returns unlocked UI state, including an issued invitation capability; identity keys and tokens stay native.
    pub async fn summary(vault: Instance<crate::Vault>) -> Result<String> {
        #[cfg(all(target_os = "macos", not(test)))]
        {
            return remote(vault, json!({"method":"summary"}))
                .await
                .and_then(|v| v.as_str().map(str::to_owned).ok_or("InvalidData".into()));
        }
        #[allow(unreachable_code)]
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || read_summary(&session))
            .await
            .map_err(|_| "Storage".to_string())?
    }
}

fn read_summary(session: &crate::session::VaultSession) -> Result<String> {
    Ok(service::display(&service::read(session)?)?.to_string())
}

#[cfg(not(feature = "ui"))]
pub(crate) fn stop_background(session: &std::sync::Arc<vault_core::VaultSession>) {
    runtime::stop(session);
}
#[cfg(not(feature = "ui"))]
pub(crate) fn background_dispatch(
    session: std::sync::Arc<vault_core::VaultSession>,
    directory: std::path::PathBuf,
    args: &Value,
) -> Result<Value> {
    let method = args["method"].as_str().ok_or("InvalidData")?;
    match method {
        "connect" => {
            runtime::start(session, directory, false)?;
            Ok(Value::Null)
        }
        "disconnect" => {
            runtime::stop(&session);
            Ok(Value::Null)
        }
        "status" => Ok(runtime::view(&session)),
        "summary" => Ok(Value::String(read_summary(&session)?)),
        "sync" => {
            runtime::stop(&session);
            runtime::start(session, directory, false)?;
            Ok(Value::Null)
        }
        "request_blob" => {
            let note_id = args["noteId"].as_str().ok_or("InvalidData")?;
            let attachment_id = args["attachmentId"].as_str().ok_or("InvalidData")?;
            let source_device = args["sourceDevice"].as_str();
            runtime::request_blob(&session, note_id, attachment_id, source_device)
        }
        "action" => {
            let request: Value =
                serde_json::from_str(args["request"].as_str().ok_or("InvalidData")?)
                    .map_err(|_| "InvalidData")?;
            if matches!(request["op"].as_str(), Some("leave" | "disband")) {
                return runtime::exit_local(&session, directory, request["op"] == "disband", false)
                    .map(Value::String);
            }
            runtime::stop(&session);
            let result = service::execute(&session, request, false);
            if let Err(error) = &result {
                if runtime::authentication_failure(error) {
                    runtime::block_authentication(&session, directory, error);
                    return result.map(Value::String);
                }
            }
            let _ = runtime::start(session, directory, false);
            result.map(Value::String)
        }
        _ => Err("Unsupported".into()),
    }
}

#[cfg(not(feature = "ui"))]
pub(crate) fn connect_background(
    session: std::sync::Arc<vault_core::VaultSession>,
    directory: std::path::PathBuf,
) -> Result<()> {
    runtime::start(session, directory, false)
}
