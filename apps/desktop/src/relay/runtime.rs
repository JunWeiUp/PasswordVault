//! One cancellable relay owner per vault. Stop never waits for the network/control mutex.
//! Delegates the connect/cycle/pump/retry/backoff loop to `vault_core::relay_net::runner::RelaySyncRunner`.
use super::{Result, protocol::*, service};
use crate::session::VaultSession;
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
};
use vault_core::relay_net::{
    mesh_sync::{MeshVault, Settings},
    runner::{CyclePrep, RelaySyncObserver, RelaySyncRunner, RunnerHooks},
};
use vault_core::relay_protocol::{BoxPublicKey, BoxSecretKey, Identity};

pub struct Run {
    stop: AtomicBool,
    runner: Mutex<Option<Arc<RelaySyncRunner>>>,
    view: Mutex<Value>,
}

impl Run {
    pub fn stopped(&self) -> bool {
        if self.stop.load(Ordering::SeqCst) {
            return true;
        }
        self.runner
            .lock()
            .ok()
            .and_then(|slot| slot.as_ref().map(|r| !r.is_running()))
            .unwrap_or(false)
    }

    pub fn disconnect(&self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Ok(mut slot) = self.runner.lock() {
            if let Some(runner) = slot.take() {
                runner.stop();
            }
        }
        if let Ok(mut v) = self.view.lock() {
            let updates = v["updates"].clone();
            *v = json!({"transport":"disconnected","online":[],"error":"","updates":updates});
        }
        crate::events::notify("relay");
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
    if let Ok(slot) = run.runner.lock() {
        if let Some(runner) = slot.as_ref() {
            runner.queue_blob_request(peer.clone(), attachment_id.to_owned());
        }
    }
    Ok(json!({"queued": true, "peer": peer, "online": online.iter().any(|p| p == &peer)}))
}

pub fn exit_local(
    s: &Arc<VaultSession>,
    _directory: PathBuf,
    disband: bool,
    local: bool,
) -> Result<String> {
    stop(s);
    let (display, remote) = service::exit_local(s, disband)?;
    let notice = Arc::new(Run {
        stop: AtomicBool::new(true),
        runner: Mutex::new(None),
        view: Mutex::new(
            json!({"transport":"disconnected","online":[],"exit":{"disband":disband,"remote":"pending"}}),
        ),
    });
    runs()
        .lock()
        .map_err(|_| "Storage")?
        .insert(Arc::as_ptr(s) as usize, notice.clone());
    // The worker owns only the old in-memory snapshot, never a vault/session or
    // persistence callback. It cannot restore membership, even after a late reply.
    std::thread::spawn(move || {
        let result = service::notify_exit(remote, disband, local);
        if let Ok(mut view) = notice.view.lock() {
            view["exit"]["remote"] = json!(if result.is_ok() {
                "confirmed"
            } else {
                "failed"
            });
        }
        crate::events::notify("relay");
    });
    crate::events::notify("relay");
    Ok(display)
}

/// Rejected credentials (401/403): stop and prompt. Shared owner policy in vault-core.
pub fn authentication_failure(error: &str) -> bool {
    vault_core::relay_protocol::policy::authentication_failure(error)
}

pub fn block_authentication(s: &Arc<VaultSession>, _directory: PathBuf, error: &str) {
    let run = Arc::new(Run {
        stop: AtomicBool::new(true),
        runner: Mutex::new(None),
        view: Mutex::new(json!({"transport":"disconnected","online":[],"error":error})),
    });
    if let Ok(mut map) = runs().lock() {
        let key = Arc::as_ptr(s) as usize;
        if map
            .get(&key)
            .is_some_and(|r| r.view.lock().is_ok_and(|v| v["exit"].is_object()))
        {
            return;
        }
        map.insert(key, run);
    }
    crate::events::notify("relay");
}

struct DesktopHooks {
    session: Arc<VaultSession>,
    directory: PathBuf,
    local: bool,
}

impl RunnerHooks for DesktopHooks {
    fn before_connect(&self) -> Result<(Settings, Value)> {
        let c = service::read(&self.session)?;
        if service::group(&c)?["group_entry"].is_null() {
            return Err("NotEnrolled".into());
        }
        service::execute(&self.session, json!({"op":"refresh"}), self.local)?;
        let c = service::read(&self.session)?;
        let groups = service::group(&c)?;
        let settings = Settings {
            url: text(&c, "endpoint")?.into(),
            token: text(&c, "token")?.into(),
            password: super::protocol::configured_password(&c)?.map(str::to_owned),
            local: self.local,
            identity: identity(&c)?,
            journal: self.directory.join("vault/relay-private/sdk-journal"),
        };
        Ok((settings, groups))
    }

