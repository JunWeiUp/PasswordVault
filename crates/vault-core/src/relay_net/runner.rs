//! Unified personal-sync runner and group-state projection shared across Desktop, iOS, and Android.
//!
//! `RelaySyncRunner` owns the full `connect -> cycle -> pump -> policy::retry -> backoff` loop
//! on a single cancellable background thread with `Condvar`-based instant wake and stop.
//! `group_summary` derives all UI-facing group fields (roster, pending drafts, join codes,
//! invitations) from the signed `groups` JSON in one place.

use super::{
    ffi::RelayError,
    mesh_sync::{MeshSync, MeshVault, Settings},
    Result,
};
use crate::relay_protocol::{policy, text, unpack, BoxPublicKey, BoxSecretKey, Identity};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, VecDeque},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Condvar, Mutex,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn format_join_code(request: &Value) -> String {
    let Some(payload) = request["payload"].as_str() else {
        return String::new();
    };
    let Ok(raw) = STANDARD.decode(payload) else {
        return String::new();
    };
    let digest = hex::encode(Sha256::digest(&raw)).to_uppercase();
    let chars: Vec<char> = digest.chars().take(12).collect();
    if chars.len() < 12 {
        return String::new();
    }
    format!(
        "{}-{}-{}",
        chars[0..4].iter().collect::<String>(),
        chars[4..8].iter().collect::<String>(),
        chars[8..12].iter().collect::<String>()
    )
}

