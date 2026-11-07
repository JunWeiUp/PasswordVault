//! Signed-helper socket and explicit preview registration. No auto-registration.
mod security;
mod wire;
use crate::Vault;
use nsh_core::prelude::*;
use serde_json::{Value, json};
use std::{
    os::unix::{fs::PermissionsExt, io::AsRawFd, net::UnixListener},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};
struct Pending {
    id: String,
    challenge: String,
    reply: std::sync::mpsc::SyncSender<bool>,
}
static STARTUP: Mutex<Option<String>> = Mutex::new(None);
static PENDING: Mutex<Option<Pending>> = Mutex::new(None);
static STARTED: OnceLock<Mutex<Vec<PathBuf>>> = OnceLock::new();
fn command(session: &vault_core::VaultSession, request: Value) -> Result<Value, String> {
    serde_json::from_str(
        &session
            .command(request.to_string())
            .map_err(crate::error_code)?,
    )
    .map_err(|_| "failed".into())
}
fn settings(session: &vault_core::VaultSession) -> Result<Value, String> {
    Ok(command(session, json!({"op":"list","richNotes":true}))?["settings"].clone())
}
fn dispatch(session: &vault_core::VaultSession, id: &str, wrapper: Value) -> Result<Value, String> {
    if wrapper["extensionOrigin"] != format!("chrome-extension://{id}/") {
        return Err("invalid-origin".into());
    }
    let request = &wrapper["request"];
    if request["version"] != 2 {
        return Err("invalid-request".into());
    }
    let op = request["op"].as_str().unwrap_or("");
    if op == "desktop-auto-unlock" {
        use base64::Engine;
        let mut startup = STARTUP.lock().map_err(|_| "unavailable")?;
        let expected = startup.take();
        if expected.as_deref() != request["nonce"].as_str() || expected.is_none() {
            return Err("sync-authorization".into());
        }
        let grant = zeroize::Zeroizing::new(
            base64::engine::general_purpose::STANDARD
                .decode(
                    request["_backgroundGrant"]
                        .as_str()
                        .ok_or("sync-authorization")?,
                )
                .map_err(|_| "sync-authorization")?,
        );
        session
            .unlock_desktop_grant(grant.to_vec())
            .map_err(|_| "sync-authorization")?;
        return Ok(json!({"ok":true}));
    }
    let current = settings(session);
    if op == "status" {
        return Ok(
            json!({"ok":true,"version":2,"unlocked":current.is_ok(),"paired":current.as_ref().is_ok_and(|s|wire::paired(s,id,request["token"].as_str().unwrap_or("")))}),
        );
    }
    if matches!(op, "sync-save" | "authorized-matches" | "authorized-fill") {
        use base64::Engine;
        let grant = zeroize::Zeroizing::new(
            base64::engine::general_purpose::STANDARD
                .decode(
                    request["_backgroundGrant"]
                        .as_str()
                        .ok_or("sync-authorization")?,
                )
                .map_err(|_| "sync-authorization")?,
        );
        let mut query = request.clone();
        query.as_object_mut().unwrap().remove("_backgroundGrant");
        let output = if op == "sync-save" {
            session.background_save(grant.to_vec(), query.to_string())
        } else {
            query["op"] = op.trim_start_matches("authorized-").into();
            session.authorized_browser_command(grant.to_vec(), query.to_string())
        }
        .map_err(|_| "sync-authorization")?;
        return Ok(
            json!({"ok":true,"data":serde_json::from_str::<Value>(&output).map_err(|_|"failed")?}),
        );
    }
    let mut current = current.map_err(|_| "locked")?;
    if op == "pair" {
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        {
            let mut pending = PENDING.lock().map_err(|_| "unavailable")?;
            if pending.is_some() {
                return Err("pairing-busy".into());
            }
            *pending = Some(Pending {
                id: id.into(),
                challenge: uuid::Uuid::new_v4().to_string(),
                reply: tx,
            });
        }
        let allowed = rx.recv_timeout(Duration::from_secs(35)).unwrap_or(false);
        PENDING.lock().map_err(|_| "unavailable")?.take();
        if !allowed {
            return Err("cancelled".into());
        }
        current = settings(session).map_err(|_| "locked")?;
        let previous = request["token"].as_str().unwrap_or("");
        let mut tokens = wire::tokens(&current["browserPairings"][id]);
        tokens.retain(|t| t != previous);
        if tokens.len() >= 64 {
            return Err("pairing-limit".into());
        }
        let token = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        tokens.push(token.clone());
        if !current["browserPairings"].is_object() {
            current["browserPairings"] = json!({})
        }
        current["browserPairings"][id] = json!(tokens);
        command(
            session,
            json!({"op":"settings","settings":{"browserPairings":current["browserPairings"]}}),
        )?;
        return Ok(json!({"ok":true,"token":token}));
    }
    if !wire::paired(&current, id, request["token"].as_str().unwrap_or("")) {
        return Err("unpaired".into());
    }
    let query = match op {
        "matches" | "fill" => {
            json!({"op":op,"origin":request["origin"],"id":request["id"],"accountId":request["accountId"]})
        }
        "lock" => {
            Browser::cancel_startup();
            json!({"op":"lock"})
        }
        // Preserve existing entries; an identical retry is acknowledged without another write.
        "save" => {
            let origin = request["origin"].as_str().ok_or("invalid-request")?;
            let url = reqwest::Url::parse(origin).map_err(|_| "invalid-request")?;
            if !matches!(url.scheme(), "https" | "http")
                || url.host_str().is_none()
                || !url.username().is_empty()
                || url.password().is_some()
                || !matches!(url.path(), "" | "/")
                || url.query().is_some()
                || url.fragment().is_some()
            {
                return Err("invalid-request".into());
            }
            let user = request["username"]
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= 4096)
                .ok_or("invalid-request")?;
            let password = request["password"]
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= 4096)
                .ok_or("invalid-request")?;
            let matches = command(session, json!({"op":"matches","origin":origin}))?;
            if let Some(accounts) = matches.as_array() {
                for account in accounts {
                    if account["username"] == user {
                        if let Ok(value) = command(
                            session,
                            json!({"op":"fill","origin":origin,"id":account["id"],"accountId":account["accountId"]}),
                        ) {
                            if value["password"] == password {
                                return Ok(json!({"ok":true,"data":{"saved":true}}));
                            }
                        }
                    }
                }
            }
            json!({"op":"save","item":{"id":uuid::Uuid::new_v4().to_string(),"type":"password","title":url.host_str().unwrap(),"username":user,"password":password,"url":origin,"tags":[],"note":"","isDeleted":false,"isFavorite":false,"createdAt":chrono::Utc::now().to_rfc3339(),"updatedAt":chrono::Utc::now().to_rfc3339()}})
        }
        _ => return Err("unsupported".into()),
    };
    Ok(json!({"ok":true,"data":command(session,query)?}))
}
fn start(session: Arc<vault_core::VaultSession>, directory: &Path) -> Result<(), String> {
    let contents = wire::bundle()?;
    let id = wire::identity(&contents)?;
    let helper = contents.join("MacOS/pv-browser-host");
    security::code_hash(&helper).ok_or("Signed helper required")?;
    let mut started = STARTED
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| "unavailable")?;
    if started.contains(&directory.to_path_buf()) {
        return Ok(());
    }
    let path = directory.join("browser-nsh.sock");
    if path.as_os_str().len() >= 104 {
        return Err("Socket path too long".into());
    }
    // The shared core already owns the directory's exclusive process lock.
    if path.exists() {
        std::fs::remove_file(&path).map_err(|_| "unavailable")?;
    }
    let listener = UnixListener::bind(&path).map_err(|_| "unavailable")?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
        .map_err(|_| "unavailable")?;
    started.push(directory.into());
    let startup_directory = directory.to_path_buf();
    let startup_helper = helper.clone();
    let nonce = uuid::Uuid::new_v4().to_string();
    *STARTUP.lock().map_err(|_| "unavailable")? = Some(nonce.clone());
    std::thread::spawn(move || {
        use std::process::{Command, Stdio};
        if let Ok(mut child) = Command::new(startup_helper)
            .arg("--desktop-unlock")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            if let Some(mut input) = child.stdin.take() {
                let _ = wire::write(
                    &mut input,
                    &json!({"directory":startup_directory,"nonce":nonce}),
                );
            }
            for _ in 0..50 {
                if child.try_wait().ok().flatten().is_some() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            let _ = child.kill();
            let _ = child.wait();
        }
        if let Ok(mut value) = STARTUP.lock() {
            if value.as_deref() == Some(&nonce) {
                value.take();
            }
        }
    });
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { break };
            let _ = stream.set_read_timeout(Some(Duration::from_secs(15)));
            let _ = stream.set_write_timeout(Some(Duration::from_secs(15)));
            if !security::peer(stream.as_raw_fd(), &helper) {
                continue;
            }
            if let Ok(request) = wire::read(&mut stream, 65536) {
                let result = dispatch(&session, &id, request).unwrap_or_else(|e| wire::failure(&e));
                let _ = wire::write(&mut stream, &result);
            }
        }
    });
    Ok(())
}
/// Browser registration, pairing confirmation and background-grant revocation.
#[module]
pub struct Browser;
#[module]
impl Browser {
    /// Attach once after Vault has opened its session. No registrations are changed.
    pub fn start(vault: Instance<Vault>) -> Result<(), String> {
        vault.with(|v| start(v.session.clone().ok_or("Locked")?, &v.directory))
    }
    /// Must run before every explicit or system lock to invalidate startup replies.
    pub fn cancel_startup() {
        if let Ok(mut value) = STARTUP.lock() {
            value.take();
        }
        if let Ok(p) = PENDING.lock() {
            if let Some(p) = p.as_ref() {
                let _ = p.reply.try_send(false);
            }
        }
    }
    /// Returns public extension identity and a per-request approval challenge, never vault material.
    pub fn pending() -> String {
        PENDING
            .lock()
            .ok()
            .and_then(|p| {
                p.as_ref()
                    .map(|p| json!({"extensionId":p.id,"challenge":p.challenge}).to_string())
            })
            .unwrap_or_default()
    }
    /// Native settings approval; times out without user consent.
    pub fn approve(challenge: String, allow: bool) {
        if let Ok(p) = PENDING.lock() {
            if let Some(p) = p.as_ref() {
                if p.challenge == challenge {
                    let _ = p.reply.try_send(allow);
                }
            }
        }
    }
    /// Registration statuses for the four supported browser families.
    pub fn registrations() -> Result<String, String> {
        let contents = wire::bundle()?;
        let helper = contents.join("MacOS/pv-browser-host");
        let home = PathBuf::from(std::env::var("HOME").map_err(|_| "unavailable")?);
        Ok(json!(wire::BROWSERS.iter().map(|b|{let value=wire::manifest_path(&home,b).ok().and_then(|p|std::fs::read(p).ok()).and_then(|v|serde_json::from_slice::<Value>(&v).ok());json!({"browser":b,"registered":value.as_ref().is_some_and(|v|v["path"]==helper.to_string_lossy().as_ref()),"otherApp":value.is_some()&&value.as_ref().is_some_and(|v|v["path"]!=helper.to_string_lossy().as_ref())})}).collect::<Vec<_>>()).to_string())
    }
    /// Explicit user action only. Unregister refuses another app's registration.
    pub fn register(browser: String, install: bool) -> Result<(), String> {
        let contents = wire::bundle()?;
        let helper = contents.join("MacOS/pv-browser-host");
        security::code_hash(&helper).ok_or("Signed helper required")?;
        wire::registration(
            &PathBuf::from(std::env::var("HOME").map_err(|_| "unavailable")?),
            &browser,
            &helper,
            &wire::identity(&contents)?,
            install,
        )
    }
    /// Startup policy is a non-secret marker; enabling does not create a grant.
    pub fn startup_enabled(vault: Instance<Vault>) -> bool {
        vault.with(|v| !v.directory.join("browser-startup-disabled").exists())
    }
    /// Explicit desktop preference; disabling cancels any in-flight startup unlock.
    pub fn set_startup_enabled(vault: Instance<Vault>, enabled: bool) -> Result<(), String> {
        Self::cancel_startup();
        vault.with(|v| {
            let path = v.directory.join("browser-startup-disabled");
            if enabled {
                if path.exists() {
                    std::fs::remove_file(path).map_err(|_| "Storage")?;
                }
            } else {
                std::fs::write(path, b"disabled").map_err(|_| "Storage")?;
            }
            Ok(())
        })
    }
    /// Revoke one extension or all pairings and invalidate every background scope.
    pub async fn revoke(vault: Instance<Vault>, extension_id: String) -> Result<(), String> {
        let (session, directory) = vault.with(|v| (v.session.clone(), v.directory.clone()));
        let session = session.ok_or("Locked")?;
        blocking(move || {
            let mut settings = settings(&session)?;
            vault_core::revoke_background_grants(directory.to_string_lossy().into())
                .map_err(crate::error_code)?;
            if extension_id.is_empty() {
                settings["browserPairings"] = json!({})
            } else if let Some(p) = settings["browserPairings"].as_object_mut() {
                p.remove(&extension_id);
            }
            command(
                &session,
                json!({"op":"settings","settings":{"browserPairings":settings["browserPairings"]}}),
            )?;
            Ok(())
        })
        .await
        .map_err(|_| "unavailable".to_string())?
    }
}

#[cfg(test)]
mod tests;
