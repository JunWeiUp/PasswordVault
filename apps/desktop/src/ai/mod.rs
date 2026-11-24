//! App-owned AI policy. The transport never opens a vault or executes content.
use crate::session::VaultSession;
use crate::{Vault, error_code};
use nsh_core::prelude::*;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, Instant},
};
#[cfg(target_os = "macos")]
mod socket;
#[cfg(not(target_os = "macos"))]
mod socket {
    pub fn start(_: std::sync::Arc<crate::session::VaultSession>) -> super::Result<String> {
        Err("Unsupported".into())
    }
}
mod clipboard;
mod crud;
mod notes;
mod projection;
#[cfg(test)]
mod tests;

use projection::{new_item, projection, prune, secret};
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
/// A write refused for chat-redaction placeholders mints a one-shot ticket so the AI can
/// retry the same operation once through its shell, where clients resolve placeholders.
struct Ticket {
    digest: String,
    op: String,
    expires: Instant,
}
const TICKET_SECONDS: u64 = 5 * 60;
const TICKET_LIMIT: usize = 20;
const CLIPBOARD_SECONDS: u64 = 30;
/// A paired client may add at most this many entries per rolling minute.
const ADD_LIMIT: usize = 10;
const ADD_WINDOW: Duration = Duration::from_secs(60);
/// Reserves one write slot for the client, or refuses when the rolling window is full.
fn reserve_add(st: &mut State, client: &str, now: Instant) -> Result<()> {
    let recent = st.adds.entry(client.to_string()).or_default();
    recent.retain(|t| now.duration_since(*t) < ADD_WINDOW);
    if recent.len() >= ADD_LIMIT {
        return Err("RateLimited".into());
    }
    recent.push(now);
    Ok(())
}
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
    socket: Option<String>,
    deferred_audit: Vec<Value>,
    leases: Vec<Lease>,
    /// Bumped when an AI client adds or updates an entry, so the window reloads its list.
    changes: u64,
    /// Latest AI note auto-save notification for the desktop UI.
    last_note_change: Option<Value>,
    /// Recent `add` times per client, for the write rate limit.
    adds: HashMap<String, Vec<Instant>>,
    /// Recent `note_update` times per client, for the note write rate limit.
    note_writes: HashMap<String, Vec<Instant>>,
    /// One-shot shell retry tickets; in memory only, cleared on lock.
    tickets: HashMap<String, Ticket>,
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
    core(s, json!({"op":"list","summaries":true,"richNotes":true}))
}
fn doc_full(s: &VaultSession) -> Result<Value> {
    core(s, json!({"op":"list","richNotes":true}))
}
fn full_item(s: &VaultSession, id: &str) -> Result<Value> {
    core(s, json!({"op":"get","id":id}))
}
fn save(s: &VaultSession, patch: Value) -> Result<()> {
    core(s, json!({"op":"settings","settings":patch})).map(|_| ())
}
fn hash(s: &str) -> String {
    format!("{:x}", Sha256::digest(s.as_bytes()))
}
fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn client_fingerprint(token_hash: &str) -> String {
    let fp = hash(&format!("pv-client-fp:{token_hash}"));
    format!("{}…{}", &fp[..4], &fp[fp.len() - 4..])
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
fn find_client_by_digest<'a>(d: &'a Value, digest: &str) -> Option<&'a Value> {
    d["settings"]["aiAccessClients"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|c| c["tokenHash"] == digest)
}
fn client_digest<'a>(d: &'a Value, digest: &str) -> Result<&'a Value> {
    if d["settings"]["aiAccessEnabled"] != true {
        return Err("Disabled".into());
    }
    let c = find_client_by_digest(d, digest).ok_or("RevokedOrUnknownClient")?;
    if c["paused"] == true {
        return Err("ClientPaused".into());
    }
    Ok(c)
}
fn excluded(d: &Value, item: &Value) -> bool {
    item["id"]
        .as_str()
        .is_some_and(|id| d["settings"]["aiAccessExcludedEntries"][id] == true)
}
fn allowed(d: &Value, _c: &Value, item: &Value) -> bool {
    !item["isDeleted"].as_bool().unwrap_or(false)
        && !excluded(d, item)
        && scope(item).is_some_and(|scope| d["settings"]["aiAccessScopes"][scope] == true)
}
fn entry<'a>(d: &'a Value, c: &Value, r: &Value) -> Result<&'a Value> {
    d["items"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|i| i["id"] == r["id"] && allowed(d, c, i))
        .ok_or("UnscopedOrMissing".into())
}
fn approved_file(d: &Value, _c: &Value, i: &Value, fid: &str) -> bool {
    !excluded(d, i)
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
    let ts = now_unix();
    log.insert(0,json!({"client":cid,"item":item,"operation":op,"requestId":rid,"result":result,"unixSeconds":ts}));
    log.truncate(200);
    let mut patch = json!({"aiAccessAudit": log});
    if op != "unlock" && result != "ClientPaused" && cid != "unknown" && cid != "app" {
        if let Some(mut cs) = d["settings"]["aiAccessClients"].as_array().cloned() {
            if let Some(c) = cs.iter_mut().find(|c| c["id"].as_str() == Some(cid)) {
                let prev = c["callCount"].as_u64().unwrap_or(0);
                c["callCount"] = json!(prev.saturating_add(1));
                c["lastUsedUnix"] = json!(ts);
                c["lastOp"] = json!(op);
                patch["aiAccessClients"] = json!(cs);
            }
        }
    }
    save(s, patch)?;
    state().deferred_audit.clear();
    Ok(())
}
/// Every read checks the live core session, then permission, then a field whitelist.
pub(super) fn request(s: &VaultSession, r: Value) -> Result<Value> {
    if let Some(ticket) = r.get("ticket").and_then(Value::as_str).map(str::to_string) {
        return ticket_request(s, r, &ticket);
    }
    let digest = hash(r["token"].as_str().unwrap_or(""));
    let op = r["op"].as_str().unwrap_or("").to_string();
    match request_digest(s, r, &digest) {
        Err(e)
            if e == "RedactedPlaceholderDetected" && matches!(op.as_str(), "create" | "update") =>
        {
            match mint_ticket(s, &digest, &op) {
                Some(t) => Err(format!("{e}#{t}")),
                None => Err(e),
            }
        }
        other => other,
    }
}
/// Issues a single-use retry ticket bound to this client and operation.
fn mint_ticket(s: &VaultSession, digest: &str, op: &str) -> Option<String> {
    let d = doc(s).ok()?;
    client_digest(&d, digest).ok()?;
    let mut st = state();
    let now = Instant::now();
    st.tickets.retain(|_, t| t.expires > now);
    if st.tickets.len() >= TICKET_LIMIT {
        return None;
    }
    let ticket = uuid::Uuid::new_v4().simple().to_string();
    st.tickets.insert(
        ticket.clone(),
        Ticket {
            digest: digest.to_string(),
            op: op.to_string(),
            expires: now + Duration::from_secs(TICKET_SECONDS),
        },
    );
    Some(ticket)
}
/// Redeems a ticket once. The retry runs with the original client's identity, policy, rate
/// limits and audit; if placeholders are still present the client cannot resolve them.
fn ticket_request(s: &VaultSession, mut r: Value, ticket: &str) -> Result<Value> {
    let t = {
        let mut st = state();
        let now = Instant::now();
        st.tickets.retain(|_, t| t.expires > now);
        st.tickets.remove(ticket)
    }
    .ok_or("TicketInvalid")?;
    match r["op"].as_str().unwrap_or("") {
        "" => r["op"] = json!(t.op),
        op if op == t.op => {}
        _ => return Err("TicketInvalid".into()),
    }
    if let Some(map) = r.as_object_mut() {
        map.remove("ticket");
        map.remove("token");
    }
    match request_digest(s, r, &t.digest) {
        Err(e) if e == "RedactedPlaceholderDetected" => Err("PlaceholderNotResolved".into()),
        other => other,
    }
}
fn request_digest(s: &VaultSession, r: Value, digest: &str) -> Result<Value> {
    // Public CRUD names and `passwordvault:` references resolve against the client's view.
    let tool = match r["op"].as_str().unwrap_or("") {
        t @ ("find" | "read" | "create" | "update" | "delete") => t.to_string(),
        _ => "unsupported".into(),
    };
    // Locked, disabled, unknown-client and routing errors are still audited below.
    let routed = match doc(s) {
        _ if tool == "unsupported" => Err("ReadOnlyUnsupportedOperation".to_string()),
        Ok(d) => client_digest(&d, digest).and_then(|c| crud::route(&d, c, r.clone())),
        Err(e) => Err(e),
    };
    let (r, pre_error) = match routed {
        Ok(r) => (r, None),
        Err(e) => (r, Some(e)),
    };
    let initial = doc(s).ok();
    let c = initial
        .as_ref()
        .and_then(|d| find_client_by_digest(d, digest));
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
    let op = r["op"].as_str().unwrap_or("").to_string();
    let rid = r["requestId"]
        .as_str()
        .and_then(|v| uuid::Uuid::parse_str(v).ok())
        .map(|v| v.to_string())
        .unwrap_or_else(id);
    let mut result = match pre_error {
        Some(e) => Err(e),
        None => request_inner(s, r.clone(), &rid, digest),
    };
    let item = if !item.is_empty() {
        item
    } else {
        result
            .as_ref()
            .ok()
            .and_then(|v| v["id"].as_str())
            .unwrap_or("")
            .to_string()
    };
    let _guard = SERIAL.lock().unwrap();
    if result.is_ok() {
        let final_check = (|| {
            let d = doc(s)?;
            let c = client_digest(&d, digest)?;
            if matches!(
                op.as_str(),
                "add" | "note_update" | "note_attach" | "entry_update" | "entry_delete"
            ) {
                // Added/auto-saved entries need no approval; only the client must still be valid.
            } else if op == "note_list" {
                if d["settings"]["aiAccessScopes"]["notes"] != true {
                    return Err("UnscopedOrMissing".into());
                }
            } else if op == "note_read" || op == "note_history" || op == "note_read_asset" {
                let target = json!({"id": item});
                let found = notes::find_note(&d, &target).ok_or("UnscopedOrMissing")?;
                if !notes::note_readable(&d, c, found) {
                    return Err("UnscopedOrMissing".into());
                }
            } else if op == "search" {
                for row in result.as_ref().unwrap().as_array().into_iter().flatten() {
                    entry(&d, c, &json!({"id":row["id"]}))?;
                }
            } else {
                let i = entry(&d, c, &r)?;
                if let Some(fid) = r["fileId"].as_str().filter(|_| op == "get")
                    && !approved_file(&d, c, i, fid)
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
        .map(|v| {
            if v["approval"] == "lease" {
                "AllowedByLease"
            } else {
                "Allowed"
            }
        })
        .unwrap_or_else(|e| e.as_str());
    if doc(s).is_ok() {
        audit(s, &cid, &item, &tool, &rid, outcome)?;
    } else {
        let mut st = state();
        st.deferred_audit.push(
            json!({"client":cid,"item":item,"operation":tool,"requestId":rid,"result":"Locked","unixSeconds":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs()}),
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
    let rid = request_id.to_string();
    if op == "add" {
        return add(s, &r, digest);
    }
    if op == "entry_update" {
        return crud::entry_update(s, &r, digest);
    }
    if op == "entry_delete" {
        return crud::entry_delete(s, &r, digest);
    }
    if op == "note_update" {
        return notes::note_update(s, &r, digest);
    }
    if op == "note_attach" {
        return notes::note_attach(s, &r, digest);
    }
    if matches!(
        op,
        "note_list" | "note_read" | "note_read_asset" | "note_history"
    ) {
        let _guard = SERIAL.lock().unwrap();
        let d = doc(s)?;
        let c = client_digest(&d, digest)?;
        return match op {
            "note_list" => notes::note_list(s, &d, c, &r),
            "note_read" => notes::note_read(s, &d, c, &r),
            "note_read_asset" => notes::note_read_asset(s, &d, c, &r),
            "note_history" => notes::note_history(s, &d, c, &r),
            _ => unreachable!(),
        };
    }
    let field = r["field"].as_str().unwrap_or("").to_string();
    // Secrets go to the clipboard unless the client explicitly asks to see them.
    let reveal = r["delivery"] == "reveal";
    let (approval, revision, leased) = {
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
        let i = entry(&d, c, &r).ok();
        if op == "get_secret" {
            let item = i.ok_or("UnscopedOrMissing")?;
            secret(item, &field)?;
        }
        let item_id = i
            .map(|i| i["id"].as_str().unwrap_or("").to_string())
            .unwrap_or_default();
        let leased = op == "get_secret"
            && state()
                .leases
                .iter()
                .any(|l| lease_matches(l, &cid, &item_id, &field, reveal));
        if op == "get_secret" && !leased {
            let i = i.unwrap();
            let mut st = state();
            if st.pending.len() >= 8 {
                return Err("Busy".into());
            }
            st.pending.insert(rid.clone(), Pending {
                view: json!({
                    "requestId": rid, "client": c["name"], "item": i["title"],
                    "kind": "secret",
                    "grant": false,
                    "field": json!(field),
                    "delivery": json!(if reveal { "reveal" } else { "clipboard" }),
                    "leaseUntilLock": low_sensitivity(&field),
                    "leaseMinutes": LEASE_SECONDS / 60,
                    // Untrusted client text: bounded before it reaches the approval sheet.
                    "purpose": r["purpose"].as_str().map(|p| p.chars().take(120).collect::<String>()),
                }),
                expires: Instant::now() + Duration::from_secs(60),
                answer: None,
                lease: None,
            });
            (true, hash(&i.to_string()), false)
        } else {
            (
                false,
                i.map_or(String::new(), |i| hash(&i.to_string())),
                leased,
            )
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
    let _guard = SERIAL.lock().unwrap();
    let result: Result<Value> = (|| {
        decision?;
        let d = doc(s)?;
        let c = client_digest(&d, digest)?;
        match op {
            "search" => {
                let q = r["query"].as_str().unwrap_or("").to_lowercase();
                Ok(json!(
                    d["items"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter(|i| allowed(&d, c, i)
                            && r["id"].as_str().is_none_or(|id| i["id"] == id)
                            && format!(
                                "{} {} {} {} {} {} {} {}",
                                i["title"],
                                i["username"],
                                i["url"],
                                i["tags"],
                                i["device"]["aliases"],
                                i["device"]["host"],
                                i["device"]["services"]
                                    .as_array()
                                    .into_iter()
                                    .flatten()
                                    .map(|svc| svc["name"].as_str().unwrap_or(""))
                                    .collect::<Vec<_>>()
                                    .join(" "),
                                d["settings"]["aiAccessAliases"][i["id"].as_str().unwrap_or("")]
                            )
                            .to_lowercase()
                            .contains(&q))
                        .take(100)
                        .map(|i| projection(i, false))
                        .collect::<Vec<_>>()
                ))
            }
            "get" if r.get("fileId").is_none() => {
                let i = entry(&d, c, &r)?;
                let owned;
                let target = if i["type"] == "secureNote" && i["noteSummary"] == true {
                    owned = full_item(s, i["id"].as_str().ok_or("InvalidData")?)?;
                    &owned
                } else {
                    i
                };
                let mut out = projection(target, true);
                out["version"] = target["updatedAt"].clone();
                let files: Vec<&String> = d["settings"]["aiAccessOrdinaryFiles"]
                    [target["id"].as_str().unwrap_or("")]
                .as_object()
                .into_iter()
                .flatten()
                .filter(|(fid, _)| approved_file(&d, c, target, fid))
                .map(|(fid, _)| fid)
                .collect();
                if !files.is_empty() {
                    out["files"] = json!(files);
                }
                Ok(out)
            }
            "get_secret" => {
                let i = entry(&d, c, &r)?;
                if hash(&i.to_string()) != revision {
                    return Err("EntryChanged".into());
                }
                let owned;
                let target = if i["type"] == "secureNote" && i["noteSummary"] == true {
                    owned = full_item(s, i["id"].as_str().ok_or("InvalidData")?)?;
                    &owned
                } else {
                    i
                };
                let value = secret(target, &field)?.as_str().ok_or("DeniedField")?;
                if let Some(seconds) = lease {
                    let entry_id = i["id"].as_str().unwrap_or("").to_string();
                    let cid = c["id"].as_str().unwrap_or("").to_string();
                    let mut st = state();
                    st.leases
                        .retain(|l| !(l.client == cid && l.entry == entry_id && l.field == field));
                    st.leases.push(Lease {
                        client: cid,
                        entry: entry_id,
                        field: field.clone(),
                        reveal,
                        expires: (seconds > 0)
                            .then(|| Instant::now() + Duration::from_secs(seconds)),
                    });
                }
                let approval = if leased {
                    "lease"
                } else if lease.is_some() {
                    "leaseStarted"
                } else {
                    "once"
                };
                if reveal {
                    return Ok(json!({"value":value,"approval":approval}));
                }
                clipboard::put(value, CLIPBOARD_SECONDS)?;
                Ok(
                    json!({"delivered": "clipboard", "clearsAfterSeconds": CLIPBOARD_SECONDS, "approval": approval}),
                )
            }
            "get" => {
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
                Ok(json!({"text":chunk,"nextOffset":next,"eof":next>=text.chars().count()}))
            }
            _ => Err("ReadOnlyUnsupportedOperation".into()),
        }
    })();
    result
}
/// Adds one entry to the requesting client's list, like Settings would.
fn grant_entry(s: &VaultSession, digest: &str, entry_id: &str) -> Result<()> {
    let _guard = SERIAL.lock().unwrap();
    let d = doc(s)?;
    let cid = client_digest(&d, digest)?["id"].clone();
    let mut cs = d["settings"]["aiAccessClients"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let c = cs
        .iter_mut()
        .find(|c| c["id"] == cid)
        .ok_or("RevokedOrUnknownClient")?;
    if !c["entries"].is_object() {
        c["entries"] = json!({});
    }
    c["entries"][entry_id] = json!(true);
    save(s, json!({"aiAccessClients":cs}))
}
/// Adds a new entry straight away, without approval. Wallets are excluded; existing
/// records are never touched. The entry joins the client's list so it can read it back.
fn add(s: &VaultSession, r: &Value, digest: &str) -> Result<Value> {
    let mut item = new_item(r)?;
    let incoming = item["customFields"].as_array().cloned().unwrap_or_default();
    let (keep, lines) = projection::split_fields(incoming, 0);
    let folded = lines.len();
    if keep.is_empty() {
        if let Some(map) = item.as_object_mut() {
            map.remove("customFields");
        }
    } else {
        item["customFields"] = json!(keep);
    }
    projection::append_note(&mut item["note"], &lines);
    {
        let _guard = SERIAL.lock().unwrap();
        let d = doc(s)?;
        let cid = client_digest(&d, digest)?["id"]
            .as_str()
            .unwrap_or("")
            .to_string();
        if item["type"] == "device" && core(s, json!({"op":"devices-status"}))?["enabled"] != true {
            return Err("DevicesNotEnabled".into());
        }
        reserve_add(&mut state(), &cid, Instant::now())?;
        if let Err(e) = core(s, json!({"op":"save","item":item,"richNotes":true})) {
            // A failed save does not use up the client's quota.
            if let Some(recent) = state().adds.get_mut(&cid) {
                recent.pop();
            }
            return Err(e);
        }
    }
    grant_entry(s, digest, item["id"].as_str().unwrap_or(""))?;
    state().changes += 1;
    let mut out = json!({"id":item["id"],"type":item["type"],"title":item["title"],"added":true});
    if folded > 0 {
        out["fieldsMovedToNote"] = json!(folded);
    }
    Ok(out)
}
/// Read-only local AI access with encrypted grants and single-request approvals.
#[module]
pub struct Ai;
#[module]
impl Ai {
    /// Clears outstanding approvals when the UI transitions to locked.
    pub fn cancel_pending() {
        let mut st = state();
        st.leases.clear();
        st.tickets.clear();
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
    } else {
        doc(s)?
    };
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
                    if let Some(obj) = c.as_object_mut() {
                        let fp_source = obj
                            .get("tokenHash")
                            .and_then(|v| v.as_str())
                            .or_else(|| obj.get("id").and_then(|v| v.as_str()))
                            .unwrap_or("");
                        let fp = client_fingerprint(fp_source);
                        obj.remove("tokenHash");
                        obj.insert("fingerprint".into(), json!(fp));
                    }
                }
            }
            let mut st = state();
            st.leases
                .retain(|l| l.expires.is_none_or(|t| t > Instant::now()));
            let leases: Vec<Value> = st.leases.iter().map(|l| json!({
                "client": l.client, "entryId": l.entry, "field": l.field, "reveal": l.reveal,
                "secondsLeft": l.expires.map(|t| t.saturating_duration_since(Instant::now()).as_secs()),
            })).collect();
            Ok(
                json!({"settings":settings,"leases":leases,"changes":st.changes,"lastNoteChange":st.last_note_change,"pending":st.pending.values().filter(|p|p.answer.is_none() && p.expires>Instant::now()).map(|p|p.view.clone()).collect::<Vec<_>>(),"socket":st.socket,"helper":std::env::current_exe().ok().and_then(|p|p.parent().map(|p|p.join("pv-mcp"))).map(|p|p.to_string_lossy().into_owned())}),
            )
        }
        "pair" => {
            // One step: the app creates the client and hands its token to the UI exactly once.
            if d["settings"]["aiAccessEnabled"] != true {
                return Err("Disabled".into());
            }
            let name: String = r["name"]
                .as_str()
                .unwrap_or("")
                .trim()
                .chars()
                .take(80)
                .collect();
            let token = format!("{}{}", id(), id());
            let token_hash = hash(&token);
            let fp = client_fingerprint(&token_hash);
            let cid = id();
            let created = now_unix();
            let mut clients = d["settings"]["aiAccessClients"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            clients.push(json!({
                "id": cid,
                "name": if name.is_empty() { "Local client".into() } else { name },
                "tokenHash": token_hash,
                "createdUnix": created,
                "paused": false,
                "entries": {},
                "files": {}
            }));
            save(s, json!({"aiAccessClients":clients}))?;
            Ok(json!({"clientId":cid,"token":token,"fingerprint":fp}))
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
                "aiAccessExcludedEntries",
                "aiAccessNoteAutoWrite",
                "aiAccessNoteWritableCategories",
                "aiAccessNoteAssetText",
            ] {
                if let Some(v) = r.get(k) {
                    patch[k] = v.clone()
                }
            }
            save(s, patch)?;
            Ok(json!({"ok":true}))
        }
        "rename" => {
            let name: String = r["name"]
                .as_str()
                .unwrap_or("")
                .trim()
                .chars()
                .take(80)
                .collect();
            if name.is_empty() {
                return Err("InvalidData".into());
            }
            let mut cs = d["settings"]["aiAccessClients"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let c = cs
                .iter_mut()
                .find(|c| c["id"] == r["clientId"])
                .ok_or("UnknownClient")?;
            c["name"] = json!(name);
            save(s, json!({"aiAccessClients":cs}))?;
            Ok(json!({"ok":true}))
        }
        "set_paused" => {
            let cid = r["clientId"].as_str().ok_or("InvalidData")?;
            let paused = r["paused"].as_bool().ok_or("InvalidData")?;
            let mut cs = d["settings"]["aiAccessClients"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let c = cs
                .iter_mut()
                .find(|c| c["id"] == cid)
                .ok_or("UnknownClient")?;
            c["paused"] = json!(paused);
            if paused {
                let mut st = state();
                st.leases.retain(|l| l.client != cid);
                for p in st.pending.values_mut() {
                    p.answer = Some(false);
                }
            }
            save(s, json!({"aiAccessClients":cs}))?;
            Ok(json!({"ok":true}))
        }
        "revoke_many" => {
            Ai::cancel_pending();
            let ids: Vec<String> = r["clientIds"]
                .as_array()
                .ok_or("InvalidData")?
                .iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect();
            let mut cs = d["settings"]["aiAccessClients"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let before = cs.len();
            cs.retain(|c| {
                !c["id"]
                    .as_str()
                    .is_some_and(|cid| ids.iter().any(|x| x == cid))
            });
            state()
                .leases
                .retain(|l| !ids.iter().any(|x| x == &l.client));
            save(s, json!({"aiAccessClients":cs}))?;
            Ok(json!({"ok":true,"removed":before.saturating_sub(cs.len())}))
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
                Some(entry) => st.leases.retain(|l| {
                    l.entry != entry || r["field"].as_str().is_some_and(|f| f != l.field)
                }),
                None => st.leases.clear(),
            }
            Ok(json!({"ok":true}))
        }
        _ => Err("Unsupported".into()),
    }
}
