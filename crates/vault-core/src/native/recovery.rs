//! Recovery envelopes are independent of the master-password header.
use super::*;
use crate::recovery::RecoveryEnvelope;

impl DiskVault {
    fn recovery_envelope(&self) -> Result<RecoveryEnvelope> {
        let path = self.directory.join("recovery.json");
        if storage(fs::metadata(&path))?.len() > 16384 {
            return Err(VaultError::InvalidData);
        }
        serde_json::from_slice(&storage(fs::read(path))?).map_err(|_| VaultError::InvalidData)
    }

    pub(super) fn recovery_command(&mut self, request: &Value) -> Result<Value> {
        let string = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        match string("op")? {
            "recovery-generate" => {
                self.open()?;
                Ok(json!({"key":generate_recovery_key()}))
            }
            "recovery-status" => {
                self.open()?;
                let enabled = match fs::metadata(self.directory.join("recovery.json")) {
                    Ok(_) => {
                        let envelope = self.recovery_envelope()?;
                        envelope.aad()?;
                        if envelope.vault_id != self.open()?.header.vault_id {
                            return Err(VaultError::Authentication);
                        }
                        true
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
                    Err(_) => return Err(VaultError::Storage),
                };
                Ok(json!({"enabled":enabled}))
            }
            "recovery-enable" => {
                let open = self.open()?;
                open.header.unlock(string("currentPassword")?)?;
                let envelope = RecoveryEnvelope::create(
                    string("key")?,
                    &open.root,
                    open.header.vault_id.clone(),
                )?;
                atomic_write(
                    &self.directory.join("recovery.json"),
                    &serde_json::to_vec(&envelope).map_err(|_| VaultError::InvalidData)?,
                )?;
                Ok(json!({"ok":true}))
            }
            "recovery-disable" => {
                self.open()?.header.unlock(string("currentPassword")?)?;
                match fs::remove_file(self.directory.join("recovery.json")) {
                    Ok(()) => storage(crate::native_file_ops::sync_directory(&self.directory))?,
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
                    Err(_) => return Err(VaultError::Storage),
                }
                Ok(json!({"ok":true}))
            }
            "recovery-export" => {
                let key = normalize_recovery_key(string("key")?)?;
                let envelope = self.recovery_envelope()?;
                let open = self.open()?;
                let root = envelope.unlock(&key, &open.header.vault_id)?;
                if root.as_ref() != open.root.as_ref() {
                    return Err(VaultError::Authentication);
                }
                Ok(json!({"content":self.archive(&key)?}))
            }
            "recovery-restore-backup" => {
                if self.directory.exists() {
                    return Err(VaultError::AlreadyExists);
                }
                let key = normalize_recovery_key(string("key")?)?;
                self.import_archive(string("content")?, &key, Some(string("newPassword")?))
            }
            "recovery-reset-password" => {
                // Authenticate both envelope and database before replacing any header bytes.
                if self.unlocked.is_some() {
                    return Err(VaultError::InvalidData);
                }
                let header = self.header()?;
                let root = self
                    .recovery_envelope()?
                    .unlock(string("key")?, &header.vault_id)?;
                let connection = open_database(&self.directory.join("vault.sqlite"), &root, false)?;
                let document = load_document(&connection, &root, &header.vault_id)?;
                let next = Header::create(string("newPassword")?, &root, header.vault_id)?;
                atomic_write(
                    &self.directory.join("header.json"),
                    &serde_json::to_vec(&next).map_err(|_| VaultError::InvalidData)?,
                )?;
                self.unlocked = Some(OpenVault {
                    connection,
                    root,
                    header: next,
                    document,
                });
                Ok(json!({"ok":true}))
            }
            _ => Err(VaultError::Unsupported),
        }
    }
}
