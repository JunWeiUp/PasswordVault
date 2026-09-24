//! Read-only mobile SQLite migration. Source files and keys are never modified.
use crate::{legacy_decrypt, Document, Kdf, Result, VaultError};
use base64::{engine::general_purpose::STANDARD, Engine};
use rusqlite::{types::ValueRef, Connection, OpenFlags};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::path::Path;
use zeroize::Zeroizing;

pub fn read_legacy_database(path: &Path, password: &str, salt: &str) -> Result<Document> {
    if std::fs::metadata(path)
        .map_err(|_| VaultError::Storage)?
        .len()
        > crate::MAX_INPUT as u64
    {
        return Err(VaultError::InvalidData);
    }
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|_| VaultError::Storage)?;
    conn.execute_batch(
        "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; PRAGMA temp_store=MEMORY;",
    )
    .map_err(|_| VaultError::Storage)?;
    let version: i64 = conn
        .pragma_query_value(None, "user_version", |r| r.get(0))
        .map_err(|_| VaultError::InvalidData)?;
    if !(1..=12).contains(&version) {
        return Err(VaultError::Unsupported);
    }
    let sharing_table: i64 = conn
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='shared_vaults'",
            [],
            |r| r.get(0),
        )
        .map_err(|_| VaultError::InvalidData)?;
    if sharing_table > 0 {
        let count: i64 = conn
            .query_row("SELECT count(*) FROM shared_vaults", [], |r| r.get(0))
            .map_err(|_| VaultError::InvalidData)?;
        if count > 0 {
            return Err(VaultError::Unsupported);
        }
    }
    let argon = Kdf {
        salt: salt.into(),
        memory_kib: 32768,
        iterations: 2,
        parallelism: 1,
    }
    .derive(password)?;
    let simple = Zeroizing::new(<[u8; 32]>::from(Sha256::digest(password.as_bytes())));
    let standard = Kdf {
        salt: STANDARD.encode(b"SecurePass_Backup_Standard_Salt_2024"),
        memory_kib: 32768,
        iterations: 2,
        parallelism: 1,
    }
    .derive(password)?;
    let mut statement = conn
        .prepare("SELECT * FROM vault_items")
        .map_err(|_| VaultError::InvalidData)?;
    let columns = statement
        .column_names()
        .iter()
        .map(|s| s.to_string())
        .collect::<Vec<_>>();
    let mut rows = statement.query([]).map_err(|_| VaultError::Storage)?;
    let mut document = Document::default();
    let mut authenticated = false;
    let mut total_bytes = 0usize;
    while let Some(row) = rows.next().map_err(|_| VaultError::Storage)? {
        if document.items.len() >= 100_000 {
            return Err(VaultError::InvalidData);
        }
        let mut item = Map::new();
        for (i, name) in columns.iter().enumerate() {
            let key = camel(name);
            let value = match row.get_ref(i).map_err(|_| VaultError::InvalidData)? {
                ValueRef::Null => Value::Null,
                ValueRef::Integer(n) => json!(n),
                ValueRef::Real(n) => json!(n),
                ValueRef::Text(bytes) => Value::String(
                    std::str::from_utf8(bytes)
                        .map_err(|_| VaultError::InvalidData)?
                        .into(),
                ),
                ValueRef::Blob(_) => return Err(VaultError::InvalidData),
            };
            item.insert(key, value);
        }
        if item
            .get("sharedVaultId")
            .and_then(Value::as_str)
            .is_some_and(|s| !s.is_empty())
        {
            // Legacy sharing uses a different identity/key envelope. Require the old client's authenticated export.
            return Err(VaultError::Unsupported);
        }
        for field in [
            "secret",
            "password",
            "mnemonic",
            "privateKey",
            "address",
            "note",
            "passwordHistory",
            "accounts",
            "tags",
        ] {
            if let Some(encoded) = item.get(field).and_then(Value::as_str) {
                if encoded.is_empty() {
                    continue;
                }
                let bytes = STANDARD
                    .decode(encoded)
                    .map_err(|_| VaultError::InvalidData)?;
                let clear = legacy_decrypt(&bytes, &argon)
                    .or_else(|_| legacy_decrypt(&bytes, &simple))
                    .or_else(|_| legacy_decrypt(&bytes, &standard))?;
                authenticated = true;
                let text = std::str::from_utf8(&clear).map_err(|_| VaultError::InvalidData)?;
                let value = if ["passwordHistory", "accounts", "tags"].contains(&field) {
                    serde_json::from_str::<Value>(text).map_err(|_| VaultError::InvalidData)?
                } else {
                    json!(text)
                };
                item.insert(field.into(), value);
            }
        }
        let kind = item
            .get("type")
            .and_then(Value::as_i64)
            .ok_or(VaultError::InvalidData)?;
        item.insert(
            "type".into(),
            json!(match kind {
                0 => "password",
                1 => "totp",
                2 => "crypto",
                3 => "secureNote",
                _ => return Err(VaultError::InvalidData),
            }),
        );
        for key in ["isDeleted", "isPinned", "isFavorite"] {
            let enabled = item.get(key).and_then(Value::as_i64).unwrap_or(0) != 0;
            item.insert(key.into(), json!(enabled));
        }
        for key in ["updatedAt", "deletedAt", "passwordLastChanged"] {
            if let Some(seconds) = item.get(key).and_then(Value::as_i64) {
                let time =
                    chrono::DateTime::from_timestamp(seconds, 0).ok_or(VaultError::InvalidData)?;
                item.insert(key.into(), json!(time.to_rfc3339()));
            }
        }
        item.retain(|_, value| !value.is_null());
        let item = Value::Object(item);
        total_bytes = total_bytes
            .checked_add(
                serde_json::to_vec(&item)
                    .map_err(|_| VaultError::InvalidData)?
                    .len(),
            )
            .ok_or(VaultError::InvalidData)?;
        if total_bytes > crate::MAX_INPUT {
            return Err(VaultError::InvalidData);
        }
        document.upsert(item)?;
    }
    // An empty/plain-metadata-only database cannot authenticate a master password.
    if !authenticated {
        return Err(VaultError::Authentication);
    }
    Ok(document)
}
fn camel(value: &str) -> String {
    let mut upper = false;
    value
        .chars()
        .map(|c| {
            if c == '_' {
                upper = true;
                String::new()
            } else if upper {
                upper = false;
                c.to_uppercase().collect()
            } else {
                c.to_string()
            }
        })
        .collect()
}
