//! Transactional structured-record imports and local security controls.
use super::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use std::collections::BTreeMap;

impl DiskVault {
    /// Called before the first successful incompatible mutation; copies encrypted files only.
    /// The directory lock and session mutex prevent competing writes during the snapshot.
    pub(super) fn prepare_capability_upgrade(&mut self) -> Result<()> {
        if self.open()?.document.format_version >= 6 {
            return Ok(());
        }
        let destination = self.directory.join("before-capability-format6");
        if destination.exists() {
            return Ok(());
        }
        let temp = storage(
            tempfile::Builder::new()
                .prefix(".capability-backup-")
                .tempdir_in(&self.directory),
        )?;
        protect_dir(temp.path())?;
        for name in ["header.json", "vault.sqlite", "recovery.json"] {
            let bytes = match fs::read(self.directory.join(name)) {
                Ok(bytes) => bytes,
                Err(error)
                    if name == "recovery.json" && error.kind() == std::io::ErrorKind::NotFound =>
                {
                    continue
                }
                Err(_) => return Err(VaultError::Storage),
            };
            atomic_write(&temp.path().join(name), &bytes)?;
        }
        storage(fs::rename(temp.path(), &destination))?;
        storage(File::open(&self.directory).and_then(|f| f.sync_all()))?;
        Ok(())
    }

    pub(super) fn capability_command(&mut self, request: &Value) -> Result<Value> {
        self.open()?;
        let text = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        match text("op")? {
            "import-preview" | "import-commit" => {
                let source = Zeroizing::new(
                    STANDARD
                        .decode(text("data")?)
                        .map_err(|_| VaultError::InvalidData)?,
                );
                let mapping: BTreeMap<String, String> =
                    serde_json::from_value(request.get("mapping").cloned().unwrap_or(json!({})))
                        .map_err(|_| VaultError::InvalidData)?;
                let preview =
                    preview_import(text("format")?, &source, &mapping, &self.open()?.document)?;
                if request["op"] == "import-preview" {
                    return serde_json::to_value(preview).map_err(|_| VaultError::InvalidData);
                }
                let choices: BTreeMap<usize, String> =
                    serde_json::from_value(request.get("choices").cloned().unwrap_or(json!({})))
                        .map_err(|_| VaultError::InvalidData)?;
                // Validate choices and every item before creating the migration snapshot.
                let mut next = self.open()?.document.clone();
                let result = apply_import(&mut next, preview, &choices)?;
                if next.format_version >= 6 {
                    self.prepare_capability_upgrade()?;
                }
                self.mutate(|doc| {
                    *doc = next;
                    Ok(result)
                })
            }
            "security-audit" => {
                let document = &self.open()?.document;
                security_audit(document, document.settings.get("securityCatalog"))
            }
            "security-ignore" => {
                let ignored = request["ignored"]
                    .as_bool()
                    .ok_or(VaultError::InvalidData)?;
                self.mutate(|document| {
                    set_security_ignored(document, text("key")?, ignored)?;
                    Ok(json!({"ok":true}))
                })
            }
            "security-catalog" => {
                let catalog = &request["catalog"];
                if serde_json::to_vec(catalog)
                    .map_err(|_| VaultError::InvalidData)?
                    .len()
                    > 8 * 1024 * 1024
                {
                    return Err(VaultError::InvalidData);
                }
                validate_security_catalog(catalog)?;
                self.mutate(|document| {
                    document.settings["securityCatalog"] = catalog.clone();
                    Ok(json!({"ok":true}))
                })
            }
            "breach-request" => Ok(breach_request(text("password")?)),
            "breach-response" => {
                Ok(json!({"count":breach_response(text("suffix")?,text("response")?)?}))
            }
            _ => Err(VaultError::Unsupported),
        }
    }
}
