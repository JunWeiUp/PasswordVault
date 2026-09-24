//! Read-only compatibility. Legacy derivations are never used for new writes.
use crate::{crypto::*, new_id, Document, Result, VaultError};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

pub fn legacy_decrypt(bytes: &[u8], key: &[u8; 32]) -> Result<Zeroizing<Vec<u8>>> {
    if bytes.len() < 28 {
        return Err(VaultError::InvalidData);
    }
    unseal(
        key,
        &Sealed {
            nonce: STANDARD.encode(&bytes[..12]),
            ciphertext: STANDARD.encode(&bytes[12..]),
        },
        b"",
    )
}

pub fn import_document(input: &str, password: &str, kind: &str) -> Result<Document> {
    if input.len() > MAX_INPUT {
        return Err(VaultError::InvalidData);
    }
    if kind == "csv" {
        return import_csv(input);
    }
    if kind == "encrypted-csv" {
        let bytes = STANDARD
            .decode(input.split_whitespace().collect::<String>())
            .map_err(|_| VaultError::InvalidData)?;
        let key = Zeroizing::new(<[u8; 32]>::from(Sha256::digest(password.trim().as_bytes())));
        let clear = legacy_decrypt(&bytes, &key)?;
        return import_csv(std::str::from_utf8(&clear).map_err(|_| VaultError::InvalidData)?);
    }
    let value: Value = serde_json::from_str(input).map_err(|_| VaultError::InvalidData)?;
    if value["format"] == "PasswordVaultCSVBackup" {
        if value["version"] != 1 {
            return Err(VaultError::Unsupported);
        }
        let envelope =
            serde_json::to_string(&value["envelope"]).map_err(|_| VaultError::InvalidData)?;
        let clear = decrypt_backup(&envelope, password)?;
        return import_csv(std::str::from_utf8(&clear).map_err(|_| VaultError::InvalidData)?);
    }
    if value["format"] == "PasswordVaultBackup" {
        return Document::parse(&decrypt_backup(input, password)?);
    }
    if value["metadata"]["encrypted"] != true {
        return Document::parse(input.as_bytes());
    }
    let payload = value["payload"].as_str().ok_or(VaultError::InvalidData)?;
    let bytes = STANDARD
        .decode(payload.split_whitespace().collect::<String>())
        .map_err(|_| VaultError::InvalidData)?;
    let metadata = &value["metadata"];
    // Try the exact password for WebDAV backups; the legacy manual exporter trimmed it.
    for candidate in [password, password.trim()] {
        let simple = Zeroizing::new(<[u8; 32]>::from(Sha256::digest(candidate.as_bytes())));
        if let Ok(clear) = legacy_decrypt(&bytes, &simple) {
            return Document::parse(&clear);
        }
        if let Some(salt) = metadata["salt"].as_str() {
            let kdf = Kdf {
                salt: salt.into(),
                memory_kib: param(metadata, "memory", "argon2_memory", 32768)?,
                iterations: param(metadata, "iterations", "argon2_iterations", 2)?,
                parallelism: param(metadata, "parallelism", "argon2_parallelism", 1)?,
            };
            let key = kdf.derive(candidate)?;
            if let Ok(clear) = legacy_decrypt(&bytes, &key) {
                return Document::parse(&clear);
            }
        }
        let kdf = Kdf {
            salt: STANDARD.encode(b"SecurePass_Backup_Standard_Salt_2024"),
            memory_kib: 32768,
            iterations: 2,
            parallelism: 1,
        };
        let key = kdf.derive(candidate)?;
        if let Ok(clear) = legacy_decrypt(&bytes, &key) {
            return Document::parse(&clear);
        }
    }
    Err(VaultError::Authentication)
}

fn param(v: &Value, a: &str, b: &str, default: u32) -> Result<u32> {
    match v.get(a).or_else(|| v.get(b)) {
        Some(value) => value
            .as_u64()
            .and_then(|n| n.try_into().ok())
            .ok_or(VaultError::InvalidData),
        None => Ok(default),
    }
}

pub fn import_csv(input: &str) -> Result<Document> {
    let mut reader = csv::ReaderBuilder::new()
        .flexible(true)
        .from_reader(input.trim_start_matches('\u{feff}').as_bytes());
    let headers = reader
        .headers()
        .map_err(|_| VaultError::InvalidData)?
        .clone();
    let labels: Vec<String> = headers.iter().map(|s| s.trim().to_lowercase()).collect();
    if !labels.iter().any(|s| {
        [
            "title",
            "name",
            "username",
            "user",
            "password",
            "login_password",
            "secret",
            "note",
            "notes",
            "privatekey",
            "private_key",
        ]
        .contains(&s.as_str())
    }) {
        return Err(VaultError::Unsupported);
    }
    let mut doc = Document::default();
    for row in reader.records() {
        let row = row.map_err(|_| VaultError::InvalidData)?;
        if row.len() > headers.len() {
            return Err(VaultError::InvalidData);
        }
        let get = |keys: &[&str]| -> String {
            keys.iter()
                .find_map(|key| {
                    labels
                        .iter()
                        .position(|s| s == key)
                        .and_then(|i| row.get(i))
                        .filter(|s| !s.is_empty())
                })
                .unwrap_or("")
                .to_string()
        };
        let original_type = get(&["type"]);
        let kind = match original_type.as_str() {
            "totp" => "totp",
            "crypto" => "crypto",
            "secureNote" | "securenote" | "note" => "secureNote",
            _ => "password",
        };
        let title = get(&["title", "name"]);
        let url = get(&["url", "login_uri", "website", "urls"]);
        let mut item = json!({"id":new_id(),"type":kind,"title":if title.is_empty(){url.clone()}else{title},
            "username":get(&["username","user","login_username","login"]),"password":get(&["password","login_password"]),
            "secret":get(&["secret"]),"period":get(&["period"]).parse::<u64>().unwrap_or(30),
            "url":url,"note":get(&["note","notes","extra"]),"category":get(&["category","folder","group","grouping"]),
            "email":get(&["email"]),"network":get(&["network"]),"address":get(&["address"]),
            "privateKey":get(&["privatekey", "private_key"]),"mnemonic":get(&["mnemonic"])});
        crate::normalize_item(&mut item)?;
        doc.items.push(item);
    }
    Ok(doc)
}

pub fn export_csv(doc: &Document) -> Result<String> {
    let fields = [
        "type",
        "title",
        "username",
        "password",
        "secret",
        "period",
        "url",
        "note",
        "category",
        "email",
        "network",
        "address",
        "privateKey",
        "mnemonic",
    ];
    let mut writer = csv::Writer::from_writer(Vec::new());
    writer
        .write_record(fields)
        .map_err(|_| VaultError::Storage)?;
    for item in &doc.items {
        let cells: Vec<String> = fields
            .iter()
            .map(|key| match &item[*key] {
                Value::String(s) => s.clone(),
                Value::Null => String::new(),
                other => other.to_string(),
            })
            .collect();
        writer
            .write_record(cells)
            .map_err(|_| VaultError::Storage)?;
    }
    String::from_utf8(writer.into_inner().map_err(|_| VaultError::Storage)?)
        .map_err(|_| VaultError::Storage)
}
