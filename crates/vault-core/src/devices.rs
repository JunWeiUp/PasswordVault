//! Explicitly enabled device records. Commands and files are inert encrypted data.
use crate::{Result, VaultError};
use serde_json::Value;
use std::collections::HashSet;

pub const DEVICES_FORMAT: u32 = 7;

pub fn validate_device(item: &Value) -> Result<()> {
    if item["type"] != "device" {
        return Ok(());
    }
    let d = &item["device"];
    if d["version"] != 1
        || !d.is_object()
        || !valid_port(&d["port"])
        || !matches!(d["authMethod"].as_str(), Some("password" | "key" | "agent"))
        || item["sharedVaultId"]
            .as_str()
            .is_some_and(|s| !s.is_empty())
    {
        return Err(VaultError::InvalidData);
    }
    for (key, limit) in [
        ("host", 1024),
        ("username", 1024),
        ("password", 65536),
        ("privateKey", 65536),
        ("notes", 262144),
    ] {
        if d[key].as_str().is_none_or(|s| s.len() > limit) {
            return Err(VaultError::InvalidData);
        }
    }
    let aliases = d["aliases"]
        .as_array()
        .filter(|a| a.len() <= 128)
        .ok_or(VaultError::InvalidData)?;
    if aliases
        .iter()
        .any(|v| v.as_str().is_none_or(|s| s.len() > 1024))
    {
        return Err(VaultError::InvalidData);
    }
    for key in ["services", "commands", "files"] {
        let rows = d[key]
            .as_array()
            .filter(|a| a.len() <= 256)
            .ok_or(VaultError::InvalidData)?;
        let mut ids = HashSet::new();
        for row in rows {
            let id_key = if key == "files" { "attachmentId" } else { "id" };
            let id = row[id_key]
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= 256)
                .ok_or(VaultError::InvalidData)?;
            if !ids.insert(id) {
                return Err(VaultError::InvalidData);
            }
            let fields: &[(&str, usize)] = match key {
                "services" => &[("name", 1024), ("path", 8192)],
                "commands" => &[("title", 1024), ("text", 262144)],
                _ => &[("name", 1024), ("mime", 128)],
            };
            for (field, limit) in fields {
                if row[*field].as_str().is_none_or(|s| s.len() > *limit) {
                    return Err(VaultError::InvalidData);
                }
            }
            if key == "services"
                && (!valid_port(&row["remotePort"])
                    || !valid_port(&row["localPort"])
                    || !matches!(
                        row["kind"].as_str(),
                        Some("ssh" | "vnc" | "browser" | "custom")
                    ))
            {
                return Err(VaultError::InvalidData);
            }
            if key == "commands" && !row["secret"].is_boolean() {
                return Err(VaultError::InvalidData);
            }
            if key == "files" && row["size"].as_u64().is_none_or(|n| n > 25 * 1024 * 1024) {
                return Err(VaultError::InvalidData);
            }
        }
    }
    Ok(())
}
fn valid_port(value: &Value) -> bool {
    value.as_u64().is_some_and(|v| (1..=65535).contains(&v))
}

/// Only ordinary metadata belongs in list search; never index keys or command contents.
pub fn device_search_text(item: &Value) -> String {
    let d = &item["device"];
    let mut terms = vec![
        item["title"].as_str().unwrap_or(""),
        d["host"].as_str().unwrap_or(""),
        d["username"].as_str().unwrap_or(""),
    ];
    terms.extend(
        d["aliases"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str),
    );
    terms.extend(
        item["tags"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str),
    );
    terms.extend(
        d["services"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|s| s["name"].as_str()),
    );
    terms.join(" ").to_lowercase()
}

/// No unauthenticated caller-supplied capability flag may bypass this gate.
pub fn guard_device_sync(format: u32, op: &str) -> Result<()> {
    if format >= DEVICES_FORMAT
        && (op.starts_with("relay-")
            || op.starts_with("peer-transport-")
            || op.starts_with("sync-"))
        && !matches!(
            op,
            "relay-status"
                | "relay-peer-status"
                | "relay-peer-list"
                | "relay-credentials-read"
                | "relay-credentials-write"
                | "peer-transport-status"
                // Access-reducing local operations stay available: revoking a
                // device and detaching (archiving the journal) export nothing.
                | "relay-revoke"
                | "relay-detach"
        )
    {
        return Err(VaultError::DevicesSyncBlocked);
    }
    Ok(())
}

#[cfg(test)]
mod device_sync_gate_tests {
    use super::*;

    #[test]
    fn format7_keeps_only_status_and_access_reducing_relay_ops() {
        for op in [
            "relay-revoke",
            "relay-detach",
            "relay-status",
            "relay-credentials-read",
        ] {
            assert!(
                guard_device_sync(DEVICES_FORMAT, op).is_ok(),
                "{op} must stay available"
            );
        }
        for op in [
            "relay-export",
            "relay-trust",
            "relay-init",
            "relay-receive",
            "relay-resolve",
            "relay-peer-export",
            "sync-apply",
        ] {
            assert!(
                matches!(
                    guard_device_sync(DEVICES_FORMAT, op),
                    Err(VaultError::DevicesSyncBlocked)
                ),
                "{op} must stay blocked"
            );
        }
        assert!(guard_device_sync(DEVICES_FORMAT - 1, "relay-export").is_ok());
    }
}
