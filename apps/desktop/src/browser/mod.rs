//! Signed-helper socket and explicit preview registration. No auto-registration.
mod security;
mod wire;
#[cfg(feature = "ui")]
use crate::Vault;
#[cfg(feature = "ui")]
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
    /// "pair", "update-login", "otp-fill", "structured-list" or "structured-fill".
    kind: &'static str,
    /// Website origin and, for updates, the username. Never a secret.
    detail: String,
    reply: std::sync::mpsc::SyncSender<bool>,
}
/// One-shot request to reveal a record in the window; expires if no window shows it.
struct Navigation {
    nonce: String,
    id: String,
    account_id: Option<String>,
    expires: std::time::Instant,
}
static NAVIGATE: Mutex<Option<Navigation>> = Mutex::new(None);
const CONSENT_TIMEOUT: Duration = Duration::from_secs(35);
/// Ask the unlocked window to confirm one extension request (same channel as pairing).
fn consent(id: &str, kind: &'static str, detail: String) -> Result<(), String> {
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    {
        let mut pending = PENDING.lock().map_err(|_| "unavailable")?;
        if pending.is_some() {
            return Err(if kind == "pair" { "pairing-busy" } else { "request-busy" }.into());
        }
        *pending = Some(Pending {
            id: id.into(),
            challenge: uuid::Uuid::new_v4().to_string(),
            kind,
            detail,
            reply: tx,
        });
    }
    crate::background::show_interface();
    let allowed = rx.recv_timeout(CONSENT_TIMEOUT).unwrap_or(false);
    PENDING.lock().map_err(|_| "unavailable")?.take();
    if allowed { Ok(()) } else { Err("cancelled".into()) }
}
/// Plain http(s) origin without credentials, path, query or fragment.
fn web_origin(value: &Value) -> Result<reqwest::Url, String> {
    let origin = value.as_str().ok_or("invalid-request")?;
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
    Ok(url)
}
fn bounded<'a>(value: &'a Value, allow_empty: bool) -> Result<&'a str, String> {
    value
        .as_str()
        .filter(|s| (allow_empty || !s.is_empty()) && s.len() <= 4096)
        .ok_or_else(|| "invalid-request".into())
}
/// The record (and optional additional account) must be one of this website's matches.
fn owned_by(
    session: &crate::session::VaultSession,
    origin: &str,
    id: &Value,
    account_id: &Value,
) -> Result<(), String> {
    let id = bounded(id, false)?;
    let account = if account_id.is_null() { "" } else { bounded(account_id, true)? };
    let matches = command(session, json!({"op":"matches","origin":origin}))?;
    let found = matches.as_array().is_some_and(|accounts| {
        accounts.iter().any(|a| {
            a["id"] == id && a["accountId"].as_str().unwrap_or("") == account
        })
    });
    if found { Ok(()) } else { Err("invalid-entry".into()) }
}
static STARTUP: Mutex<Option<String>> = Mutex::new(None);
static PENDING: Mutex<Option<Pending>> = Mutex::new(None);
static STARTED: OnceLock<Mutex<Vec<PathBuf>>> = OnceLock::new();
/// Bumped after each successful extension save so the open Mac window can merge
/// the new account without a full reload. Carries no vault material.
static REVISION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
fn saved() {
    REVISION.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
}
fn command(session: &crate::session::VaultSession, request: Value) -> Result<Value, String> {
    serde_json::from_str(
        &session
            .command(request.to_string())
            .map_err(crate::error_code)?,
    )
    .map_err(|_| "failed".into())
}
fn settings(session: &crate::session::VaultSession) -> Result<Value, String> {
    command(session, json!({"op":"read-settings"}))
}
fn dispatch(
    session: &crate::session::VaultSession,
    id: &str,
    wrapper: Value,
) -> Result<Value, String> {
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
        let data = serde_json::from_str::<Value>(&output).map_err(|_| "failed")?;
        if op == "sync-save" && data["saved"] == true {
            saved();
        }
        return Ok(json!({"ok":true,"data":data}));
    }
    let mut current = current.map_err(|_| "locked")?;
    if op == "pair" {
        consent(id, "pair", String::new())?;
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
            cancel_startup_native();
            json!({"op":"lock"})
        }
        // Preserve existing entries; an identical retry is acknowledged without another write.
        "save" => {
            let url = web_origin(&request["origin"])?;
            let origin = request["origin"].as_str().ok_or("invalid-request")?;
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
        // Same explicit confirmations as the legacy Mac bridge.
        "update-login" => {
            web_origin(&request["origin"])?;
            let origin = request["origin"].as_str().unwrap_or("");
            let user = bounded(&request["username"], false)?;
            bounded(&request[concat!("pass", "word")], false)?;
            owned_by(session, origin, &request["id"], &request["accountId"])?;
            consent(id, "update-login", format!("{origin}\n{user}"))?;
            let mut query = json!({"op":"update-login","origin":origin,"id":request["id"],"username":user,"time":chrono::Utc::now().to_rfc3339()});
            if request["accountId"].is_string() {
                query["accountId"] = request["accountId"].clone();
            }
            query[concat!("pass", "word")] = request[concat!("pass", "word")].clone();
            let data = command(session, query)?;
            saved();
            return Ok(json!({"ok":true,"data":data}));
        }
        "open-entry" => {
            web_origin(&request["origin"])?;
            let origin = request["origin"].as_str().unwrap_or("");
            owned_by(session, origin, &request["id"], &request["accountId"])?;
            *NAVIGATE.lock().map_err(|_| "unavailable")? = Some(Navigation {
                nonce: uuid::Uuid::new_v4().to_string(),
                id: bounded(&request["id"], false)?.into(),
                account_id: request["accountId"].as_str().map(str::to_owned),
                expires: std::time::Instant::now() + Duration::from_secs(30),
            });
            crate::background::show_interface();
            return Ok(json!({"ok":true,"data":{"opened":true}}));
        }
        // Labels only; the code itself needs a confirmation.
        "otp-matches" => {
            web_origin(&request["origin"])?;
            json!({"op":"otp-matches","origin":request["origin"]})
        }
        "otp-fill" => {
            web_origin(&request["origin"])?;
            let origin = request["origin"].as_str().unwrap_or("");
            bounded(&request["id"], false)?;
            consent(id, "otp-fill", origin.into())?;
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_err(|_| "failed")?
                .as_secs();
            json!({"op":"otp-fill","origin":origin,"id":request["id"],"time":now})
        }
        "structured-list" => {
            consent(id, "structured-list", String::new())?;
            json!({"op":"structured-list"})
        }
        "structured-fill" => {
            let url = web_origin(&request["origin"])?;
            if url.scheme() != "https" {
                return Err("invalid-request".into());
            }
            let origin = request["origin"].as_str().unwrap_or("");
            bounded(&request["id"], false)?;
            consent(id, "structured-fill", origin.into())?;
            json!({"op":"structured-fill","origin":origin,"id":request["id"],"includeSecurityCode":request["includeSecurityCode"] == true})
        }
        _ => return Err("unsupported".into()),
    };
    let data = command(session, query)?;
    if op == "save" {
        saved();
    }
    Ok(json!({"ok":true,"data":data}))
}
pub(crate) fn start(
    session: Arc<crate::session::VaultSession>,
    directory: &Path,
) -> Result<(), String> {
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
pub(crate) fn request_startup(directory: &Path) -> Result<(), String> {
    static ISSUED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if ISSUED.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return Ok(());
    }
    let helper = wire::bundle()?.join("MacOS/pv-browser-host");
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
    Ok(())
}
/// Browser registration, pairing confirmation and background-grant revocation.
#[cfg_attr(feature = "ui", module)]
pub struct Browser;
#[cfg_attr(feature = "ui", module)]
impl Browser {
    /// Attach once after Vault has opened its session. No registrations are changed.
    #[cfg(feature = "ui")]
    pub async fn start(vault: Instance<Vault>) -> Result<(), String> {
        #[cfg(not(test))]
        {
            let directory = vault.with(|v| v.directory.clone());
            return crate::service_ipc::control_async(directory, "browser-start", json!({}))
                .await
                .map(|_| ());
        }
        #[cfg(test)]
        vault.with(|v| start(v.session.clone().ok_or("Locked")?, &v.directory))
    }
    /// Must run before every explicit or system lock to invalidate startup replies.
    pub async fn cancel_startup() {
        #[cfg(all(feature = "ui", not(test)))]
        {
            let result = crate::service_ipc::control_async(
                crate::vault_directory(),
                "browser-cancel",
                json!({}),
            )
            .await;
            let _ = result;
            return;
        }
        #[allow(unreachable_code)]
        cancel_startup_native()
    }
    /// `{"pending": <pending() text>, "revision": n}`; the revision changes after
    /// each extension save so the UI can merge new accounts. Never vault material.
    pub async fn poll() -> String {
        #[cfg(all(feature = "ui", not(test)))]
        {
            let result = crate::service_ipc::control_async(
                crate::vault_directory(),
                "browser-poll",
                json!({}),
            )
            .await;
            return result
                .ok()
                .and_then(|v| v.as_str().map(str::to_owned))
                .unwrap_or_default();
        }
        #[allow(unreachable_code)]
        poll_native()
    }
    /// Returns public extension identity and a per-request approval challenge, never vault material.
    pub async fn pending() -> String {
        #[cfg(all(feature = "ui", not(test)))]
        {
            let result = crate::service_ipc::control_async(
                crate::vault_directory(),
                "browser-pending",
                json!({}),
            )
            .await;
            return result
                .ok()
                .and_then(|v| v.as_str().map(str::to_owned))
                .unwrap_or_default();
        }
        #[allow(unreachable_code)]
        pending_native()
    }
    /// Native settings approval; times out without user consent.
    pub async fn approve(challenge: String, allow: bool) {
        #[cfg(all(feature = "ui", not(test)))]
        {
            let result = crate::service_ipc::control_async(
                crate::vault_directory(),
                "browser-approve",
                json!({"challenge":challenge,"allow":allow}),
            )
            .await;
            let _ = result;
            return;
        }
        #[allow(unreachable_code)]
        approve_native(challenge, allow)
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
    #[cfg(feature = "ui")]
    pub fn startup_enabled(vault: Instance<Vault>) -> bool {
        vault.with(|v| !v.directory.join("browser-startup-disabled").exists())
    }
    /// Explicit desktop preference; disabling cancels any in-flight startup unlock.
    #[cfg(feature = "ui")]
    pub async fn set_startup_enabled(vault: Instance<Vault>, enabled: bool) -> Result<(), String> {
        let directory = vault.with(|v| v.directory.clone());
        Self::cancel_startup().await;
        (|| {
            let path = directory.join("browser-startup-disabled");
            if enabled {
                if path.exists() {
                    std::fs::remove_file(path).map_err(|_| "Storage")?;
                }
            } else {
                std::fs::write(path, b"disabled").map_err(|_| "Storage")?;
            }
            Ok(())
        })()
    }
    /// Revoke one extension or all pairings and invalidate every background scope.
    #[cfg(feature = "ui")]
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

pub(crate) fn cancel_startup_native() {
    if let Ok(mut value) = STARTUP.lock() {
        value.take();
    }
    if let Ok(p) = PENDING.lock() {
        if let Some(p) = p.as_ref() {
            let _ = p.reply.try_send(false);
        }
    }
}
pub(crate) fn pending_native() -> String {
    PENDING
        .lock()
        .ok()
        .and_then(|p| {
            p.as_ref()
                .map(|p| json!({"extensionId":p.id,"challenge":p.challenge,"kind":p.kind,"detail":p.detail}).to_string())
        })
        .unwrap_or_default()
}
/// Pending pairing challenge plus the extension-save revision, in one IPC round trip.
pub(crate) fn poll_native() -> String {
    let open = NAVIGATE.lock().ok().and_then(|mut slot| {
        if slot.as_ref().is_some_and(|n| n.expires <= std::time::Instant::now()) {
            slot.take();
        }
        slot.as_ref()
            .map(|n| json!({"nonce":n.nonce,"id":n.id,"accountId":n.account_id}))
    });
    json!({
        "pending": pending_native(),
        "revision": REVISION.load(std::sync::atomic::Ordering::SeqCst),
        "open": open,
    })
    .to_string()
}
pub(crate) fn approve_native(challenge: String, allow: bool) {
    if let Ok(p) = PENDING.lock() {
        if let Some(p) = p.as_ref() {
            if p.challenge == challenge {
                let _ = p.reply.try_send(allow);
            }
        }
    }
}
