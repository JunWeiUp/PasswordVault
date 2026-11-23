//! One cancellable relay owner per vault. Stop never waits for the network/control mutex.
use super::{Result, protocol::*, service};
use vault_core::relay_net::{Journal, connection::Connection};
use vault_core::relay_protocol::{BoxPublicKey, BoxSecretKey, Identity};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use crate::session::VaultSession;
pub struct Run {
    directory: std::path::PathBuf,
    stop: AtomicBool,
    /// The open connection, so `disconnect` can close it without the control lock.
    connection: Mutex<Option<Arc<Connection>>>,
    view: Mutex<Value>,
    blob_outbox: Mutex<std::collections::VecDeque<(String, Vec<u8>)>>,
}
impl Run {
    pub fn stopped(&self) -> bool {
        self.stop.load(Ordering::SeqCst)
    }
    fn changed(&self) {
        if let Ok(mut v) = self.view.lock() {
            let n = v["updates"].as_u64().unwrap_or(0) + 1;
            v["updates"] = json!(n);
        }
    }
    fn set(&self, status: &str, online: Value, error: &str) {
        if let Ok(mut v) = self.view.lock() {
            let updates = v["updates"].clone();
            *v = json!({"transport":status,"online":online,"error":error,"updates":updates});
        }
    }
    pub fn disconnect(&self) {
        self.stop.store(true, Ordering::SeqCst);
        self.close_connection();
        self.set("disconnected", json!([]), "");
    }
    fn close_connection(&self) {
        if let Ok(mut slot) = self.connection.lock() {
            if let Some(connection) = slot.take() {
                connection.close();
            }
        }
    }
    fn wait(&self, duration: Duration) {
        let until = Instant::now() + duration;
        while !self.stopped() && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}
fn runs() -> &'static Mutex<HashMap<usize, Arc<Run>>> {
    static RUNS: OnceLock<Mutex<HashMap<usize, Arc<Run>>>> = OnceLock::new();
    RUNS.get_or_init(Default::default)
}
pub fn stop(s: &Arc<VaultSession>) {
    if let Ok(mut map) = runs().lock() {
        if let Some(run) = map.remove(&(Arc::as_ptr(s) as usize)) {
            run.disconnect();
        }
    }
}
pub fn view(s: &Arc<VaultSession>) -> Value {
    runs()
        .lock()
        .ok()
        .and_then(|m| m.get(&(Arc::as_ptr(s) as usize)).cloned())
        .and_then(|r| r.view.lock().ok().map(|v| v.clone()))
        .unwrap_or(json!({"transport":"disconnected","online":[]}))
}

