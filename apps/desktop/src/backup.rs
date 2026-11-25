//! Local backup and HTTPS WebDAV. File content never crosses into JavaScript.
use crate::{Vault, error_code};
use base64::{Engine, engine::general_purpose::STANDARD};
use nsh_core::prelude::*;
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    path::Path,
};
use zeroize::Zeroizing;
const LIMIT: u64 = 128 * 1024 * 1024;
/// Local encrypted archives, reviewed imports and HTTPS WebDAV.
#[module]
pub struct Backup;
fn read(path: &str) -> Result<Zeroizing<Vec<u8>>, String> {
    let file = std::fs::File::open(path).map_err(|_| "Storage")?;
    if !file.metadata().map_err(|_| "Storage")?.is_file() {
        return Err("InvalidData".into());
    }
    limited(file, LIMIT)
}
fn limited(reader: impl Read, limit: u64) -> Result<Zeroizing<Vec<u8>>, String> {
    let mut bytes = Zeroizing::new(Vec::new());
    reader
        .take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "Storage")?;
    if bytes.len() as u64 > limit {
        return Err("InvalidData".into());
    }
    Ok(bytes)
}
fn command(session: &crate::session::VaultSession, value: Value) -> Result<String, String> {
    let request = Zeroizing::new(value.to_string());
    session.command(request.to_string()).map_err(error_code)
}
fn archive(session: &crate::session::VaultSession, password: &str) -> Result<String, String> {
    let response = command(
        session,
        json!({"op":"export","password":password,"richNotes":true}),
    )?;
    let value: Value = serde_json::from_str(&response).map_err(|_| "InvalidData")?;
    Ok(value["content"].as_str().ok_or("InvalidData")?.into())
}
fn merge(
    session: &crate::session::VaultSession,
    data: &[u8],
    password: &str,
) -> Result<String, String> {
    command(
        session,
        json!({"op":"import","content":std::str::from_utf8(data).map_err(|_| "InvalidData")?,"password":password,"richNotes":true}),
    )
}
fn dav_error(error: vault_core::WebDavError) -> String {
    match error {
        vault_core::WebDavError::Failed { code } => code,
    }
}
pub(crate) fn write_new(path: &Path, bytes: &[u8]) -> Result<(), String> {
    #[cfg(unix)]
    use std::os::unix::fs::OpenOptionsExt;
    let parent = path.parent().ok_or("InvalidData")?;
    let staging = parent.join(format!(".pvbackup-{}.tmp", uuid::Uuid::new_v4()));
    let result: Result<(), &str> = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);
        let mut file = options.open(&staging).map_err(|_| "Storage")?;
        file.write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| "Storage")?;
        // Linking is atomic and fails if the destination already exists, including symlinks.
        std::fs::hard_link(&staging, path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::AlreadyExists {
                "AlreadyExists"
            } else {
                "Storage"
            }
        })?;
        Ok(())
    })();
    let _ = std::fs::remove_file(staging);
    result.map_err(String::from)
}
fn structured_file(
    session: &crate::session::VaultSession,
    path: &str,
    options: &str,
) -> Result<String, String> {
    let mut value: Value = serde_json::from_str(&options).map_err(|_| "InvalidData")?;
    if !["import-preview", "import-commit"].contains(&value["op"].as_str().unwrap_or("")) {
        return Err("InvalidData".into());
    }
    let data = read(&path)?;
    use sha2::{Digest, Sha256};
    let fingerprint = format!("{:x}", Sha256::digest(&*data));
    if value["op"] == "import-commit" && value["fingerprint"] != fingerprint {
        return Err("StaleEdit".into());
    }
    value["data"] = json!(STANDARD.encode(&*data));
    value["richNotes"] = json!(true);
    let result = command(&session, value)?;
    let mut result: Value = serde_json::from_str(&result).map_err(|_| "InvalidData")?;
    result["fingerprint"] = json!(fingerprint);
    // Preview exposes summaries, never passwords or retained source material.
    if let Some(rows) = result["rows"].as_array_mut() {
        for row in rows {
            let i = &row["item"];
            row["item"] = json!({"title":i["title"],"type":i["type"],"username":i["username"],"url":i["url"],"passkeys":i["passkeys"].as_array().map(|k| k.len())});
        }
    }
    Ok(result.to_string())
}
#[module]
impl Backup {
    /// Writes a complete encrypted archive to a new destination.
    pub async fn export_file(
        vault: Instance<Vault>,
        path: String,
        password: String,
    ) -> Result<(), String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            let password = Zeroizing::new(password);
            let content = archive(&session, &password)?;
            write_new(Path::new(&path), content.as_bytes())
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }
    /// Writes a FIDO CXF v1.0 export (plaintext passwords and passkey private keys) to a new
    /// owner-only file. The core reauthenticates the master password; content never reaches TS.
    pub async fn export_cxf(
        vault: Instance<Vault>,
        path: String,
        password: String,
    ) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            let password = Zeroizing::new(password);
            let output = Zeroizing::new(command(
                &session,
                json!({"op":"export-cxf","currentPassword":password.as_str()}),
            )?);
            let mut value: Value = serde_json::from_str(&output).map_err(|_| "InvalidData")?;
            let content =
                Zeroizing::new(value["content"].as_str().ok_or("InvalidData")?.to_owned());
            value["content"] = Value::Null;
            write_new(Path::new(&path), content.as_bytes())?;
            Ok(json!({"skipped":value["skipped"]}).to_string())
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }
    /// Merges a local archive through the shared core.
    pub async fn import_file(
        vault: Instance<Vault>,
        path: String,
        password: String,
    ) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || merge(&session, &read(&path)?, &Zeroizing::new(password)))
            .await
            .map_err(|_| "Storage".to_string())?
    }
    /// Previews summaries or commits a fingerprint-bound CSV/1PUX source.
    pub async fn structured(
        vault: Instance<Vault>,
        path: String,
        options: String,
    ) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || structured_file(&session, &path, &options))
            .await
            .map_err(|_| "Storage".to_string())?
    }
    /// Saves encrypted configuration, lists, uploads, or restores via HTTPS.
    pub async fn webdav(vault: Instance<Vault>, options: String) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            let status: Value = serde_json::from_str(&command(&session, json!({"op":"status"}))?)
                .map_err(|_| "InvalidData")?;
            if status["unlocked"] != true {
                return Err("Locked".into());
            }
            let options = Zeroizing::new(options);
            let o: Value = serde_json::from_str(&options).map_err(|_| "InvalidData")?;
            let config = &o["config"];
            vault_core::webdav::base_url(config).map_err(dav_error)?;
            let config_json = Zeroizing::new(config.to_string());
            match o["action"].as_str().unwrap_or("") {
                "save" => command(
                    &session,
                    json!({"op":"settings","settings":{"webdav":config}}),
                ),
                "list" => vault_core::webdav_list(config_json.to_string()).map_err(dav_error),
                "upload" => {
                    let content = archive(&session, o["password"].as_str().ok_or("InvalidData")?)?;
                    let name = format!("PasswordVault-{}.pvbackup", uuid::Uuid::new_v4());
                    vault_core::webdav_upload(
                        config_json.to_string(),
                        name.clone(),
                        content.into_bytes(),
                    )
                    .map_err(dav_error)?;
                    Ok(json!({"name":name}).to_string())
                }
                "restore" => {
                    let url = o["url"].as_str().ok_or("InvalidData")?.to_string();
                    let data = Zeroizing::new(
                        vault_core::webdav_download(config_json.to_string(), url)
                            .map_err(dav_error)?,
                    );
                    merge(&session, &data, o["password"].as_str().unwrap_or(""))
                }
                _ => Err("InvalidData".into()),
            }
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn backup_archive_round_trip_wrong_password_and_settings() {
        let root = std::env::temp_dir().join(format!("pv-backup-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let source =
            crate::session::VaultSession::new(root.join("source").to_string_lossy().into())
                .unwrap();
        let destination =
            crate::session::VaultSession::new(root.join("destination").to_string_lossy().into())
                .unwrap();
        for s in [&source, &destination] {
            command(s, json!({"op":"create","password":"synthetic-master"})).unwrap();
        }
        command(&source,json!({"op":"save","item":{"id":"fixture","type":"password","title":"Synthetic","username":"example","password":"synthetic-secret"},"richNotes":true})).unwrap();
        command(&source,json!({"op":"settings","settings":{"webdav":{"url":"https://example.test/","username":"synthetic-user","password":"synthetic-dav-secret","folder":"backups"}}})).unwrap();
        let bytes = archive(&source, "synthetic-backup-password").unwrap();
        assert!(!bytes.contains("synthetic-dav-secret"));
        assert!(merge(&destination, bytes.as_bytes(), "wrong").is_err());
        let before: Value = serde_json::from_str(
            &command(&destination, json!({"op":"list","richNotes":true})).unwrap(),
        )
        .unwrap();
        assert!(before["items"].as_array().unwrap().is_empty());
        merge(&destination, bytes.as_bytes(), "synthetic-backup-password").unwrap();
        let after: Value = serde_json::from_str(
            &command(&destination, json!({"op":"list","richNotes":true})).unwrap(),
        )
        .unwrap();
        assert_eq!(after["items"][0]["title"], "Synthetic");
        let file = root.join("archive.pvbackup");
        write_new(&file, bytes.as_bytes()).unwrap();
        assert!(write_new(&file, b"replacement").is_err());
        assert_eq!(&*read(file.to_str().unwrap()).unwrap(), bytes.as_bytes());
        assert!(limited(&b"12345"[..], 4).is_err());
        drop(source);
        drop(destination);
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[cfg(test)]
mod import_tests {
    use super::*;
    #[test]
    fn backup_review_masks_secrets_rejects_changed_source_and_skips_duplicates() {
        let root = std::env::temp_dir().join(format!("pv-import-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let session =
            crate::session::VaultSession::new(root.join("vault").to_string_lossy().into()).unwrap();
        command(
            &session,
            json!({"op":"create","password":"synthetic-master"}),
        )
        .unwrap();
        let path = root.join("source.csv");
        let path = path.to_str().unwrap();
        let source = "name,username,password,url\nExample,test,synthetic-secret,https://example.test\nExample,test,synthetic-secret,https://example.test\n";
        std::fs::write(path, source).unwrap();
        let preview = structured_file(
            &session,
            path,
            &json!({"op":"import-preview","format":"csv"}).to_string(),
        )
        .unwrap();
        assert!(!preview.contains("synthetic-secret"));
        let preview: Value = serde_json::from_str(&preview).unwrap();
        assert_eq!(preview["rows"].as_array().unwrap().len(), 2);
        assert!(
            !preview["rows"][1]["duplicateIds"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        let options =
            json!({"op":"import-commit","format":"csv","fingerprint":preview["fingerprint"]})
                .to_string();
        std::fs::write(path, source.replace("Example", "Changed")).unwrap();
        assert_eq!(
            structured_file(&session, path, &options).unwrap_err(),
            "StaleEdit"
        );
        std::fs::write(path, source).unwrap();
        structured_file(&session, path, &options).unwrap();
        let doc: Value = serde_json::from_str(
            &command(&session, json!({"op":"list","richNotes":true})).unwrap(),
        )
        .unwrap();
        assert_eq!(doc["items"].as_array().unwrap().len(), 1);
        drop(session);
        std::fs::remove_dir_all(root).unwrap();
    }
}
