//! PasswordVault Desktop (Native Shell): the native layer that the TSX
//! interface imports from `passwordvault/native`.
//!
//! The encrypted vault stays in `vault-core`. TSX only sends JSON commands and
//! receives the results it displays; keys, the database and file access remain
//! in Rust.

mod ai;
mod relay;
mod platform;
#[cfg(target_os = "macos")]
mod browser;
#[cfg(not(target_os = "macos"))]
#[path = "windows/browser.rs"]
mod browser;
mod qa_window;
mod data_dir;
pub use data_dir::data_directory_name;
mod hotkey;
mod window_ctl;

mod attachments;
mod markdown;
mod rich_notes;
mod recovery_io;
mod files;
#[cfg(target_os = "macos")]
mod script_runner;
#[cfg(not(target_os = "macos"))]
#[path = "windows/scripts.rs"]
mod script_runner;
mod qr_import;
mod backup;

use nsh_core::prelude::*;
use std::path::PathBuf;
use std::sync::Arc;
use vault_core::VaultSession;
use zeroize::Zeroizing;

#[native_module("passwordvault/native")]
fn native(registry: &mut Registry) {
    rich_notes::register(registry);
    registry.module::<script_runner::Scripts>();
    registry.module::<qr_import::QrImport>();
    registry.module::<markdown::NoteMarkdown>();
    registry.module::<browser::Browser>();
    registry.module::<ai::Ai>();
    registry.module::<relay::Relay>();
    registry.module::<recovery_io::RecoveryIO>();
    registry.module::<hotkey::Hotkey>();
    registry.module::<window_ctl::WindowCtl>();
    registry.module::<backup::Backup>().module::<files::Files>().module::<attachments::Attachments>().class::<Vault>().module::<Platform>();
}

/// Data directory used when no explicit directory is given. It is separate from
/// the SwiftUI app's `PasswordVaultNative` directory so the preview never opens
/// a production vault by accident.

fn vault_directory() -> PathBuf {
    let mut args = std::env::args();
    while let Some(arg) = args.next() {
        if arg == "--vault-directory" {
            if let Some(path) = args.next() {
                return PathBuf::from(path);
            }
        }
    }
    if let Ok(path) = std::env::var("PASSWORDVAULT_VAULT_DIRECTORY") {
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }
    data_dir::default_vault_directory()
}

fn error_code(error: vault_core::VaultError) -> String {
    format!("{error:?}")
}

/// The encrypted vault: one session for the app's lifetime.
#[class]
pub struct Vault {
    directory: PathBuf,
    session: Option<Arc<VaultSession>>,
}

#[class]
impl Vault {
    /// Opens the vault directory (it is created on first use).
    pub fn new() -> Self {
        qa_window::place_for_qa();
        Vault { directory: vault_directory(), session: None }
    }

    /// The vault directory on disk.
    #[getter]
    pub fn directory(&self) -> String {
        self.directory.to_string_lossy().into_owned()
    }

    /// Checks hardware/enrollment without prompting.
    pub fn biometric_available() -> bool { platform::available() }

    /// Reports whether this preview vault has an enrolled Keychain credential.
    pub fn biometric_enabled(&self) -> Result<bool, String> { platform::enabled(&self.directory) }

    /// Reauthenticates with the master password before storing a native-only key.
    pub async fn biometric_enable(this: Instance<Vault>, password: String) -> Result<(), String> {
        let (directory, session) = this.with(|v| (v.directory.clone(), v.session.clone()));
        let session = session.ok_or("Locked")?;
        blocking(move || {
            let key = platform::verify_enrollment(&session, &directory, password)?;
            platform::enroll(&directory, &key)
        }).await.map_err(|_| "Storage".to_string())?
    }

    /// Removes only this preview vault's credential.
    pub async fn biometric_disable(this: Instance<Vault>) -> Result<(), String> {
        let directory = this.with(|v| v.directory.clone());
        blocking(move || platform::remove(&directory)).await.map_err(|_| "Storage".to_string())?
    }