/// Pure projection of the signed `groups` JSON into all fields needed by Desktop, iOS and Android UIs.
pub fn group_summary(groups: &Value, device_id: &str, now_secs: u64) -> Value {
    let managed = groups["group_entry"].is_object();
    let access_invalid = groups["access_invalid"].as_bool().unwrap_or(false);
    let joining = groups["pending_join"].is_object();
    let creating = groups["pending_create"].is_object();

    let mut group_name = String::new();
    let mut closed = false;
    let mut members_out = Vec::new();
    let mut mesh_peers: Vec<String> = Vec::new();
    let mut is_manager = false;

    if let Some(entry) = groups.get("group_entry").filter(|v| v.is_object()) {
        if let Ok(state) = unpack(entry) {
            closed = state["closed"].as_bool().unwrap_or(false);
            group_name = state["name"].as_str().unwrap_or("").to_owned();
            let trusted = groups["trusted_peers"].as_object();
            if let Some(members) = state["members"].as_array() {
                for m in members {
                    let Some(id) = m["device"].as_str() else {
                        continue;
                    };
                    let name = m["name"].as_str().unwrap_or(id);
                    let manager = m["manager"].as_bool().unwrap_or(false);
                    if id == device_id && manager {
                        is_manager = true;
                    }
                    members_out.push(json!({
                        "id": id,
                        "name": name,
                        "manager": manager,
                    }));
                    if !access_invalid
                        && !closed
                        && id != device_id
                        && trusted
                            .and_then(|t| t.get(id))
                            .and_then(Value::as_str)
                            .is_some_and(|k| !k.is_empty())
                    {
                        mesh_peers.push(id.to_owned());
                    }
                }
            }
        }
    }
    mesh_peers.sort();

    let (draft_group_name, draft_device_name) = groups
        .get("pending_create")
        .filter(|v| v.is_object())
        .and_then(|entry| unpack(entry).ok())
        .map(|payload| {
            let gname = payload["name"].as_str().unwrap_or("").to_owned();
            let dname = payload["members"]
                .as_array()
                .and_then(|arr| {
                    arr.iter()
                        .find(|m| m["device"].as_str() == Some(device_id))
                        .or_else(|| arr.first())
                })
                .and_then(|m| m["name"].as_str())
                .unwrap_or("")
                .to_owned();
            (gname, dname)
        })
        .unwrap_or_default();

    let inv = groups.get("issued_invitation").filter(|v| v.is_object());
    let pending_inv = groups["pending_join"]
        .get("invitation")
        .filter(|v| v.is_object());
    let automatic_join = pending_inv
        .or(inv)
        .and_then(|i| i["mode"].as_str())
        .is_some_and(|m| m == "auto");

    let (invite, invite_expires) = inv
        .and_then(|i| {
            let exp = i["expires"].as_u64().unwrap_or(0);
            if exp > now_secs {
                let link = i["short_link"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .map(str::to_owned)
                    .unwrap_or_else(|| i.to_string());
                Some((link, exp))
            } else {
                None
            }
        })
        .unwrap_or_default();

    let request = groups["pending_join"]
        .get("request")
        .filter(|v| v.is_object())
        .or_else(|| groups.get("join_request").filter(|v| v.is_object()));
    let group_code = request.map(format_join_code).unwrap_or_default();

    let applicant = groups
        .get("join_request")
        .filter(|v| v.is_object())
        .and_then(|entry| unpack(entry).ok())
        .and_then(|body| body["member"]["name"].as_str().map(str::to_owned))
        .unwrap_or_default();

    let endpoint = if creating {
        groups["url"].as_str().unwrap_or("").to_owned()
    } else {
        String::new()
    };

    json!({
        "managed": managed,
        "accessInvalid": access_invalid,
        "closed": closed,
        "mesh": managed && !access_invalid && !closed,
        "meshPeers": mesh_peers,
        "groupName": group_name,
        "members": members_out,
        "isManager": is_manager,
        "joining": joining,
        "creating": creating,
        "draftGroupName": draft_group_name,
        "draftDeviceName": draft_device_name,
        "automaticJoin": automatic_join,
        "groupCode": group_code,
        "applicant": applicant,
        "invite": invite,
        "inviteExpires": invite_expires,
        "draftEndpoint": endpoint,
    })
}

/// UniFFI export of [`group_summary`] for iOS and Android.
#[uniffi::export]
pub fn relay_group_summary(groups_json: String, device_id: String, now_secs: u64) -> String {
    let groups: Value = serde_json::from_str(&groups_json).unwrap_or_else(|_| json!({}));
    group_summary(&groups, &device_id, now_secs).to_string()
}

/// Foreign callback notified on every [`RelaySyncRunner`] state transition.
#[uniffi::export(with_foreign)]
pub trait RelaySyncObserver: Send + Sync {
    fn on_state(&self, state_json: String);
}

/// Rust-only per-cycle lifecycle hooks allowing Desktop to refresh group state and
/// trigger a clean reconnect when `group_entry` changes, while sharing the same runner loop.
pub enum CyclePrep {
    Continue(Value),
    Reconnect,
}

pub trait RunnerHooks: Send + Sync {
    fn before_connect(&self) -> Result<(Settings, Value)>;
    fn before_cycle(&self, current_groups: &Value) -> Result<CyclePrep>;
}

struct StaticHooks {
    settings: Settings,
    groups: Arc<Mutex<Value>>,
}

impl RunnerHooks for StaticHooks {
    fn before_connect(&self) -> Result<(Settings, Value)> {
        let groups = self
            .groups
            .lock()
            .map(|g| g.clone())
            .unwrap_or_else(|_| json!({}));
        Ok((self.settings.clone(), groups))
    }

    fn before_cycle(&self, _current_groups: &Value) -> Result<CyclePrep> {
        let groups = self
            .groups
            .lock()
            .map(|g| g.clone())
            .unwrap_or_else(|_| json!({}));
        Ok(CyclePrep::Continue(groups))
    }
}

#[derive(Default)]
struct WakeState {
    stop: bool,
    force_sync: bool,
    reconnect: bool,
    blob_outbox: VecDeque<(String, Vec<u8>)>,
}

struct RunnerShared {
    wake_lock: Mutex<WakeState>,
    wake_cv: Condvar,
    groups: Arc<Mutex<Value>>,
    connection: Mutex<Option<Arc<MeshSync>>>,
    snapshot: Mutex<Value>,
    running: AtomicBool,
    observer: Option<Arc<dyn RelaySyncObserver>>,
}

impl RunnerShared {
    fn emit(&self, mutate: impl FnOnce(&mut Value)) {
        let out = {
            let Ok(mut snap) = self.snapshot.lock() else {
                return;
            };
            mutate(&mut snap);
            snap.to_string()
        };
        if let Some(obs) = &self.observer {
            obs.on_state(out);
        }
    }

    fn is_stopped(&self) -> bool {
        self.wake_lock.lock().map(|w| w.stop).unwrap_or(true)
    }

    fn close_connection(&self) {
        if let Ok(mut slot) = self.connection.lock() {
            if let Some(conn) = slot.take() {
                conn.close();
            }
        }
    }

    fn wait_backoff(&self, delay_secs: u64) {
        let Ok(mut wake) = self.wake_lock.lock() else {
            return;
        };
        if wake.stop || wake.force_sync || wake.reconnect {
            wake.reconnect = false;
            return;
        }
        let deadline = Instant::now() + Duration::from_secs(delay_secs);
        while !wake.stop && !wake.force_sync && !wake.reconnect {
            let now = Instant::now();
            if now >= deadline {
                break;
            }
            let Ok((guard, _)) = self.wake_cv.wait_timeout(wake, deadline - now) else {
                return;
            };
            wake = guard;
        }
        wake.reconnect = false;
    }
}

fn parse_settings(options: &Value) -> Result<Settings> {
    let id_val = &options["identity"];
    let secret = BoxSecretKey::from_slice(&crate::relay_protocol::unhex(text(id_val, "secret")?)?)
        .ok_or_else(|| "InvalidData".to_owned())?;
    let mut trusted = BTreeMap::new();
    for (device, key) in id_val["trusted"].as_object().into_iter().flatten() {
        let key_str = key.as_str().ok_or_else(|| "InvalidData".to_owned())?;
        let pk = BoxPublicKey::from_slice(&crate::relay_protocol::unhex(key_str)?)
            .ok_or_else(|| "InvalidData".to_owned())?;
        trusted.insert(device.clone(), pk);
    }
    Ok(Settings {
        url: text(options, "url")?.into(),
        token: text(options, "token")?.into(),
        password: options["password"]
            .as_str()
            .filter(|p| !p.is_empty())
            .map(str::to_owned),
        local: options["allowLocal"] == true,
        identity: Identity {
            app: text(id_val, "app")?.into(),
            group: text(id_val, "group")?.into(),
            device: text(id_val, "device")?.into(),
            secret,
            trusted: trusted.into_iter().collect(),
        },
        journal: text(options, "journal")?.into(),
    })
}

/// Cancellable background sync runner shared by iOS, Android, and Desktop.
#[derive(uniffi::Object)]
pub struct RelaySyncRunner {
    shared: Arc<RunnerShared>,
}

#[uniffi::export]
impl RelaySyncRunner {
    /// Starts the unified sync loop (`connect -> cycle -> pump -> policy::retry -> backoff`)
    /// on a dedicated background thread.
    #[uniffi::constructor]
    pub fn start(
        vault: Arc<crate::VaultSession>,
        options: String,
        groups: String,
        observer: Option<Arc<dyn RelaySyncObserver>>,
    ) -> std::result::Result<Arc<Self>, RelayError> {
        let opt_val: Value = serde_json::from_str(&options)
            .map_err(|_| RelayError::from("InvalidData".to_owned()))?;
        let settings = parse_settings(&opt_val)?;
        let groups_val: Value = serde_json::from_str(&groups)
            .map_err(|_| RelayError::from("InvalidData".to_owned()))?;
        let groups_slot = Arc::new(Mutex::new(groups_val));
        let hooks: Arc<dyn RunnerHooks> = Arc::new(StaticHooks {
            settings,
            groups: groups_slot.clone(),
        });
        Self::spawn(vault, hooks, groups_slot, observer, true)
    }

    /// Wakes the sync loop immediately and forces a resend of unchanged packets.
    pub fn sync_now(&self) {
        if let Ok(mut wake) = self.shared.wake_lock.lock() {
            wake.force_sync = true;
            self.shared.wake_cv.notify_all();
        }
    }

    /// Drops the active socket and reconnects immediately (e.g. when returning to foreground).
    pub fn reconnect_now(&self) {
        if let Ok(mut wake) = self.shared.wake_lock.lock() {
            wake.reconnect = true;
            self.shared.wake_cv.notify_all();
        }
        self.shared.close_connection();
    }

    /// Updates the signed `groups` JSON used on subsequent sync cycles.
    pub fn update_groups(&self, groups: String) -> std::result::Result<(), RelayError> {
        let val: Value = serde_json::from_str(&groups)
            .map_err(|_| RelayError::from("InvalidData".to_owned()))?;
        if let Ok(mut slot) = self.shared.groups.lock() {
            *slot = val;
        }
        Ok(())
    }

    /// Queues an on-demand L3 attachment download request to `peer`.
    pub fn queue_blob_request(&self, peer: String, attachment_id: String) {
        let payload = super::mesh_sync::blob_request(&attachment_id);
        if let Ok(mut wake) = self.shared.wake_lock.lock() {
            wake.blob_outbox.push_back((peer, payload));
            self.shared.wake_cv.notify_all();
        }
    }

    /// Returns the latest state snapshot JSON.
    pub fn state(&self) -> String {
        self.shared
            .snapshot
            .lock()
            .map(|s| s.to_string())
            .unwrap_or_else(|_| r#"{"transport":"disconnected","online":[]}"#.to_owned())
    }

    /// True while the background sync thread is still alive.
    pub fn is_running(&self) -> bool {
        self.shared.running.load(Ordering::SeqCst)
    }

    /// Stops the runner and closes any open socket immediately without blocking on I/O.
    pub fn stop(&self) {
        if let Ok(mut wake) = self.shared.wake_lock.lock() {
            wake.stop = true;
            self.shared.wake_cv.notify_all();
        }
        self.shared.close_connection();
    }
}

impl RelaySyncRunner {
    /// Rust-only constructor for Desktop: accepts a custom [`MeshVault`] (e.g. one that
    /// serializes `relay-mesh-*` writes with group actions) and [`RunnerHooks`].
    pub fn start_with_hooks(
        vault: Arc<dyn MeshVault>,
        hooks: Arc<dyn RunnerHooks>,
        observer: Option<Arc<dyn RelaySyncObserver>>,
    ) -> std::result::Result<Arc<Self>, RelayError> {
        Self::spawn(
            vault,
            hooks,
            Arc::new(Mutex::new(json!({}))),
            observer,
            false,
        )
    }

    fn spawn(
        vault: Arc<dyn MeshVault>,
        hooks: Arc<dyn RunnerHooks>,
        groups: Arc<Mutex<Value>>,
        observer: Option<Arc<dyn RelaySyncObserver>>,
        include_self_in_online: bool,
    ) -> std::result::Result<Arc<Self>, RelayError> {
        let shared = Arc::new(RunnerShared {
            wake_lock: Mutex::new(WakeState::default()),
            wake_cv: Condvar::new(),
            groups,
            connection: Mutex::new(None),
            snapshot: Mutex::new(json!({
                "transport": "disconnected",
                "phase": "idle",
                "online": [],
                "error": "",
                "stoppedByAuth": false,
                "changed": false,
                "sent": 0,
                "updates": 0,
                "lastSentAt": null,
                "lastReceivedAt": null,
                "lastCheckedAt": null,
                "reconnectReason": null,
            })),
            running: AtomicBool::new(true),
            observer,
        });

        let thread_shared = shared.clone();
        std::thread::Builder::new()
            .name("pv-relay-sync".into())
            .spawn(move || run_loop(vault, hooks, thread_shared, include_self_in_online))
            .map_err(|_| RelayError::from("Storage".to_owned()))?;

        Ok(Arc::new(Self { shared }))
    }
}

fn run_loop(
    vault: Arc<dyn MeshVault>,
    hooks: Arc<dyn RunnerHooks>,
    shared: Arc<RunnerShared>,
    include_self_in_online: bool,
) {
    let mut backoff = 0u64;
    while !shared.is_stopped() {
        let mut connected_at: Option<Instant> = None;
        let mut reconnect_reason: Option<String> = None;

        let attempt_result: Result<()> = (|| {
            let (settings, mut current_groups) = hooks.before_connect()?;
            if shared.is_stopped() {
                return Err("Locked".into());
            }
            let self_device = settings.identity.device.clone();
            if let Ok(mut slot) = shared.groups.lock() {
                *slot = current_groups.clone();
            }
            shared.emit(|s| {
                s["transport"] = json!("connecting");
                s["phase"] = json!("connecting");
                s["changed"] = json!(false);
                s["reconnectReason"] = Value::Null;
            });

            let sync = Arc::new(MeshSync::connect(vault.clone(), settings)?);
            if let Ok(mut slot) = shared.connection.lock() {
                *slot = Some(sync.clone());
            }
            if shared.is_stopped() {
                return Err("Locked".into());
            }
            connected_at = Some(Instant::now());
            shared.emit(|s| {
                s["transport"] = json!("connected");
                s["error"] = json!("");
                s["changed"] = json!(false);
            });

            while !shared.is_stopped() {
                let (force, drained) = {
                    let Ok(mut wake) = shared.wake_lock.lock() else {
                        break;
                    };
                    if wake.reconnect {
                        wake.reconnect = false;
                        return Ok(());
                    }
                    let force = wake.force_sync;
                    wake.force_sync = false;
                    let drained: Vec<(String, Vec<u8>)> = wake.blob_outbox.drain(..).collect();
                    (force, drained)
                };
                match hooks.before_cycle(&current_groups)? {
                    CyclePrep::Continue(next_groups) => {
                        current_groups = next_groups;
                        if let Ok(mut slot) = shared.groups.lock() {
                            *slot = current_groups.clone();
                        }
                    }
                    CyclePrep::Reconnect => return Ok(()),
                }
                for (peer, payload) in drained {
                    sync.queue(&peer, payload)?;
                }
                shared.emit(|s| {
                    s["phase"] = json!("checking");
                    s["changed"] = json!(false);
                });
                let round = sync.cycle(&current_groups, force)?;
                if shared.is_stopped() {
                    break;
                }
                let mut online: Vec<String> = round["online"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect();
                if include_self_in_online && !online.iter().any(|d| d == &self_device) {
                    online.push(self_device.clone());
                }
                let changed = round["changed"].as_bool().unwrap_or(false);
                let sent = round["sent"].as_u64().unwrap_or(0);
                let now = now_millis();
                shared.emit(|s| {
                    s["transport"] = json!("connected");
                    s["phase"] = json!("checked");
                    s["online"] = json!(online);
                    s["changed"] = json!(changed);
                    s["sent"] = json!(sent);
                    s["lastCheckedAt"] = json!(now);
                    if sent > 0 {
                        s["lastSentAt"] = json!(now);
                    }
                    if changed {
                        s["lastReceivedAt"] = json!(now);
                        s["updates"] = json!(s["updates"].as_u64().unwrap_or(0) + 1);
                    }
                });

                // Pump incoming events for up to 5s in 1s slices; wake early on sync_now/stop/blob.
                for _ in 0..5 {
                    if shared.is_stopped() {
                        break;
                    }
                    let should_break = shared
                        .wake_lock
                        .lock()
                        .map(|w| w.force_sync || w.reconnect || !w.blob_outbox.is_empty())
                        .unwrap_or(true);
                    if should_break {
                        break;
                    }
                    let pumped = sync.pump(Duration::from_secs(1))?;
                    if pumped["changed"].as_bool().unwrap_or(false) {
                        let now = now_millis();
                        shared.emit(|s| {
                            s["changed"] = json!(true);
                            s["lastReceivedAt"] = json!(now);
                            s["updates"] = json!(s["updates"].as_u64().unwrap_or(0) + 1);
                        });
                    }
                    if let Some(reason) = pumped["reconnect"].as_str() {
                        reconnect_reason = Some(reason.to_owned());
                        return Ok(());
                    }
                }
            }
            Ok(())
        })();

        shared.close_connection();
        if shared.is_stopped() {
            break;
        }

        let connected_secs = connected_at.map(|t| t.elapsed().as_secs()).unwrap_or(0);
        match attempt_result {
            Err(ref e) if e == "Locked" || e == "NotEnrolled" || e == "GroupAccessRevoked" => {
                shared.emit(|s| {
                    s["transport"] = json!("disconnected");
                    s["phase"] = json!("idle");
                    s["online"] = json!([]);
                    s["error"] = json!(if e == "NotEnrolled" { "" } else { e.as_str() });
                    s["changed"] = json!(false);
                });
                break;
            }
            Err(e) => match policy::retry(&e, backoff, connected_secs) {
                policy::Retry::Stop => {
                    shared.emit(|s| {
                        s["transport"] = json!("disconnected");
                        s["phase"] = json!("failed");
                        s["online"] = json!([]);
                        s["error"] = json!(e);
                        s["stoppedByAuth"] = json!(true);
                        s["changed"] = json!(false);
                    });
                    break;
                }
                policy::Retry::After(delay) => {
                    backoff = delay;
                    shared.emit(|s| {
                        s["transport"] = json!("reconnecting");
                        s["phase"] = json!("failed");
                        s["online"] = json!([]);
                        s["error"] = json!(e);
                        s["changed"] = json!(false);
                    });
                }
            },
            Ok(()) => {
                if let Some(reason) = reconnect_reason.take() {
                    shared.emit(|s| {
                        s["transport"] = json!("reconnecting");
                        s["online"] = json!([]);
                        s["reconnectReason"] = json!(reason);
                        s["changed"] = json!(false);
                    });
                }
                match policy::retry("closed", backoff, connected_secs) {
                    policy::Retry::Stop => break,
                    policy::Retry::After(delay) => backoff = delay,
                }
            }
        }
        shared.wait_backoff(backoff);
    }

    shared.close_connection();
    shared.running.store(false, Ordering::SeqCst);
    shared.emit(|s| {
        if s["stoppedByAuth"].as_bool() != Some(true) {
            s["transport"] = json!("disconnected");
            s["phase"] = json!("idle");
            s["online"] = json!([]);
            s["changed"] = json!(false);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn packed(body: Value) -> Value {
        json!({"payload": STANDARD.encode(body.to_string().as_bytes())})
    }

    #[test]
    fn group_summary_projects_roster_codes_invitations_and_drafts() {
        let key = "01".repeat(32);
        let groups = json!({
            "url": "wss://relay.example.test/v2/ws",
            "group_entry": packed(json!({
                "version": 1,
                "app": "passwordvault",
                "group": "grp-1",
                "revision": 1,
                "previous": "",
                "invitation": "",
                "request_hash": "",
                "name": "Family Vault",
                "closed": false,
                "members": [
                    {"device": "dev-a", "name": "MacBook", "public_key": key, "signing_key": key, "manager": true},
                    {"device": "dev-b", "name": "iPhone", "public_key": key, "signing_key": key, "manager": false},
                    {"device": "dev-c", "name": "Unpinned", "public_key": key, "signing_key": key, "manager": false}
                ]
            })),
            "trusted_peers": {"dev-b": key},
            "issued_invitation": {"short_link": "https://relay.example.test/i/abc", "expires": 2000, "mode": "auto"},
            "join_request": packed(json!({
                "version": 1,
                "app": "passwordvault",
                "group": "grp-1",
                "invitation": "inv-1",
                "member": {"device": "dev-d", "name": "iPad", "public_key": key, "signing_key": key, "manager": false},
                "token_hash": key
            })),
        });
        let s = group_summary(&groups, "dev-a", 1500);
        assert_eq!(s["managed"], true);
        assert_eq!(s["mesh"], true);
        assert_eq!(s["isManager"], true);
        assert_eq!(s["groupName"], "Family Vault");
        assert_eq!(s["meshPeers"], json!(["dev-b"]));
        assert_eq!(s["automaticJoin"], true);
        assert_eq!(s["applicant"], "iPad");
        assert_eq!(s["invite"], "https://relay.example.test/i/abc");
        assert_eq!(s["inviteExpires"], 2000);
        let code = s["groupCode"].as_str().unwrap();
        assert_eq!(code.len(), 14);
        assert_eq!(code.chars().filter(|&c| c == '-').count(), 2);

        // Expired invitation is omitted.
        let expired = group_summary(&groups, "dev-a", 2500);
        assert_eq!(expired["invite"], "");
        assert_eq!(expired["inviteExpires"], 0);
    }
}
