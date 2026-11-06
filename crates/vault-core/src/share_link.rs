//! Encrypted snapshots for temporary sharing. The service never receives the URL key.
use crate::*;
use base64::engine::general_purpose::STANDARD;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use zeroize::Zeroizing;

pub const SHARE_FIELDS: &[&str] = &[
    "title",
    "username",
    "password",
    "url",
    "note",
    "secret",
    "mnemonic",
    "privateKey",
    "address",
    "network",
    "category",
    "tags",
    "card",
    "identity",
    "customFields",
];
#[derive(Serialize, Deserialize)]
pub struct ShareAttachment {
    pub name: String,
    pub mime: String,
    pub data: String,
}

pub fn seal_share(
    item: &Value,
    fields: &[String],
    attachments: &[ShareAttachment],
) -> Result<Value> {
    if item["isDeleted"] == true
        || fields.is_empty()
        || fields.len() > SHARE_FIELDS.len()
        || !fields
            .iter()
            .all(|key| SHARE_FIELDS.contains(&key.as_str()))
    {
        return Err(VaultError::InvalidData);
    }
    if ![
        "password",
        "totp",
        "crypto",
        "secureNote",
        "creditCard",
        "identity",
    ]
    .contains(&item["type"].as_str().unwrap_or(""))
    {
        return Err(VaultError::Unsupported);
    }
    validate_structured_item(item)?;
    let selected: serde_json::Map<String, Value> = fields
        .iter()
        .filter_map(|key| item.get(key).map(|value| (key.clone(), value.clone())))
        .collect();
    let clear = Zeroizing::new(serde_json::to_vec(&json!({"title":selected.get("title").cloned().unwrap_or(json!("Shared item")), "type":item["type"], "fields":selected, "attachments":attachments})).map_err(|_|VaultError::InvalidData)?);
    if clear.len() > 24 * 1024 * 1024 {
        return Err(VaultError::InvalidData);
    }
    let id = new_id();
    let key = Zeroizing::new(random_bytes::<32>());
    let envelope = seal(
        &key,
        &clear,
        format!("PasswordVaultShare/v1/{id}").as_bytes(),
    )?;
    Ok(
        json!({"version":1,"id":id,"nonce":envelope.nonce,"ciphertext":envelope.ciphertext,"key":URL_SAFE_NO_PAD.encode(key.as_ref())}),
    )
}

pub fn open_share(envelope: &Value, key: &str) -> Result<Value> {
    let id = envelope["id"].as_str().ok_or(VaultError::InvalidData)?;
    if envelope["version"] != 1 || id.len() != 32 || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(VaultError::InvalidData);
    }
    let bytes = Zeroizing::new(
        URL_SAFE_NO_PAD
            .decode(key)
            .map_err(|_| VaultError::InvalidData)?,
    );
    let key = Zeroizing::new(
        <[u8; 32]>::try_from(bytes.as_slice()).map_err(|_| VaultError::InvalidData)?,
    );
    let sealed = Sealed {
        nonce: envelope["nonce"]
            .as_str()
            .ok_or(VaultError::InvalidData)?
            .into(),
        ciphertext: envelope["ciphertext"]
            .as_str()
            .ok_or(VaultError::InvalidData)?
            .into(),
    };
    let clear = unseal(
        &key,
        &sealed,
        format!("PasswordVaultShare/v1/{id}").as_bytes(),
    )?;
    if clear.len() > 24 * 1024 * 1024 {
        return Err(VaultError::InvalidData);
    }
    serde_json::from_slice(&clear).map_err(|_| VaultError::InvalidData)
}

pub(crate) fn share_attachment(name: String, mime: String, bytes: &[u8]) -> ShareAttachment {
    ShareAttachment {
        name,
        mime,
        data: STANDARD.encode(bytes),
    }
}