/// Queues an on-demand L3 attachment download request to an online mesh peer (or source peer).
pub fn request_blob(
    s: &Arc<VaultSession>,
    note_id: &str,
    attachment_id: &str,
    source_device: Option<&str>,
) -> Result<Value> {
    let run = runs()
        .lock()
        .ok()
        .and_then(|m| m.get(&(Arc::as_ptr(s) as usize)).cloned());
    let Some(run) = run.filter(|r| !r.stopped()) else {
        let _ = service::core(
            s,
            json!({"op":"note-attachment-state","noteId":note_id,"id":attachment_id,"state":"failed","errorReason":"RelayDisconnected"}),
        );
        return Err("RelayDisconnected".into());
    };
    let snapshot = run.view.lock().ok().map(|v| v.clone()).unwrap_or_default();
    if snapshot["transport"].as_str() != Some("connected") {
        let _ = service::core(
            s,
            json!({"op":"note-attachment-state","noteId":note_id,"id":attachment_id,"state":"failed","errorReason":"RelayDisconnected"}),
        );
        return Err("RelayDisconnected".into());
    }
    let online: Vec<String> = snapshot["online"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
    let target = source_device
        .filter(|src| !src.is_empty() && online.iter().any(|p| p == src))
        .map(str::to_owned)
        .or_else(|| online.first().cloned())
        .or_else(|| source_device.filter(|s| !s.is_empty()).map(str::to_owned));
    let Some(peer) = target else {
        let _ = service::core(
            s,
            json!({"op":"note-attachment-state","noteId":note_id,"id":attachment_id,"state":"failed","errorReason":"PeerOffline"}),
        );
        return Err("PeerOffline".into());
    };
    service::core(
        s,
        json!({"op":"note-attachment-state","noteId":note_id,"id":attachment_id,"state":"downloading"}),
    )?;
    let req = canonical(&json!({
        "version": super::mesh::VERSION,
        "kind": "mesh-blob-req",
        "attachmentId": attachment_id,
    }));
    if let Ok(mut outbox) = run.blob_outbox.lock() {
        outbox.push_back((peer.clone(), req));
    }
    Ok(json!({"queued": true, "peer": peer, "online": online.iter().any(|p| p == &peer)}))
}
use vault_core::relay_protocol::policy;
pub fn exit_local(s: &Arc<VaultSession>, directory: std::path::PathBuf, disband: bool, local: bool) -> Result<String> {
    stop(s);
    let (display, remote) = service::exit_local(s, disband)?;
    let notice = Arc::new(Run {
        directory, stop: AtomicBool::new(true), connection: Mutex::new(None),
        view: Mutex::new(json!({"transport":"disconnected","online":[],"exit":{"disband":disband,"remote":"pending"}})),
        blob_outbox: Mutex::new(std::collections::VecDeque::new()),
    });
    runs().lock().map_err(|_| "Storage")?.insert(Arc::as_ptr(s) as usize, notice.clone());
    // The worker owns only the old in-memory snapshot, never a vault/session or
    // persistence callback. It cannot restore membership, even after a late reply.
    std::thread::spawn(move || {
        let result = service::notify_exit(remote, disband, local);
        if let Ok(mut view) = notice.view.lock() {
            view["exit"]["remote"] = json!(if result.is_ok() { "confirmed" } else { "failed" });
        }
    });
    Ok(display)
}

/// Rejected credentials (401/403): stop and prompt. Shared owner policy in vault-core.
pub fn authentication_failure(error: &str) -> bool {
    vault_core::relay_protocol::policy::authentication_failure(error)
}
pub fn block_authentication(s: &Arc<VaultSession>, directory: std::path::PathBuf, error: &str) {
    let run = Arc::new(Run {
        directory, stop: AtomicBool::new(true), connection: Mutex::new(None),
        view: Mutex::new(json!({"transport":"disconnected","online":[],"error":error})),
        blob_outbox: Mutex::new(std::collections::VecDeque::new()),
    });
    if let Ok(mut map) = runs().lock() {
        let key = Arc::as_ptr(s) as usize;
        if map.get(&key).is_some_and(|r| r.view.lock().is_ok_and(|v| v["exit"].is_object())) { return; }
        map.insert(key, run);
    }
}
pub fn start(s: Arc<VaultSession>, directory: std::path::PathBuf, local: bool) -> Result<()> {
    if service::core(&s, json!({"op":"status"}))?["unlocked"] != true {
        return Err("Locked".into());
    }
    let mut map = runs().lock().map_err(|_| "Storage")?;
    let key = Arc::as_ptr(&s) as usize;
    // An automatic connect must not restart rejected credentials. Explicit actions
    // remove this entry through stop() before starting a new attempt.
    if map.get(&key).is_some_and(|r| !r.stopped() || r.view.lock().is_ok_and(|v| v["exit"].is_object() || authentication_failure(v["error"].as_str().unwrap_or("")))) {
        return Ok(());
    }
    let run = Arc::new(Run {
        directory,
        stop: AtomicBool::new(false),
        connection: Mutex::new(None),
        view: Mutex::new(json!({"transport":"disconnected","online":[]})),
        blob_outbox: Mutex::new(std::collections::VecDeque::new()),
    });
    map.insert(key, run.clone());
    std::thread::spawn(move || {
        let mut backoff = 0;
        while !run.stopped() {
            let attempt = Instant::now();
            let result = connected(&s, &run, local);
            if run.stopped() {
                break;
            }
            match result {
                Err(ref e) if e == "Locked" || e == "NotEnrolled" || e == "GroupAccessRevoked" || authentication_failure(e) => {
                    run.set(
                        "disconnected",
                        json!([]),
                        if e == "NotEnrolled" { "" } else { e },
                    );
                    break;
                }
                Err(e) => {
                    run.set("reconnecting", json!([]), &e);
                    // Shared policy: double up to 30 s; a connection that stayed up for
                    // 120 s is a fresh failure, not part of a tight retry storm.
                    backoff = match policy::retry(&e, backoff, attempt.elapsed().as_secs()) {
                        policy::Retry::After(delay) => delay,
                        policy::Retry::Stop => break,
                    };
                }
                Ok(()) => {
                    backoff = match policy::retry("", backoff, attempt.elapsed().as_secs()) {
                        policy::Retry::After(delay) => delay,
                        policy::Retry::Stop => break,
                    };
                }
            }
            run.close_connection();
            run.wait(Duration::from_secs(backoff));
        }
        run.close_connection();
        run.stop.store(true, Ordering::SeqCst);
    });
    Ok(())
}
pub fn identity(c: &Value) -> Result<Identity> {
    let g = service::group(c)?;
    let raw = zeroize::Zeroizing::new(
        STANDARD
            .decode(text(c, "secret")?)
            .map_err(|_| "InvalidData")?,
    );
    let secret = BoxSecretKey::from_slice(&raw).ok_or("InvalidData")?;
    let mut trusted = BTreeMap::new();
    for (id, key) in g["trusted_peers"].as_object().ok_or("InvalidData")? {
        trusted.insert(
            id.clone(),
            BoxPublicKey::from_slice(&unhex(
                key.as_str().ok_or("InvalidData")?,
            )?)
            .ok_or("InvalidData")?,
        );
    }
    Ok(Identity {
        app: "passwordvault".into(),
        group: text(c, "group")?.into(),
        device: text(c, "device")?.into(),
        secret,
        trusted,
    })
}
/// Offline-message journal of the current device (the SDK's format, shared with mobile).
fn journal(run: &Run) -> Result<Journal> {
    Journal::open(&run.directory.join("vault/relay-private/sdk-journal")).map_err(|_| "Storage".into())
}
fn connected(s: &Arc<VaultSession>, run: &Run, local: bool) -> Result<()> {
    let c = service::read(s)?;
    if service::group(&c)?["group_entry"].is_null() {
        return Err("NotEnrolled".into());
    }
    service::execute(s, json!({"op":"refresh"}), local)?;
    let journal = journal(run)?;
    let _ = journal.cleanup();
    let mut c = service::read(s)?;
    if run.stopped() {
        return Err("Locked".into());
    }
    run.set("connecting", json!([]), "");
    let connection = Arc::new(Connection::connect(
        text(&c, "endpoint")?,
        text(&c, "token")?,
        super::protocol::configured_password(&c)?,
        identity(&c)?,
        local,
        Some(journal),
    )?);
    *run.connection.lock().map_err(|_| "Storage")? = Some(connection.clone());
    if run.stopped() {
        return Err("Locked".into());
    }
    // File envelopes are sealed with the same identity as messages.
    let sealing = identity(&c)?;
    run.set("connected", json!([]), "");
    let check = || if run.stopped() { Err("Locked".to_owned()) } else { Ok(()) };
    let mut next = Instant::now();
    let mut sent = HashMap::<String, String>::new();
    let mut undecryptable_seen = HashSet::<String>::new();
    // Only members of a personal device group sync (symmetric mesh).
    let mut mesh_peers: Vec<String> = Vec::new();
    // Delivers one packet: small ones as journaled offline messages, the rest as files.
    let deliver = |c: &Value, peer: &str, id: &str, data: &[u8]| -> Result<()> {
        if data.len() <= 128 * 1024 {
            connection.message(peer, data, true, Some(id))?;
        } else {
            let files = super::files::Files::new(
                text(c, "endpoint")?,
                text(c, "token")?,
                super::protocol::configured_password(c)?,
                local,
                &check,
            )?;
            let (descriptor, cipher) = super::files::prepare(&sealing, peer, data)?;
            files.upload(&descriptor, &cipher)?;
        }
        Ok(())
    };
    while !run.stopped() {
        if Instant::now() >= next {
            if service::core(s, json!({"op":"status"}))?["unlocked"] != true {
                return Err("Locked".into());
            }
            let old_group = service::group(&c)?;
            service::execute(s, json!({"op":"refresh"}), local)?;
            c = service::read(s)?;
            if service::group(&c)?["group_entry"] != old_group["group_entry"] {
                return Ok(());
            }
            let online: Vec<String> = connection.peers()?["devices"]
                .as_array()
                .ok_or("InvalidData")?
                .iter()
                .filter(|d| d["app"] == "passwordvault" && d["group"] == c["group"])
                .filter_map(|d| d["device"].as_str().map(str::to_owned))
                .collect();
            run.set("connected", json!(online), "");
            mesh_peers = super::mesh::ensure(s, &c)?.unwrap_or_default();
            for (peer, data) in super::mesh::outgoing(s, &mesh_peers)? {
                let data = zeroize::Zeroizing::new(data);
                let signature = format!("{}:{}", digest(&data), super::groups::now() / 3600);
                if sent.get(&peer) == Some(&signature) {
                    continue;
                }
                let id = digest(format!("{peer}{signature}").as_bytes())[..32].to_string();
                deliver(&c, &peer, &id, &data)?;
                sent.insert(peer, signature);
            }
            let files = super::files::Files::new(
                text(&c, "endpoint")?,
                text(&c, "token")?,
                super::protocol::configured_password(&c)?,
                local,
                &check,
            )?;
            for descriptor in files.inbox()? {
                let from = text(&descriptor, "from")?;
                // Files from outside the signed roster can never be applied: drop them.
                if !mesh_peers.iter().any(|p| p == from) {
                    files.acknowledge(text(&descriptor, "id")?)?;
                    continue;
                }
                let cipher = files.download(&descriptor)?;
                let plain = super::files::decrypt(&sealing, from, &descriptor, &cipher)?;
                receive(s, run, from, &plain)?;
                files.acknowledge(text(&descriptor, "id")?)?;
            }
            next = Instant::now() + Duration::from_secs(5);
        }
        let drained: Vec<(String, Vec<u8>)> = run
            .blob_outbox
            .lock()
            .map(|mut q| q.drain(..).collect())
            .unwrap_or_default();
        for (peer, payload) in drained {
            if mesh_peers.contains(&peer) {
                let id = uuid::Uuid::new_v4().simple().to_string();
                if let Err(e) = deliver(&c, &peer, &id, &payload) {
                    if payload.len() <= 128 * 1024 { return Err(e); }
                }
            }
        }
        let wait = next.saturating_duration_since(Instant::now()).min(Duration::from_millis(500));
        let Some(event) = connection.next_event(wait)? else { continue };
        match event["type"].as_str() {
            Some("message") => {
                let from = text(&event, "from")?;
                let id = text(&event, "id")?;
                let data = zeroize::Zeroizing::new(
                    STANDARD.decode(text(&event, "data")?).map_err(|_| "InvalidData")?,
                );
                let value: Value = serde_json::from_slice(&data).unwrap_or(Value::Null);
                // Obsolete access/capability controls from old clients are ignored.
                let control = value["format"] == "passwordvault.access.v1"
                    || value["format"] == "passwordvault.capabilities.v1";
                if !control && mesh_peers.iter().any(|p| p == from) {
                    receive(s, run, from, &data)?;
                }
                connection.acknowledge(from, id, event["offline"] == true)?;
            }
            Some("undecryptable") => {
                // A sender that joined after we connected (or before our roster refreshed):
                // reconnect once with fresh keys and the relay redelivers. Still not a
                // member, or a corrupt envelope from a trusted one: drop it for good.
                let from = text(&event, "from")?;
                let id = text(&event, "id")?;
                if event["trusted"] != true
                    && (mesh_peers.iter().any(|p| p == from)
                        || undecryptable_seen.insert(format!("{from}/{id}")))
                {
                    return Ok(());
                }
                connection.acknowledge(from, id, event["offline"] == true)?;
            }
            Some("group.changed") => {
                // The relay announces its current revision after every hello; reconnect
                // only for a newer roster, otherwise the hello loops forever.
                let current = unpack(&service::group(&c)?["group_entry"])?;
                if event["revision"].as_u64().unwrap_or(0) > current["revision"].as_u64().unwrap_or(0) {
                    return Ok(());
                }
            }
            Some("peer.up") => sent.clear(),
            _ => {}
        }
    }
    Ok(())
}
/// Applies a symmetric-sync packet and queues any on-demand attachment reply.
fn receive(s: &Arc<VaultSession>, run: &Run, from: &str, data: &[u8]) -> Result<()> {
    let (changed, reply) = super::mesh::receive_with_reply(s, from, data)?;
    if changed {
        run.changed();
    }
    if let Some(reply) = reply {
        if let Ok(mut outbox) = run.blob_outbox.lock() {
            outbox.push_back((from.to_string(), reply));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn relay_stop_without_a_connection_never_needs_the_control_lock() {
        let r = Run {
            directory: "/tmp".into(),
            stop: AtomicBool::new(false),
            connection: Mutex::new(None),
            view: Mutex::new(json!({})),
            blob_outbox: Mutex::new(std::collections::VecDeque::new()),
        };
        let _control = service::CONTROL.lock().unwrap();
        r.disconnect();
        assert!(r.stopped());
        assert_eq!(r.view.lock().unwrap()["transport"], "disconnected");
    }
}
