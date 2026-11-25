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
        note_blobs::copy_blobs_dir(&self.directory, temp.path())?;
        storage(fs::rename(temp.path(), &destination))?;
        storage(crate::native_file_ops::sync_directory(&self.directory))?;
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
                    let mut preview = preview;
                    redact_import_preview(&mut preview);
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
            // CXF carries plaintext private keys: always reauthenticate the vault header.
            "export-cxf" => {
                let open = self.open()?;
                let verified = open.header.unlock(text("currentPassword")?)?;
                if verified.as_ref() != open.root.as_ref() {
                    return Err(VaultError::Authentication);
                }
                let personal = open.document.clone();
                let hydrated = note_bodies::hydrate(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    personal,
                )?;
                let exported = cxf_export(&hydrated, "com.securepass.vault", "PasswordVault")?;
                Ok(
                    json!({"content":serde_json::to_string(&exported).map_err(|_| VaultError::InvalidData)?,"skipped":exported["skipped"]}),
                )
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

const BREACH_ENDPOINT: &str = "https://api.pwnedpasswords.com/range/";
const BREACH_MAX_RESPONSE: u64 = 4 * 1024 * 1024;

fn valid_breach_prefix(prefix: &str) -> bool {
    prefix.len() == 5
        && prefix
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(&b))
}

/// Opt-in Have I Been Pwned k-anonymity range lookup shared by Desktop, iOS and Android.
/// Sends only the 5-character uppercase hex SHA-1 prefix over HTTPS without redirects
/// and without holding the vault session lock.
#[uniffi::export]
pub fn breach_range(prefix: String) -> Result<String> {
    use std::io::Read;
    use std::time::Duration;

    if !valid_breach_prefix(&prefix) {
        return Err(VaultError::InvalidData);
    }
    let client = reqwest::blocking::Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|_| VaultError::Storage)?;
    let response = client
        .get(format!("{BREACH_ENDPOINT}{prefix}"))
        .header("Add-Padding", "true")
        .send()
        .map_err(|_| VaultError::Storage)?;
    if response.status() != reqwest::StatusCode::OK {
        return Err(VaultError::Storage);
    }
    let mut body = String::new();
    response
        .take(BREACH_MAX_RESPONSE + 1)
        .read_to_string(&mut body)
        .map_err(|_| VaultError::Storage)?;
    if body.len() as u64 > BREACH_MAX_RESPONSE {
        return Err(VaultError::InvalidData);
    }
    Ok(body)
}

#[cfg(test)]
mod breach_tests {
    use super::{breach_range, valid_breach_prefix};
    use crate::VaultError;

    #[test]
    fn only_five_uppercase_hex_digits_are_sent() {
        assert!(valid_breach_prefix("21BD1"));
        assert!(valid_breach_prefix("00000"));
        for bad in ["21bd1", "21BD", "21BD12", "21BG1", "", "../x1", "21BD1/"] {
            assert!(!valid_breach_prefix(bad), "{bad}");
            assert!(matches!(
                breach_range(bad.into()),
                Err(VaultError::InvalidData)
            ));
        }
    }
}