    /// Authenticates through Keychain and unlocks without exposing the key to JS.
    pub async fn unlock_with_biometrics(this: Instance<Vault>) -> Result<(), String> {
        let (directory, session) = this.with(|v| (v.directory.clone(), v.session.clone()));
        let session = session.ok_or("Locked")?;
        blocking(move || {
            let key = platform::retrieve(&directory)?;
            session.unlock_biometric(key.to_vec()).map_err(error_code)
        }).await.map_err(|_| "Storage".to_string())?
    }

    /// Runs one JSON command (`{"op":"list"}`) on a background thread; resolves with
    /// the JSON result. Rejects with the error code: `Locked`, `Authentication`,
    /// `InvalidData`, `AlreadyExists`, `InUse`, `Storage`, `StaleEdit` or `Unsupported`.
    pub async fn command(this: Instance<Vault>, request: String) -> Result<String, String> {
        let session = match this.with(|vault| vault.session.clone()) {
            Some(session) => session,
            None => {
                let directory = this.with(|vault| vault.directory.clone());
                let session = blocking(move || shared_session(&directory))
                    .await
                    .map_err(|_| "Storage".to_string())??;
                this.with_mut(|vault| vault.session = Some(session.clone()));
                session
            }
        };
        let request = Zeroizing::new(with_rich_notes(request)?);
        blocking(move || session.command(request.to_string()))
            .await
            .map_err(|_| "Storage".to_string())?
            .map_err(error_code)
    }
}

/// One session per vault directory and process: the session holds the vault's
/// process lock, and an interface reloaded in the same process (development
/// reloads, test engines) must not see its own earlier instance as "in use".
/// An instance that adopts a live session locks it first, so every interface
/// starts at the lock screen.
fn shared_session(directory: &std::path::Path) -> Result<Arc<VaultSession>, String> {
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock, Weak};
    static SESSIONS: OnceLock<Mutex<HashMap<PathBuf, Weak<VaultSession>>>> = OnceLock::new();
    let mut sessions = SESSIONS.get_or_init(Default::default).lock().map_err(|_| "Storage".to_string())?;
    if let Some(session) = sessions.get(directory).and_then(Weak::upgrade) {
        session.command(r#"{"op":"lock"}"#.into()).map_err(error_code)?;
        return Ok(session);
    }
    if let Some(parent) = directory.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let session = Arc::new(VaultSession::new(directory.to_string_lossy().into_owned()).map_err(error_code)?);
    sessions.insert(directory.to_path_buf(), Arc::downgrade(&session));
    Ok(session)
}

/// Adds `richNotes: true`, as the native clients do, so rich notes are preserved.
fn with_rich_notes(request: String) -> Result<String, String> {
    let request = Zeroizing::new(request);
    let mut value: serde_json::Value =
        serde_json::from_str(&request).map_err(|_| "InvalidData".to_string())?;
    value
        .as_object_mut()
        .ok_or_else(|| "InvalidData".to_string())?
        .insert("richNotes".into(), serde_json::Value::Bool(true));
    let out = serde_json::to_string(&value).map_err(|_| "InvalidData".to_string());
    if let Some(object) = value.as_object_mut() {
        object.clear();
    }
    out
}

/// Desktop services the shared interface uses.
#[module]
pub struct Platform;

#[module]
impl Platform {
    /// Platform capability gating; unavailable integrations never report success.
    pub fn is_macos() -> bool { cfg!(target_os = "macos") }
    /// Integrations enabled in this build; unsupported transports remain closed.
    pub fn capabilities() -> String {
        let mac = cfg!(target_os = "macos");
        serde_json::json!({"browser":mac,"ai":mac,"terminal":mac,"globalHotkeys":mac,"recoveryPrinting":mac}).to_string()
    }
    /// Drains system lock notifications and returns system idle seconds.
    pub fn poll_lock_signals() -> String { platform::poll() }

    /// The app's version as shown next to its name.
    pub fn version() -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }

    /// Shows `path` selected in the system file manager.
    pub fn reveal(path: String) -> bool {
        platform::reveal(&path)
    }

    /// Opens the vault's folder in the system file manager (its files stay encrypted).
    pub fn open_vault_folder() -> bool {
        let dir = vault_directory();
        platform::open_folder(dir.parent().unwrap_or(&dir))
    }
}
