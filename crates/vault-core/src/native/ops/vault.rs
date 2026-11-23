//! `vault` ops (see `contract/commands.json`): Vault lifecycle: create, unlock/lock, settings, password and background grants.
//! Routed from `DiskVault::command` after the shared checks (registry, lock, format guards).
use super::super::*;

impl DiskVault {
    pub(in crate::native) fn vault_ops(&mut self, op: &str, request: &Value) -> Result<Value> {
        let string = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        match op {
            "status" => Ok(
                json!({"exists":self.directory.exists(),"unlocked":self.unlocked.is_some(),"version":2}),
            ),
            "create" => {
                self.create(string("password")?)?;
                Ok(json!({"ok":true}))
            }
            "create-migrated" => {
                let document = crate::legacy_database::read_legacy_database(
                    Path::new(string("source")?),
                    string("legacyPassword")?,
                    string("salt")?,
                )?;
                let count = document.items.len();
                self.create_document(string("password")?, document)?;
                Ok(json!({"imported": count}))
            }
            "unlock" => {
                self.unlock(string("password")?)?;
                Ok(json!({"ok":true}))
            }
            "lock" => {
                self.lock();
                Ok(json!({"ok":true}))
            }
            "settings" => self.mutate(|doc| {
                update_settings(doc, &request["settings"])?;
                Ok(json!({"ok":true}))
            }),
            "revoke-background" => {
                self.open()?;
                let base = self.directory.parent().ok_or(VaultError::Storage)?;
                revoke_background_grants(base.to_string_lossy().into_owned())?;
                Ok(json!({"ok":true}))
            }
            "change-password" => {
                let open = self.open()?;
                let validated = open.header.unlock(string("currentPassword")?)?;
                if validated.as_ref() != open.root.as_ref() {
                    return Err(VaultError::Authentication);
                }
                let new_header = Header::create(
                    string("newPassword")?,
                    &open.root,
                    open.header.vault_id.clone(),
                )?;
                let bytes = serde_json::to_vec(&new_header).map_err(|_| VaultError::InvalidData)?;
                atomic_write(&self.directory.join("header.json"), &bytes)?;
                self.open()?.header = new_header;
                Ok(json!({"ok":true}))
            }
            _ => Err(VaultError::Unsupported),
        }
    }
}
