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
    /// "pair", "update-login", "otp-fill", "structured-list", "structured-fill",
    /// "passkey-create" or "passkey-assert".
    kind: &'static str,
    /// Website origin and, for updates, the username. Never a secret.
    detail: String,
    /// Public ceremony metadata for passkey prompts (RP, user names, credential IDs).
    extra: Value,
    /// `None` rejects; passkey approvals carry the selected credential and master password.
    reply: std::sync::mpsc::SyncSender<Option<Value>>,
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
/// Typing the master password takes longer; still below the extension's 60 s ceremony limit.
const PASSKEY_TIMEOUT: Duration = Duration::from_secs(50);
/// Ask the unlocked window to confirm one extension request (same channel as pairing).
fn consent(id: &str, kind: &'static str, detail: String) -> Result<(), String> {
    consent_with(id, kind, detail, Value::Null, CONSENT_TIMEOUT).map(|_| ())
}
fn consent_with(
    id: &str,
    kind: &'static str,
    detail: String,
    extra: Value,
    timeout: Duration,
) -> Result<Value, String> {
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    {
        let mut pending = PENDING.lock().map_err(|_| "unavailable")?;
        if pending.is_some() {
            return Err(if kind == "pair" {
                "pairing-busy"
            } else {
                "request-busy"
            }
            .into());
        }
        *pending = Some(Pending {
            id: id.into(),
            challenge: uuid::Uuid::new_v4().to_string(),
            kind,
            detail,
            extra,
            reply: tx,
        });
    }
    crate::events::notify("browser");
    crate::background::show_interface();
    let answer = rx.recv_timeout(timeout).ok().flatten();
    PENDING.lock().map_err(|_| "unavailable")?.take();
    crate::events::notify("browser");
    answer.ok_or_else(|| "cancelled".into())
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
    let account = if account_id.is_null() {
        ""
    } else {
        bounded(account_id, true)?
    };
    let matches = command(session, json!({"op":"matches","origin":origin}))?;
    let found = matches.as_array().is_some_and(|accounts| {
        accounts
            .iter()
            .any(|a| a["id"] == id && a["accountId"].as_str().unwrap_or("") == account)
    });
    if found {
        Ok(())
    } else {
        Err("invalid-entry".into())
    }
}
static STARTUP: Mutex<Option<String>> = Mutex::new(None);
static PENDING: Mutex<Option<Pending>> = Mutex::new(None);
static STARTED: OnceLock<Mutex<Vec<PathBuf>>> = OnceLock::new();
/// Bumped after each successful extension save so the open Mac window can merge
/// the new account without a full reload. Carries no vault material.
static REVISION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
fn saved() {
    REVISION.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    crate::events::notify("browser");
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
        crate::events::notify("status");
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
            crate::events::notify("status");
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
            crate::events::notify("browser");
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
        "passkey-create" | "passkey-assert" => return passkey(session, id, op, request),
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
pub struct Browser;
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
    /// Passkey prompt answer: `{"itemId","credentialId","library","currentPassword"}`.
    /// The bridge accepts only a credential it showed for the current challenge.
    pub async fn approve_passkey(challenge: String, selection: String) {
        let selection = serde_json::from_str::<Value>(&selection).unwrap_or(Value::Null);
        #[cfg(all(feature = "ui", not(test)))]
        {
            let result = crate::service_ipc::control_async(
                crate::vault_directory(),
                "browser-approve-passkey",
                json!({"challenge":challenge,"selection":selection}),
            )
            .await;
            let _ = result;
            return;
        }
        #[allow(unreachable_code)]
        approve_passkey_native(challenge, selection)
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
            let _ = p.reply.try_send(None);
        }
    }
}
pub(crate) fn pending_native() -> String {
    PENDING
        .lock()
        .ok()
        .and_then(|p| {
            p.as_ref()
                .map(|p| json!({"extensionId":p.id,"challenge":p.challenge,"kind":p.kind,"detail":p.detail,"passkey":p.extra}).to_string())
        })
        .unwrap_or_default()
}
/// Pending pairing challenge plus the extension-save revision, in one IPC round trip.
pub(crate) fn poll_native() -> String {
    let open = NAVIGATE.lock().ok().and_then(|mut slot| {
        if slot
            .as_ref()
            .is_some_and(|n| n.expires <= std::time::Instant::now())
        {
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
                let _ = p.reply.try_send(allow.then(|| json!({})));
            }
        }
    }
}
/// Window answer for a passkey prompt: the chosen credential (assertions) and master password.
pub(crate) fn approve_passkey_native(challenge: String, selection: Value) {
    if let Ok(p) = PENDING.lock() {
        if let Some(p) = p.as_ref() {
            if p.challenge == challenge && p.kind.starts_with("passkey-") && selection.is_object() {
                let _ = p.reply.try_send(Some(selection));
            }
        }
    }
}
fn string_list(value: &Value, limit: usize) -> Result<Vec<String>, String> {
    if value.is_null() {
        return Ok(vec![]);
    }
    let list = value
        .as_array()
        .filter(|v| v.len() <= limit)
        .ok_or("invalid-request")?;
    list.iter()
        .map(|v| bounded(v, false).map(str::to_owned))
        .collect()
}
fn prf_inputs(value: &Value) -> Result<Value, String> {
    let object = value.as_object().ok_or("invalid-request")?;
    let mut out = json!({});
    for name in ["first", "second"] {
        if let Some(v) = object.get(name).filter(|v| !v.is_null()) {
            out[name] = v
                .as_str()
                .filter(|s| s.len() <= 8192)
                .ok_or("invalid-request")?
                .into();
        }
    }
    Ok(out)
}
/// WebAuthn ceremony through the desktop window: the core reauthenticates the master
/// password, checks client data against the browser-supplied origin and persists first.
fn passkey(
    session: &crate::session::VaultSession,
    id: &str,
    op: &str,
    request: &Value,
) -> Result<Value, String> {
    let url = web_origin(&request["origin"])?;
    if url.scheme() != "https" {
        return Err("invalid-request".into());
    }
    let origin = request["origin"]
        .as_str()
        .unwrap_or("")
        .trim_end_matches('/')
        .to_owned();
    let rp = bounded(&request["rpId"], false)?;
    if !vault_core::passkey_rp_matches(url.host_str().unwrap_or(""), rp) {
        return Err("unsupported-rp".into());
    }
    let client = request["clientDataJSON"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 16384)
        .ok_or("invalid-request")?;
    let allowed = string_list(&request["allowed"], 64)?;
    let excluded = string_list(&request["excluded"], 64)?;
    let create = op == "passkey-create";
    let (user_name, user_handle) = if create {
        let name = request["userName"]
            .as_str()
            .filter(|s| s.len() <= 1024)
            .ok_or("invalid-request")?;
        (
            name.to_owned(),
            bounded(&request["userHandle"], false)?.to_owned(),
        )
    } else {
        (String::new(), String::new())
    };
    let matches: Vec<Value> = command(session, json!({"op":"passkey-matches","rpId":rp}))?
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|m| {
            allowed.is_empty()
                || m["id"]
                    .as_str()
                    .is_some_and(|i| allowed.iter().any(|a| a == i))
        })
        .collect();
    if create {
        if matches.iter().any(|m| {
            m["id"]
                .as_str()
                .is_some_and(|i| excluded.iter().any(|e| e == i))
        }) {
            // Already registered here: let the browser report InvalidStateError itself.
            return Err("already-registered".into());
        }
    } else if matches.is_empty() {
        // Nothing to offer: the page falls back to the browser's own authenticator.
        return Err("no-credentials".into());
    }
    let public: Vec<Value> = matches
        .iter()
        .map(|m| json!({"library":m["library"],"itemId":m["itemId"],"id":m["id"],"userName":m["userName"]}))
        .collect();
    let extra = json!({"operation":if create {"create"} else {"get"},"origin":origin,"rpId":rp,"userName":user_name,"matches":public});
    let kind = if create {
        "passkey-create"
    } else {
        "passkey-assert"
    };
    let selection = consent_with(id, kind, format!("{origin}\n{rp}"), extra, PASSKEY_TIMEOUT)?;
    if selection["fallback"] == true {
        // "Use another device": the page hands the ceremony to the browser's own authenticator.
        return Err("use-browser".into());
    }
    let password = zeroize::Zeroizing::new(
        selection["currentPassword"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 4096)
            .ok_or("cancelled")?
            .to_owned(),
    );
    let mut query = json!({"op":op,"origin":origin,"rpId":rp,"clientDataJSON":client});
    // PRF inputs are public salts; the core validates and evaluates them for the chosen credential.
    if request["prf"].is_object() {
        query["prf"] = prf_inputs(&request["prf"])?;
        if let Some(by) = request["prfByCredential"]
            .as_object()
            .filter(|m| m.len() <= 64)
        {
            let mut map = serde_json::Map::new();
            for (key, value) in by {
                bounded(&Value::from(key.as_str()), false)?;
                map.insert(key.clone(), prf_inputs(value)?);
            }
            query["prfByCredential"] = Value::Object(map);
        }
    }
    if create {
        query["userName"] = user_name.into();
        query["userHandle"] = user_handle.into();
        query["excluded"] = json!(excluded);
        query["library"] = json!("");
    } else {
        // The window may only pick one of the credentials it was shown.
        let chosen = public
            .iter()
            .find(|m| {
                m["id"] == selection["credentialId"]
                    && m["itemId"] == selection["itemId"]
                    && m["library"] == selection["library"]
            })
            .ok_or("invalid-entry")?;
        query["credentialId"] = chosen["id"].clone();
        query["itemId"] = chosen["itemId"].clone();
        // "" is the personal library even when a shared library is active.
        query["library"] = json!(chosen["library"].as_str().unwrap_or(""));
        query["allowed"] = json!(allowed);
    }
    query["currentPassword"] = json!(password.as_str());
    let result = command(session, query);
    let data = result.map_err(|e| {
        if e == "Authentication" {
            "authentication".to_string()
        } else {
            e
        }
    })?;
    if create {
        saved();
    }
    Ok(json!({"ok":true,"data":data}))
}
