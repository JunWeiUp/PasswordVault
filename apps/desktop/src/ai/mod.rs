//! App-owned AI policy. The transport never opens a vault or executes content.
use crate::{Vault, error_code};
use nsh_core::prelude::*;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, Instant},
};
use crate::session::VaultSession;
#[cfg(target_os = "macos")]
mod socket;
#[cfg(not(target_os = "macos"))]
mod socket {
    pub fn start(_: std::sync::Arc<crate::session::VaultSession>) -> super::Result<String> {
        Err("Unsupported".into())
    }
}
mod clipboard;
#[cfg(test)]
mod tests;
type Result<T> = std::result::Result<T, String>;
struct Pending {
    view: Value,
    expires: Instant,
    answer: Option<bool>,
    /// Requested by the approver: skip approval for this client/entry/field for
    /// this many seconds; 0 means until the vault locks (low-sensitivity fields only).
    lease: Option<u64>,
}
/// In-memory only: never persisted, dropped on lock and on any policy change.
#[derive(Clone)]
struct Lease {
    client: String,
    entry: String,
    field: String,
    reveal: bool,
    expires: Option<Instant>,
}
const LEASE_SECONDS: u64 = 15 * 60;
const CLIPBOARD_SECONDS: u64 = 30;
/// Fields whose disclosure is low impact may stay approved until the vault locks.
fn low_sensitivity(field: &str) -> bool {
    matches!(field, "phone" | "address1" | "address2" | "postalCode")
}
fn lease_matches(l: &Lease, client: &str, entry: &str, field: &str, reveal: bool) -> bool {
    l.client == client
        && l.entry == entry
        && l.field == field
        && (l.reveal || !reveal)
        && l.expires.is_none_or(|t| t > Instant::now())
}
#[derive(Default)]
struct State {
    pending: HashMap<String, Pending>,
    pair: Option<(String, String, Instant)>,
    socket: Option<String>,
    deferred_audit: Vec<Value>,
    leases: Vec<Lease>,
}
static STATE: OnceLock<Mutex<State>> = OnceLock::new();
static SERIAL: Mutex<()> = Mutex::new(());
fn state() -> std::sync::MutexGuard<'static, State> {
    STATE.get_or_init(Default::default).lock().unwrap()
}
fn core(s: &VaultSession, v: Value) -> Result<Value> {
    serde_json::from_str(&s.command(v.to_string()).map_err(error_code)?)
        .map_err(|_| "InvalidData".into())
}
fn doc(s: &VaultSession) -> Result<Value> {
    core(s, json!({"op":"list","richNotes":true}))
}
fn save(s: &VaultSession, patch: Value) -> Result<()> {
    core(s, json!({"op":"settings","settings":patch})).map(|_| ())
}
fn hash(s: &str) -> String {
    format!("{:x}", Sha256::digest(s.as_bytes()))
}
fn approval_decision(p: &Pending) -> Option<Result<()>> {
    if Instant::now() >= p.expires {
        Some(Err("ApprovalTimeout".into()))
    } else {
        p.answer.map(|yes| {
            if yes {
                Ok(())
            } else {
                Err("ApprovalDenied".into())
            }
        })
    }
}
fn id() -> String {
    uuid::Uuid::new_v4().to_string()
}
fn scope(item: &Value) -> Option<&'static str> {
    match item["type"].as_str()? {
        "device" => Some("devices"),
        "password" => Some("accounts"),
        "secureNote" => Some("notes"),
        "identity" | "creditCard" => Some("profiles"),
        _ => None,
    }
}
#[cfg(test)]
fn client<'a>(d: &'a Value, token: &str) -> Result<&'a Value> {
    client_digest(d, &hash(token))
}
fn client_digest<'a>(d: &'a Value, digest: &str) -> Result<&'a Value> {
    if d["settings"]["aiAccessEnabled"] != true {
        return Err("Disabled".into());
    }
    d["settings"]["aiAccessClients"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|c| c["tokenHash"] == digest)
        .ok_or("RevokedOrUnknownClient".into())
}
fn allowed(d: &Value, c: &Value, item: &Value) -> bool {
    !item["isDeleted"].as_bool().unwrap_or(false)
        && scope(item).is_some_and(|scope| {
            d["settings"]["aiAccessScopes"][scope] == true
                && c["entries"][item["id"].as_str().unwrap_or("")] == true
        })
}
/// An existing entry in an enabled category that this client has not been granted yet.
/// The user may grant it from the approval sheet instead of opening Settings.
fn grantable<'a>(d: &'a Value, c: &Value, r: &Value) -> Option<&'a Value> {
    d["items"].as_array().into_iter().flatten().find(|i| {
        i["id"] == r["id"]
            && !i["isDeleted"].as_bool().unwrap_or(false)
            && scope(i).is_some_and(|scope| d["settings"]["aiAccessScopes"][scope] == true)
            && c["entries"][i["id"].as_str().unwrap_or("")] != true
    })
}
fn entry<'a>(d: &'a Value, c: &Value, r: &Value) -> Result<&'a Value> {
    d["items"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|i| i["id"] == r["id"] && allowed(d, c, i))
        .ok_or("UnscopedOrMissing".into())
}
fn projection(i: &Value, details: bool) -> Value {
    let mut out = json!({"id":i["id"],"type":i["type"],"title":i["title"]});
    if details {
        let keys: &[&str] = match i["type"].as_str() {
            Some("password") => &["username", "url"],
            Some("device") => &[],
            Some("secureNote") => &["note", "noteDocument"],
            _ => &[],
        };
        for k in keys {
            if let Some(v) = i.get(*k) {
                out[*k] = v.clone();
            }
        }
    }
    if details && i["type"] == "password" {
        // A website field can itself contain credentials; expose only its origin/path.
        if let Some(raw) = i["url"].as_str() {
            let candidate = if raw.contains("://") {
                raw.to_string()
            } else {
                format!("https://{raw}")
            };
            out.as_object_mut().unwrap().remove("url");
            if let Ok(mut url) = reqwest::Url::parse(&candidate) {
                if matches!(url.scheme(), "http" | "https") {
                    let _ = url.set_username("");
                    let _ = url.set_password(None);
                    url.set_query(None);
                    url.set_fragment(None);
                    out["url"] = json!(url.to_string());
                }
            }
        }
    }
    if details && i["type"] == "device" {
        let device = &i["device"];
        let mut safe = json!({});
        for k in ["host", "port", "username", "authMethod", "aliases"] {
            if let Some(v) = device.get(k) {
                safe[k] = v.clone();
            }
        }
        safe["services"] = json!(
            device["services"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|svc| {
                    let mut v = json!({});
                    for k in ["id", "name", "kind", "remotePort", "localPort"] {
                        v[k] = svc[k].clone();
                    }
                    v
                })
                .collect::<Vec<_>>()
        );
        safe["commands"] = json!(device["commands"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|cmd| cmd["secret"] == false)
            .map(|cmd| {
                let mut row = json!({"id":cmd["id"],"title":cmd["title"],"text":cmd["text"],"dataOnly":true});
                if let Some(label) = cmd["label"].as_str().filter(|s| !s.trim().is_empty()) {
                    row["label"] = json!(label);
                }
                row
            })
            .collect::<Vec<_>>());
        out["device"] = safe;
    }
    if details && i["type"] == "identity" {
        let identity = &i["identity"];
        let mut safe = json!({});
        for k in ["firstName", "lastName", "email", "company", "city", "region", "country"] {
            if let Some(v) = identity.get(k) {
                safe[k] = v.clone();
            }
        }
        out["identity"] = safe;
    }
    if details && i["type"] == "creditCard" {
        let card = &i["card"];
        let mut safe = json!({});
        for k in ["cardholder", "expiryMonth", "expiryYear", "brand"] {
            if let Some(v) = card.get(k) {
                safe[k] = v.clone();
            }
        }
        out["card"] = safe;
    }
    if let Some(fields) = i["customFields"].as_array() {
        out["customFields"] = json!(fields
            .iter()
            .filter(|field| field["kind"] != "concealed")
            .map(|field| {
                json!({
                    "id": field["id"],
                    "group": field["group"],
                    "label": field["label"],
                    "kind": field["kind"],
                    "value": field["value"],
                    "dataOnly": true,
                })
            })
            .collect::<Vec<_>>());
    }
    out
}
fn secret<'a>(i: &'a Value, field: &str) -> Result<&'a Value> {
    if !matches!(
        field,
        "password"
            | "token"
            | "privateKey"
            | "nodeLink"
            | "notes"
            | "phone"
            | "address1"
            | "address2"
            | "postalCode"
            | "number"
            | "securityCode"
    ) {
        if !field.starts_with("custom:") {
            return Err("DeniedField".into());
        }
    }
    if let Some(id) = field.strip_prefix("custom:") {
        return i["customFields"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|custom| custom["id"] == id && custom["kind"] == "concealed")
            .and_then(|custom| custom.get("value"))
            .filter(|value| value.is_string())
            .ok_or("DeniedField".into());
    }
    let source = match i["type"].as_str() {
        Some("device") => &i["device"],
        Some("password") if field == "password" => i,
        Some("identity") if matches!(field, "phone" | "address1" | "address2" | "postalCode") => {
            &i["identity"]
        }
        Some("creditCard") if matches!(field, "number" | "securityCode") => &i["card"],
        _ => return Err("DeniedField".into()),
    };
    source
        .get(field)
        .filter(|v| v.is_string())
        .ok_or("MissingField".into())
}
fn approved_file(d: &Value, c: &Value, i: &Value, fid: &str) -> bool {
    c["files"][i["id"].as_str().unwrap_or("")] == true
        && d["settings"]["aiAccessOrdinaryFiles"][i["id"].as_str().unwrap_or("")][fid] == true
}
fn audit(s: &VaultSession, cid: &str, item: &str, op: &str, rid: &str, result: &str) -> Result<()> {
    let d = doc(s)?;
    let mut log = d["settings"]["aiAccessAudit"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let deferred = state().deferred_audit.clone();
    for row in deferred {
        log.insert(0, row);
    }
    log.insert(0,json!({"client":cid,"item":item,"operation":op,"requestId":rid,"result":result,"unixSeconds":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs()}));
    log.truncate(200);
    save(s, json!({"aiAccessAudit":log}))?;
    state().deferred_audit.clear();
    Ok(())
}
/// Every read checks the live core session, then permission, then a field whitelist.
pub(super) fn request(s: &VaultSession, r: Value) -> Result<Value> {
    let digest = hash(r["token"].as_str().unwrap_or(""));
    request_digest(s, r, &digest)
}
fn request_digest(s: &VaultSession, r: Value, digest: &str) -> Result<Value> {
    let initial = doc(s).ok();
    let c = initial.as_ref().and_then(|d| client_digest(d, digest).ok());
    let cid = c
        .and_then(|c| c["id"].as_str())
        .unwrap_or("unknown")
        .to_string();
    let item = initial
        .as_ref()
        .and_then(|d| d["items"].as_array())
        .and_then(|items| items.iter().find(|i| i["id"] == r["id"]))
        .and_then(|i| i["id"].as_str())
        .unwrap_or("")
        .to_string();
    let op = match r["op"].as_str().unwrap_or("") {
        v @ ("pair" | "search_entries" | "get_entry" | "get_secret" | "list_files"
        | "read_file") => v.to_string(),
        _ => "unsupported".into(),
    };
    let rid = r["requestId"]
        .as_str()
        .and_then(|v| uuid::Uuid::parse_str(v).ok())
        .map(|v| v.to_string())
        .unwrap_or_else(id);
    let mut result = request_inner(s, r.clone(), &rid, digest);
    let _guard = SERIAL.lock().unwrap();
    if result.is_ok() && op != "pair" {
        let final_check = (|| {
            let d = doc(s)?;
            let c = client_digest(&d, digest)?;
            if op == "search_entries" {
                for row in result.as_ref().unwrap().as_array().into_iter().flatten() {
                    entry(&d, c, &json!({"id":row["id"]}))?;
                }
            } else {
                let i = entry(&d, c, &r)?;
                if op == "read_file" && !approved_file(&d, c, i, r["fileId"].as_str().unwrap_or(""))
                {
                    return Err("UnclassifiedOrDeniedFile".into());
                }
            }
            Ok(())
        })();
        if let Err(e) = final_check {
            result = Err(e);
        }
    }
    let outcome = result
        .as_ref()
        .map(|v| if v["approval"] == "lease" { "AllowedByLease" } else { "Allowed" })
        .unwrap_or_else(|e| e.as_str());
    if doc(s).is_ok() {
        audit(s, &cid, &item, &op, &rid, outcome)?;
    } else {
        let mut st = state();
        st.deferred_audit.push(
            json!({"client":cid,"item":item,"operation":op,"requestId":rid,"result":"Locked","unixSeconds":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs()}),
        );
        if st.deferred_audit.len() > 200 {
            st.deferred_audit.remove(0);
        }
        return Err("Locked".into());
    }
    result
}
fn request_inner(s: &VaultSession, r: Value, request_id: &str, digest: &str) -> Result<Value> {
    let op = r["op"].as_str().unwrap_or("");
    if op == "pair" {
        let _guard = SERIAL.lock().unwrap();
        let d = doc(s)?;
        if d["settings"]["aiAccessEnabled"] != true {
            return Err("Disabled".into());
        }
        let mut st = state();
        let (code, name, expires) = st.pair.take().ok_or("NoPairing".to_string())?;
        if expires <= Instant::now() || r["code"] != code {
            return Err("PairingDenied".into());
        }
        let token = format!("{}{}", id(), id());
        let cid = id();
        let mut clients = d["settings"]["aiAccessClients"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        clients
            .push(json!({"id":cid,"name":name,"tokenHash":hash(&token),"entries":{},"files":{}}));
        save(s, json!({"aiAccessClients":clients}))?;
        return Ok(json!({"clientId":cid,"token":token}));
    }
    let rid = request_id.to_string();
    let field = r["field"].as_str().unwrap_or("").to_string();
    // Secrets go to the clipboard unless the client explicitly asks to see them.
    let reveal = r["delivery"] == "reveal";
    let (approval, revision, grant, leased) = {
        let _guard = SERIAL.lock().unwrap();
        let d = match doc(s) {
            Ok(d) => d,
            Err(e) => {
                state().leases.clear();
                return Err(e);
            }
        };
        let c = client_digest(&d, digest)?;
        let cid = c["id"].as_str().unwrap_or("").to_string();
        let entry_op = matches!(op, "get_entry" | "get_secret" | "list_files");
        let (i, grant) = match entry(&d, c, &r) {
            Ok(i) => (Some(i), false),
            Err(e) if entry_op => (Some(grantable(&d, c, &r).ok_or(e)?), true),
            Err(_) => (None, false),
        };
        if op == "get_secret" {
            secret(i.unwrap(), &field)?;
        }
        let item_id = i.map(|i| i["id"].as_str().unwrap_or("").to_string()).unwrap_or_default();
        let leased = op == "get_secret"
            && !grant
            && state().leases.iter().any(|l| lease_matches(l, &cid, &item_id, &field, reveal));
        if (op == "get_secret" && !leased) || grant {
            let i = i.unwrap();
            let mut st = state();
            if st.pending.len() >= 8 {
                return Err("Busy".into());
            }
            let secret_view = op == "get_secret";
            st.pending.insert(rid.clone(), Pending {
                view: json!({
                    "requestId": rid, "client": c["name"], "item": i["title"],
                    "kind": if secret_view { "secret" } else { "grant" },
                    "grant": grant,
                    "field": if secret_view { json!(field) } else { Value::Null },
                    "delivery": if secret_view { json!(if reveal { "reveal" } else { "clipboard" }) } else { Value::Null },
                    "leaseUntilLock": secret_view && low_sensitivity(&field),
                    "leaseMinutes": if secret_view { LEASE_SECONDS / 60 } else { 0 },
                    // Untrusted client text: bounded before it reaches the approval sheet.
                    "purpose": r["purpose"].as_str().map(|p| p.chars().take(120).collect::<String>()),
                }),
                expires: Instant::now() + Duration::from_secs(60),
                answer: None,
                lease: None,
            });
            (true, hash(&i.to_string()), grant, false)
        } else {
            (false, i.map_or(String::new(), |i| hash(&i.to_string())), false, leased)
        }
    };
    let mut decision: Result<()> = Ok(());
    let mut lease = None;
    if approval {
        loop {
            if doc(s).is_err() {
                decision = Err("Locked".into());
                break;
            }
            let st = state();
            let p = st.pending.get(&rid).unwrap();
            if let Some(answer) = approval_decision(p) {
                decision = answer;
                lease = p.lease;
                break;
            }
            drop(st);
            std::thread::sleep(Duration::from_millis(100));
        }
        state().pending.remove(&rid);
    }
    if decision.is_ok() && grant {
        // Approving an ungranted entry adds it to this client's list, like Settings would.
        let _guard = SERIAL.lock().unwrap();
        let d = doc(s)?;
        let cid = client_digest(&d, digest)?["id"].clone();
        let mut cs = d["settings"]["aiAccessClients"].as_array().cloned().unwrap_or_default();
        let c = cs.iter_mut().find(|c| c["id"] == cid).ok_or("RevokedOrUnknownClient")?;
        if !c["entries"].is_object() {
            c["entries"] = json!({});
        }
        c["entries"][r["id"].as_str().unwrap_or("")] = json!(true);
        save(s, json!({"aiAccessClients":cs}))?;
    }
    let _guard = SERIAL.lock().unwrap();
    let result: Result<Value> = (|| {
        decision?;
        let d = doc(s)?;
        let c = client_digest(&d, digest)?;
        match op {
            "search_entries" => {
                let q = r["query"].as_str().unwrap_or("").to_lowercase();
                Ok(json!(
                    d["items"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter(|i| allowed(&d, c, i)
                            && format!(
                                "{} {} {} {}",
                                i["title"],
                                i["tags"],
                                i["device"]["aliases"],
                                d["settings"]["aiAccessAliases"][i["id"].as_str().unwrap_or("")]
                            )
                            .to_lowercase()
                            .contains(&q))
                        .take(100)
                        .map(|i| projection(i, false))
                        .collect::<Vec<_>>()
                ))
            }
            "get_entry" => Ok(projection(entry(&d, c, &r)?, true)),
            "get_secret" => {
                let i = entry(&d, c, &r)?;
                if hash(&i.to_string()) != revision {
                    return Err("EntryChanged".into());
                }
                let value = secret(i, &field)?.as_str().ok_or("DeniedField")?;
                if let Some(seconds) = lease {
                    let entry_id = i["id"].as_str().unwrap_or("").to_string();
                    let cid = c["id"].as_str().unwrap_or("").to_string();
                    let mut st = state();
                    st.leases.retain(|l| !(l.client == cid && l.entry == entry_id && l.field == field));
                    st.leases.push(Lease { client: cid, entry: entry_id, field: field.clone(), reveal,
                        expires: (seconds > 0).then(|| Instant::now() + Duration::from_secs(seconds)) });
                }
                let approval = if leased { "lease" } else if lease.is_some() { "leaseStarted" } else { "once" };
                if reveal {
                    return Ok(json!({"value":value,"approval":approval}));
                }
                clipboard::put(value, CLIPBOARD_SECONDS)?;
                Ok(json!({
                    "delivered": "clipboard",
                    "clearsAfterSeconds": CLIPBOARD_SECONDS,
                    "approval": approval,
                    "note": "The value is on the user's clipboard and was not returned to you. Ask the user to paste it, or paste it into the focused field yourself. Request delivery \"reveal\" only if you must read the text.",
                }))
            }
            "list_files" => {
                let i = entry(&d, c, &r)?;
                let files = d["settings"]["aiAccessOrdinaryFiles"][i["id"].as_str().unwrap_or("")]
                    .as_object()
                    .into_iter()
                    .flatten()
                    .filter(|(fid, _)| approved_file(&d, c, i, fid))
                    .map(|(fid, _)| json!({"id":fid,"classification":"ordinary"}))
                    .collect::<Vec<_>>();
                Ok(json!(files))
            }
            "read_file" => {
                let i = entry(&d, c, &r)?;
                let fid = r["fileId"].as_str().ok_or("MissingFile")?;
                if !approved_file(&d, c, i, fid) {
                    return Err("UnclassifiedOrDeniedFile".into());
                }
                let bytes = zeroize::Zeroizing::new(
                    s.read_note_attachment(i["id"].as_str().unwrap().into(), fid.into())
                        .map_err(error_code)?,
                );
                let text = std::str::from_utf8(&bytes).map_err(|_| "TextOnly")?;
                let offset = r["offset"].as_u64().unwrap_or(0) as usize;
                let limit = r["limit"].as_u64().unwrap_or(4096).clamp(1, 16384) as usize;
                let chunk: String = text.chars().skip(offset).take(limit).collect();
                let next = offset.saturating_add(chunk.chars().count());
                Ok(
                    json!({"text":chunk,"nextOffset":next,"eof":next>=text.chars().count(),"dataOnly":true}),
                )
            }
            _ => Err("ReadOnlyUnsupportedOperation".into()),
        }
    })();
    result
}
/// Read-only local AI access with encrypted grants and single-request approvals.
#[module]
pub struct Ai;
#[module]
impl Ai {
    /// Clears outstanding approvals when the UI transitions to locked.
    pub fn cancel_pending() {
        let mut st = state();
        st.pair = None;
        st.leases.clear();
        for p in st.pending.values_mut() {
            p.answer = Some(false);
        }
    }

    /// Starts the separate local socket after the app has opened its session.
    pub async fn start(vault: Instance<Vault>) -> Result<String> {
        let s = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || socket::start(s))
            .await
            .map_err(|_| "Storage".to_string())?
    }
    /// Runs a UI demonstration as one selected paired client, with full policy and audit.
    pub async fn preview(
        vault: Instance<Vault>,
        client_id: String,
        request: String,
    ) -> Result<String> {
        let s = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            let d = doc(&s)?;
            let digest = d["settings"]["aiAccessClients"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|c| c["id"] == client_id)
                .and_then(|c| c["tokenHash"].as_str())
                .ok_or("UnknownClient")?
                .to_string();
            let r: Value = serde_json::from_str(&request).map_err(|_| "InvalidData")?;
            if r["op"] == "pair" {
                return Err("Unsupported".into());
            }
            request_digest(&s, r, &digest).map(|v| v.to_string())
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }
    /// UI-only control plane. Never exposed by the socket protocol.
    pub async fn control(vault: Instance<Vault>, request: String) -> Result<String> {
        let s = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            control(
                &s,
                serde_json::from_str(&request).map_err(|_| "InvalidData")?,
            )
            .map(|v| v.to_string())
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }
}
fn control(s: &VaultSession, r: Value) -> Result<Value> {
    let _guard = SERIAL.lock().unwrap();
    // Approval polling only needs policy metadata. Never serialize every note
    // and account across the service connection to display an empty status.
    let d = if r["op"] == "status" {
        json!({"settings":core(s, json!({"op":"read-settings"}))?})
    } else { doc(s)? };
    match r["op"].as_str().unwrap_or("") {
        "status" => {
            if !state().deferred_audit.is_empty() {
                audit(s, "app", "", "unlock", "", "DeferredAuditFlushed")?;
            }
            let mut settings = json!({});
            if let Some(object) = d["settings"].as_object() {
                for (k, v) in object {
                    if k.starts_with("aiAccess") {
                        settings[k] = v.clone();
                    }
                }
            }
            if let Some(cs) = settings["aiAccessClients"].as_array_mut() {
                for c in cs {
                    c.as_object_mut().unwrap().remove("tokenHash");
                }
            }
            let mut st = state();
            st.leases.retain(|l| l.expires.is_none_or(|t| t > Instant::now()));
            let leases: Vec<Value> = st.leases.iter().map(|l| json!({
                "client": l.client, "entryId": l.entry, "field": l.field, "reveal": l.reveal,
                "secondsLeft": l.expires.map(|t| t.saturating_duration_since(Instant::now()).as_secs()),
            })).collect();
            Ok(
                json!({"settings":settings,"leases":leases,"pending":st.pending.values().filter(|p|p.answer.is_none() && p.expires>Instant::now()).map(|p|p.view.clone()).collect::<Vec<_>>(),"socket":st.socket,"helper":std::env::current_exe().ok().and_then(|p|p.parent().map(|p|p.join("pv-mcp"))).map(|p|p.to_string_lossy().into_owned())}),
            )
        }
        "pair" => {
            let code = id();
            state().pair = Some((
                code.clone(),
                r["name"]
                    .as_str()
                    .unwrap_or("Local client")
                    .chars()
                    .take(80)
                    .collect(),
                Instant::now() + Duration::from_secs(120),
            ));
            Ok(json!({"code":code}))
        }
        "approve" => {
            let mut st = state();
            let p = st
                .pending
                .get_mut(r["requestId"].as_str().unwrap_or(""))
                .ok_or("ExpiredRequest")?;
            if p.answer.is_some() || p.expires <= Instant::now() {
                return Err("ExpiredRequest".into());
            }
            let allow = r["allow"] == true;
            if allow {
                if let Some(seconds) = r["leaseSeconds"].as_u64() {
                    let field = p.view["field"].as_str().unwrap_or("");
                    // Grants only remember a field read; "until lock" is limited to low-impact fields.
                    if p.view["kind"] != "secret"
                        || seconds > LEASE_SECONDS
                        || (seconds == 0 && !low_sensitivity(field))
                    {
                        return Err("InvalidData".into());
                    }
                    p.lease = Some(seconds);
                }
            }
            p.answer = Some(allow);
            Ok(json!({"ok":true}))
        }
        "configure" => {
            Ai::cancel_pending();
            let mut patch = json!({});
            for k in [
                "aiAccessEnabled",
                "aiAccessScopes",
                "aiAccessAliases",
                "aiAccessOrdinaryFiles",
            ] {
                if let Some(v) = r.get(k) {
                    patch[k] = v.clone()
                }
            }
            save(s, patch)?;
            Ok(json!({"ok":true}))
        }
        "grant" | "revoke" => {
            Ai::cancel_pending();
            let mut cs = d["settings"]["aiAccessClients"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            if r["op"] == "revoke" {
                cs.retain(|c| c["id"] != r["clientId"])
            } else {
                let c = cs
                    .iter_mut()
                    .find(|c| c["id"] == r["clientId"])
                    .ok_or("UnknownClient")?;
                c["entries"] = r["entries"].clone();
                c["files"] = r["files"].clone();
            }
            save(s, json!({"aiAccessClients":cs}))?;
            Ok(json!({"ok":true}))
        }
        "end_leases" => {
            let mut st = state();
            match r["entryId"].as_str() {
                Some(entry) => st.leases.retain(|l| l.entry != entry || r["field"].as_str().is_some_and(|f| f != l.field)),
                None => st.leases.clear(),
            }
            Ok(json!({"ok":true}))
        }
        _ => Err("Unsupported".into()),
    }
}
