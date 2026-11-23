//! `backup` ops (see `contract/commands.json`): Backup export/import and creation from a backup archive.
//! Routed from `DiskVault::command` after the shared checks (registry, lock, format guards).
use super::super::*;

impl DiskVault {
    pub(in crate::native) fn backup_ops(&mut self, op: &str, request: &Value) -> Result<Value> {
        let string = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        match op {
            "create-from-backup" => {
                if string("content")?.contains("\"PasswordVaultArchive\"") {
                    if request["richNotes"] != true {
                        return Err(VaultError::Unsupported);
                    }
                    return self.import_archive(
                        string("content")?,
                        request["backupPassword"].as_str().unwrap_or(""),
                        Some(string("password")?),
                    );
                }
                let document = import_document(
                    string("content")?,
                    request["backupPassword"].as_str().unwrap_or(""),
                    request["kind"].as_str().unwrap_or("json"),
                )?;
                if document.format_version >= 3 {
                    return Err(VaultError::Unsupported);
                }
                let count = document.items.len();
                self.create_document(string("password")?, document)?;
                Ok(json!({"imported": count}))
            }
            "export" => {
                if self.open()?.document.format_version >= 3 {
                    if request["richNotes"] != true {
                        return Err(VaultError::Unsupported);
                    }
                    return Ok(json!({"content":self.archive(string("password")?)?}));
                }
                let open = self.open()?;
                let hydrated = note_bodies::hydrate(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    open.document.clone(),
                )?;
                let data = Zeroizing::new(
                    serde_json::to_vec(&hydrated).map_err(|_| VaultError::InvalidData)?,
                );
                Ok(json!({"content":encrypt_backup(&data,string("password")?)?}))
            }
            "export-csv-backup" => {
                if self.open()?.document.format_version >= 3 {
                    return Err(VaultError::Unsupported);
                }
                let open = self.open()?;
                let hydrated = note_bodies::hydrate(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    open.document.clone(),
                )?;
                let csv = Zeroizing::new(export_csv(&hydrated)?);
                let envelope: Value =
                    serde_json::from_str(&encrypt_backup(csv.as_bytes(), string("password")?)?)
                        .map_err(|_| VaultError::InvalidData)?;
                Ok(
                    json!({"content":json!({"format":"PasswordVaultCSVBackup","version":1,"envelope":envelope}).to_string()}),
                )
            }
            "export-plain" => {
                if self.open()?.document.format_version >= 3 {
                    return Err(VaultError::Unsupported);
                }
                let open = self.open()?;
                let hydrated = note_bodies::hydrate(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    open.document.clone(),
                )?;
                let content = if request["kind"] == "csv" {
                    export_csv(&hydrated)?
                } else {
                    serde_json::to_string(&hydrated).map_err(|_| VaultError::InvalidData)?
                };
                Ok(json!({"content":content}))
            }
            "import" => {
                self.open()?;
                if string("content")?.contains("\"PasswordVaultArchive\"") {
                    if request["richNotes"] != true {
                        return Err(VaultError::Unsupported);
                    }
                    return self.import_archive(
                        string("content")?,
                        request["password"].as_str().unwrap_or(""),
                        None,
                    );
                }
                let incoming = import_document(
                    string("content")?,
                    request["password"].as_str().unwrap_or(""),
                    request["kind"].as_str().unwrap_or("json"),
                )?;
                if incoming.format_version >= 3 {
                    return Err(VaultError::Unsupported);
                }
                self.mutate(|doc| Ok(json!({"imported":doc.merge(incoming)?})))
            }
            _ => Err(VaultError::Unsupported),
        }
    }
}