    fn before_cycle(&self, current_groups: &Value) -> Result<CyclePrep> {
        if service::core(&self.session, json!({"op":"status"}))?["unlocked"] != true {
            return Err("Locked".into());
        }
        service::execute(&self.session, json!({"op":"refresh"}), self.local)?;
        let c = service::read(&self.session)?;
        let groups = service::group(&c)?;
        if groups["group_entry"] != current_groups["group_entry"] {
            return Ok(CyclePrep::Reconnect);
        }
        Ok(CyclePrep::Continue(groups))
    }
}

struct DesktopObserver {
    run: Arc<Run>,
}

impl RelaySyncObserver for DesktopObserver {
    fn on_state(&self, state_json: String) {
        if self.run.stop.load(Ordering::SeqCst) {
            return;
        }
        if let Ok(parsed) = serde_json::from_str::<Value>(&state_json) {
            if let Ok(mut view) = self.run.view.lock() {
                *view = json!({
                    "transport": parsed["transport"],
                    "online": parsed["online"],
                    "error": parsed["error"],
                    "updates": parsed["updates"],
                });
            }
            crate::events::notify("relay");
        }
    }
}

pub fn start(s: Arc<VaultSession>, directory: PathBuf, local: bool) -> Result<()> {
    if service::core(&s, json!({"op":"status"}))?["unlocked"] != true {
        return Err("Locked".into());
    }
    let mut map = runs().lock().map_err(|_| "Storage")?;
    let key = Arc::as_ptr(&s) as usize;
    // An automatic connect must not restart rejected credentials. Explicit actions
    // remove this entry through stop() before starting a new attempt.
    if map.get(&key).is_some_and(|r| {
        !r.stopped()
            || r.view.lock().is_ok_and(|v| {
                v["exit"].is_object() || authentication_failure(v["error"].as_str().unwrap_or(""))
            })
    }) {
        return Ok(());
    }
    let run = Arc::new(Run {
        stop: AtomicBool::new(false),
        runner: Mutex::new(None),
        view: Mutex::new(json!({"transport":"disconnected","online":[]})),
    });
    let hooks: Arc<dyn RunnerHooks> = Arc::new(DesktopHooks {
        session: s.clone(),
        directory,
        local,
    });
    let observer: Arc<dyn RelaySyncObserver> = Arc::new(DesktopObserver { run: run.clone() });
    let runner = RelaySyncRunner::start_with_hooks(Arc::new(Vault(s)), hooks, Some(observer))
        .map_err(|e| e.to_string())?;
    if let Ok(mut slot) = run.runner.lock() {
        *slot = Some(runner);
    }
    map.insert(key, run);
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
            BoxPublicKey::from_slice(&unhex(key.as_str().ok_or("InvalidData")?)?)
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
        let _control = if request["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("relay-mesh-"))
        {
            Some(service::CONTROL.lock().map_err(|_| "Storage")?)
        } else {
            None
        };
        service::core(&self.0, request)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn relay_stop_without_a_connection_never_needs_the_control_lock() {
        let r = Run {
            stop: AtomicBool::new(false),
            runner: Mutex::new(None),
            view: Mutex::new(json!({})),
        };
        let _control = service::CONTROL.lock().unwrap();
        r.disconnect();
        assert!(r.stopped());
        assert_eq!(r.view.lock().unwrap()["transport"], "disconnected");
    }
}
