//! UI facade: only the background service opens a vault on macOS.
#[cfg(any(not(target_os = "macos"), not(feature = "ui"), test))]
pub use vault_core::VaultSession;
#[cfg(all(target_os = "macos", feature = "ui", not(test)))]
mod remote {
    use base64::{Engine, engine::general_purpose::STANDARD};
    use serde_json::{Value, json};
    use std::path::PathBuf;
    use vault_core::{Result, VaultError};
    pub struct VaultSession {
        directory: PathBuf,
        local: Option<vault_core::VaultSession>,
    }
    impl VaultSession {
        pub fn new(directory: String) -> Result<Self> {
            let path = PathBuf::from(&directory);
            let local = if std::env::var_os("PV_ALLOW_LOCAL_SESSION").is_some() {
                let canonical = path.canonicalize().map_err(|_| VaultError::InvalidData)?;
                if !(canonical.starts_with("/private/tmp") || canonical.starts_with("/tmp")) {
                    return Err(VaultError::InvalidData);
                }
                Some(vault_core::VaultSession::new(directory.clone())?)
            } else {
                None
            };
            let this = Self {
                directory: path,
                local,
            };
            if this.local.is_none() {
                crate::service_ipc::resume_directory(&this.directory)
                    .map_err(|_| VaultError::Storage)?;
            }
            this.invoke("ping", json!({}))?;
            Ok(this)
        }
        fn invoke(&self, method: &str, args: Value) -> Result<Value> {
            if let Some(local) = &self.local {
                let text = |name: &str| {
                    args[name]
                        .as_str()
                        .map(str::to_owned)
                        .ok_or(VaultError::InvalidData)
                };
                let bytes = |name: &str| {
                    serde_json::from_value::<Vec<u8>>(args[name].clone())
                        .map_err(|_| VaultError::InvalidData)
                };
                return match method {
                    "ping" => Ok(json!(true)),
                    "command" => local.command(text("request")?).map(Value::String),
                    "unlock-biometric" => {
                        local.unlock_biometric(bytes("key")?).map(|_| Value::Null)
                    }
                    "biometric-key" => local.biometric_key().map(|key| json!(STANDARD.encode(key))),
                    "attachment-import" => local
                        .import_note_attachment(
                            text("noteId")?,
                            text("name")?,
                            text("mime")?,
                            STANDARD
                                .decode(text("data")?)
                                .map_err(|_| VaultError::InvalidData)?,
                        )
                        .map(Value::String),
                    "attachment-read" => local
                        .read_note_attachment(text("noteId")?, text("id")?)
                        .map(|data| json!(STANDARD.encode(data))),
                    "attachment-import-file" => local
                        .import_note_attachment_file(
                            text("noteId")?,
                            text("path")?,
                            text("name")?,
                            text("mime")?,
                        )
                        .map(Value::String),
                    "attachment-export-file" => local
                        .export_note_attachment_file(
                            text("noteId")?,
                            text("id")?,
                            text("destPath")?,
                            args["readonly"] == true,
                        )
                        .map(Value::String),
                    "attachment-discard" => local
                        .discard_note_attachment(text("noteId")?, text("id")?)
                        .map(|_| Value::Null),
                    _ => Err(VaultError::Unsupported),
                };
            }
            crate::service_ipc::control(&self.directory, method, args).map_err(|code| {
                match code.as_str() {
                    "Locked" => VaultError::Locked,
                    "Authentication" => VaultError::Authentication,
                    "InvalidData" => VaultError::InvalidData,
                    "AlreadyExists" => VaultError::AlreadyExists,
                    "InUse" => VaultError::InUse,
                    "StaleEdit" => VaultError::StaleEdit,
                    "Unsupported" => VaultError::Unsupported,
                    "UpdateRequired" => VaultError::UpdateRequired,
                    "DevicesUpgradeRequired" => VaultError::DevicesUpgradeRequired,
                    "DevicesSyncBlocked" => VaultError::DevicesSyncBlocked,
                    _ => VaultError::Storage,
                }
            })
        }
        fn string(&self, method: &str, args: Value) -> Result<String> {
            match self.invoke(method, args)? {
                Value::String(text) => Ok(text),
                _ => Err(VaultError::InvalidData),
            }
        }
        pub fn command(&self, request: String) -> Result<String> {
            self.string("command", json!({"request":request}))
        }
        #[allow(dead_code)] // Used by pv-background browser bridge.
        pub fn authorized_browser_command(
            &self,
            grant: Vec<u8>,
            request: String,
        ) -> Result<String> {
            self.string(
                "authorized-browser",
                json!({"grant":grant,"request":request}),
            )
        }
        #[allow(dead_code)] // Used by pv-background browser bridge.
        pub fn background_save(&self, grant: Vec<u8>, request: String) -> Result<String> {
            self.string("background-save", json!({"grant":grant,"request":request}))
        }
        #[allow(dead_code)] // Used by pv-background auto-unlock.
        pub fn unlock_desktop_grant(&self, grant: Vec<u8>) -> Result<()> {
            self.invoke("unlock-grant", json!({"grant":grant}))
                .map(|_| ())
        }
        pub fn unlock_biometric(&self, key: Vec<u8>) -> Result<()> {
            self.invoke("unlock-biometric", json!({"key":key}))
                .map(|_| ())
        }
        pub fn biometric_key(&self) -> Result<Vec<u8>> {
            STANDARD
                .decode(zeroize::Zeroizing::new(
                    self.string("biometric-key", json!({}))?,
                ))
                .map_err(|_| VaultError::InvalidData)
        }
        #[allow(dead_code)] // Kept for small-buffer attachment tests and compatibility.
        pub fn import_note_attachment(
            &self,
            note_id: String,
            name: String,
            mime: String,
            data: Vec<u8>,
        ) -> Result<String> {
            self.string(
                "attachment-import",
                json!({"noteId":note_id,"name":name,"mime":mime,"data":STANDARD.encode(&data)}),
            )
        }
        pub fn read_note_attachment(&self, note_id: String, id: String) -> Result<Vec<u8>> {
            STANDARD
                .decode(self.string("attachment-read", json!({"noteId":note_id,"id":id}))?)
                .map_err(|_| VaultError::InvalidData)
        }
        pub fn import_note_attachment_file(
            &self,
            note_id: String,
            path: String,
            name: String,
            mime: String,
        ) -> Result<String> {
            self.string(
                "attachment-import-file",
                json!({"noteId":note_id,"path":path,"name":name,"mime":mime}),
            )
        }
        pub fn export_note_attachment_file(
            &self,
            note_id: String,
            id: String,
            dest_path: String,
            readonly: bool,
        ) -> Result<String> {
            self.string(
                "attachment-export-file",
                json!({"noteId":note_id,"id":id,"destPath":dest_path,"readonly":readonly}),
            )
        }
        pub fn discard_note_attachment(&self, note_id: String, id: String) -> Result<()> {
            self.invoke("attachment-discard", json!({"noteId":note_id,"id":id}))
                .map(|_| ())
        }
    }
}
#[cfg(all(target_os = "macos", feature = "ui", not(test)))]
pub use remote::VaultSession;
