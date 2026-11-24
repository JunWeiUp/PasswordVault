//! One cancellable relay owner per vault. Stop never waits for the network/control mutex.
use super::{Result, protocol::*, service};
use vault_core::relay_net::mesh_sync::{MeshSync, MeshVault, Settings};
use vault_core::relay_protocol::{BoxPublicKey, BoxSecretKey, Identity};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
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
    /// The open sync session, so `disconnect` can close it without the control lock.
    connection: Mutex<Option<Arc<MeshSync>>>,
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
    let req = vault_core::relay_net::mesh_sync::blob_request(attachment_id);
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
/// The vault as seen by the shared sync session; mesh writes serialize with group actions.
struct Vault(Arc<VaultSession>);
impl MeshVault for Vault {
    fn command(&self, request: Value) -> Result<Value> {
        let _control = if request["op"].as_str().is_some_and(|op| op.starts_with("relay-mesh-")) {
            Some(service::CONTROL.lock().map_err(|_| "Storage")?)
        } else {
            None
        };
        service::core(&self.0, request)
    }
}
fn connected(s: &Arc<VaultSession>, run: &Run, local: bool) -> Result<()> {
    let c = service::read(s)?;
    if service::group(&c)?["group_entry"].is_null() {
        return Err("NotEnrolled".into());
    }
    service::execute(s, json!({"op":"refresh"}), local)?;
    let mut c = service::read(s)?;
    if run.stopped() {
        return Err("Locked".into());
    }
    run.set("connecting", json!([]), "");
    let sync = Arc::new(MeshSync::connect(
        Arc::new(Vault(s.clone())),
        Settings {
            url: text(&c, "endpoint")?.into(),
            token: text(&c, "token")?.into(),
            password: super::protocol::configured_password(&c)?.map(str::to_owned),
            local,
            identity: identity(&c)?,
            journal: run.directory.join("vault/relay-private/sdk-journal"),
        },
    )?);
    *run.connection.lock().map_err(|_| "Storage")? = Some(sync.clone());
    if run.stopped() {
        return Err("Locked".into());
    }
    run.set("connected", json!([]), "");
    while !run.stopped() {
        if service::core(s, json!({"op":"status"}))?["unlocked"] != true {
            return Err("Locked".into());
        }
        let old_group = service::group(&c)?;
        service::execute(s, json!({"op":"refresh"}), local)?;
        c = service::read(s)?;
        let groups = service::group(&c)?;
        if groups["group_entry"] != old_group["group_entry"] {
            return Ok(());
        }
        let drained: Vec<(String, Vec<u8>)> =
            run.blob_outbox.lock().map(|mut q| q.drain(..).collect()).unwrap_or_default();
        for (peer, payload) in drained {
            sync.queue(&peer, payload)?;
        }
        let round = sync.cycle(&groups, false)?;
        run.set("connected", round["online"].clone(), "");
        if round["changed"] == true {
            run.changed();
        }
        let pumped = sync.pump(Duration::from_secs(5))?;
        if pumped["changed"] == true {
            run.changed();
        }
        if !pumped["reconnect"].is_null() {
            return Ok(());
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
