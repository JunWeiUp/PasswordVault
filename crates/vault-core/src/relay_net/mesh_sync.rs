//! The personal-sync session every client runs: symmetric mesh sync with the members of the
//! signed device group, over the SDK connection and encrypted relay files. Clients only own
//! the loop around it (connect, `cycle` every few seconds, `pump` events in between, reconnect
//! when asked) and their UI; the rules below are shared:
//! - peers are the verified roster members with pinned keys, excluding this device;
//! - packets up to 128 KiB travel as journaled offline messages, larger ones as files;
//! - an unchanged packet is resent at most hourly per peer (or after `peer.up`/`force`);
//! - files and messages from outside the roster are dropped, never applied;
//! - an undecryptable envelope triggers one reconnect (fresh keys/roster), then is dropped;
//! - `group.changed` with a newer revision asks for a reconnect;
//! - obsolete access/capability control messages from old clients are ignored.
use super::{connection::Connection, files, Journal, Result};
use crate::relay_protocol::{canonical, digest, text, unpack, Identity};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

/// Wire version of mesh packets (`relay-mesh-export`).
pub const VERSION: u64 = 3;
/// Largest packet sent as an offline message; larger ones go through relay files.
pub const MESSAGE_LIMIT: usize = 128 * 1024;
/// Largest relay file accepted from a peer.
pub const FILE_LIMIT: u64 = 768 * 1024 * 1024;

/// The vault the session reads and writes: `command(request) -> result` with core ops.
pub trait MeshVault: Send + Sync {
    fn command(&self, request: Value) -> Result<Value>;
}

impl MeshVault for crate::VaultSession {
    fn command(&self, request: Value) -> Result<Value> {
        let raw = zeroize::Zeroizing::new(
            crate::VaultSession::command(self, request.to_string())
                .map_err(|e| format!("{e:?}"))?,
        );
        serde_json::from_str(&raw).map_err(|_| "InvalidData".into())
    }
}

/// Roster members with pinned transport keys, excluding `device`. `None` outside a usable
/// personal group (no signed entry, closed group or invalidated access).
pub fn roster(groups: &Value, device: &str) -> Result<Option<Vec<String>>> {
    let Some(entry) = groups.get("group_entry").filter(|e| e.is_object()) else {
        return Ok(None);
    };
    if groups["access_invalid"] == true {
        return Ok(None);
    }
    let state = unpack(entry)?;
    if state["closed"] == true {
        return Ok(None);
    }
    let trusted = &groups["trusted_peers"];
    let mut peers: Vec<String> = state["members"]
        .as_array()
        .ok_or("InvalidData")?
        .iter()
        .filter_map(|m| m["device"].as_str())
        .filter(|id| *id != device && trusted[*id].as_str().is_some_and(|k| !k.is_empty()))
        .map(str::to_owned)
        .collect();
    peers.sort();
    Ok(Some(peers))
}

/// Connection settings: the relay endpoint plus this device's identity.
pub struct Settings {
    pub url: String,
    pub token: String,
    pub password: Option<String>,
    pub local: bool,
    pub identity: Identity,
    /// Directory of the SDK delivery journal.
    pub journal: std::path::PathBuf,
}

pub struct MeshSync {
    vault: Arc<dyn MeshVault>,
    connection: Connection,
    settings: Settings,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    peers: Vec<String>,
    revision: u64,
    sent: HashMap<String, String>,
    outbox: VecDeque<(String, Vec<u8>)>,
}

impl MeshSync {
    pub fn connect(vault: Arc<dyn MeshVault>, settings: Settings) -> Result<Self> {
        let journal = Journal::open(&settings.journal).map_err(|_| "Storage".to_owned())?;
        let _ = journal.cleanup();
        let connection = Connection::connect(
            &settings.url,
            &settings.token,
            settings.password.as_deref(),
            settings.identity.clone(),
            settings.local,
            Some(journal),
        )?;
        Ok(Self {
            vault,
            connection,
            settings,
            state: Mutex::new(State::default()),
        })
    }

    fn state(&self) -> Result<std::sync::MutexGuard<'_, State>> {
        self.state.lock().map_err(|_| "Storage".into())
    }

    fn files<'a>(&self, check: &'a dyn Fn() -> Result<()>) -> Result<files::Files<'a>> {
        files::Files::new(
            &self.settings.url,
            &self.settings.token,
            self.settings.password.as_deref(),
            self.settings.local,
            check,
        )
    }

    /// One sync round: applies the roster from `groups` (the group state-machine config),
    /// sends changed packets, queued replies and pending files, and applies the file inbox.
    /// Returns `{changed, online:[device], sent, received, peers:[device]}`.
    pub fn cycle(&self, groups: &Value, force: bool) -> Result<Value> {
        let device = self.settings.identity.device.clone();
        let peers = roster(groups, &device)?.unwrap_or_default();
        if let Some(entry) = groups.get("group_entry").filter(|e| e.is_object()) {
            self.state()?.revision = unpack(entry)?["revision"].as_u64().unwrap_or(0);
        }
        self.vault.command(
            json!({"op":"relay-mesh-init","group":self.settings.identity.group,"device":device}),
        )?;
        self.vault
            .command(json!({"op":"relay-mesh-peers","peers":peers}))?;
        {
            let mut state = self.state()?;
            if force {
                state.sent.clear();
            }
            state.peers = peers.clone();
        }
        let group = self.settings.identity.group.clone();
        let online: Vec<String> = self.connection.peers()?["devices"]
            .as_array()
            .ok_or("InvalidData")?
            .iter()
            .filter(|d| d["app"] == "passwordvault" && d["group"] == group.as_str())
            .filter_map(|d| d["device"].as_str().map(str::to_owned))
            .collect();
        let mut sent = 0;
        for peer in &peers {
            let packet = self
                .vault
                .command(json!({"op":"relay-mesh-export","peer":peer}))?["packet"]
                .clone();
            if !packet.is_object() {
                continue;
            }
            let data = zeroize::Zeroizing::new(canonical(&packet));
            let signature = format!("{}:{}", digest(&data), unix_hours());
            if self.state()?.sent.get(peer) == Some(&signature) {
                continue;
            }
            let id = digest(format!("{peer}{signature}").as_bytes())[..32].to_string();
            self.deliver(peer, &id, &data)?;
            self.state()?.sent.insert(peer.clone(), signature);
            sent += 1;
        }
        self.flush_outbox()?;
        let mut changed = false;
        let mut received = 0;
        let check = || self.check();
        let files = self.files(&check)?;
        for descriptor in files.inbox()? {
            let from = text(&descriptor, "from")?;
            let id = text(&descriptor, "id")?;
            if !peers.iter().any(|p| p == from)
                || descriptor["size"].as_u64().unwrap_or(0) > FILE_LIMIT
            {
                files.acknowledge(id)?;
                continue;
            }
            let cipher = files.download(&descriptor)?;
            let plain = files::decrypt(&self.settings.identity, from, &descriptor, &cipher)?;
            changed |= self.apply(from, &plain)?;
            files.acknowledge(id)?;
            received += 1;
        }
        self.flush_outbox()?;
        Ok(json!({"changed":changed,"online":online,"sent":sent,"received":received,"peers":peers}))
    }

    /// Handles relay events for up to `timeout`. Returns `{changed, reconnect}` where
    /// `reconnect` is null or the reason (`roster`, `group`) the caller must reconnect for.
    pub fn pump(&self, timeout: Duration) -> Result<Value> {
        let until = Instant::now() + timeout;
        let mut changed = false;
        loop {
            let left = until.saturating_duration_since(Instant::now());
            let Some(event) = self
                .connection
                .next_event(left.min(Duration::from_millis(500)))?
            else {
                if left.is_zero() {
                    return Ok(json!({"changed":changed,"reconnect":null}));
                }
                continue;
            };
            let offline = event["offline"] == true;
            match event["type"].as_str() {
                Some("message") => {
                    let from = text(&event, "from")?;
                    let id = text(&event, "id")?;
                    let data = zeroize::Zeroizing::new(
                        STANDARD
                            .decode(text(&event, "data")?)
                            .map_err(|_| "InvalidData")?,
                    );
                    if self.state()?.peers.iter().any(|p| p == from) {
                        changed |= self.apply(from, &data)?;
                    }
                    self.connection.acknowledge(from, id, offline)?;
                }
                Some("undecryptable") => {
                    let from = text(&event, "from")?;
                    let id = text(&event, "id")?;
                    let retry = event["trusted"] != true
                        && (self.state()?.peers.iter().any(|p| p == from)
                            || first_undecryptable(&self.settings.identity.device, from, id));
                    if retry {
                        return Ok(json!({"changed":changed,"reconnect":"roster"}));
                    }
                    self.connection.acknowledge(from, id, offline)?;
                }
                Some("group.changed") => {
                    if event["revision"].as_u64().unwrap_or(0) > self.state()?.revision {
                        return Ok(json!({"changed":changed,"reconnect":"group"}));
                    }
                }
                Some("peer.up") => self.state()?.sent.clear(),
                _ => {}
            }
            self.flush_outbox()?;
        }
    }

    /// Queues a packet for `peer` (e.g. an on-demand attachment request), sent next round.
    pub fn queue(&self, peer: &str, data: Vec<u8>) -> Result<()> {
        self.state()?.outbox.push_back((peer.to_owned(), data));
        Ok(())
    }

    pub fn close(&self) {
        self.connection.close();
    }

    pub fn is_closed(&self) -> bool {
        self.connection.is_closed()
    }

    fn check(&self) -> Result<()> {
        if self.is_closed() {
            Err("RelayConnection".into())
        } else {
            Ok(())
        }
    }

    fn deliver(&self, peer: &str, id: &str, data: &[u8]) -> Result<()> {
        if data.len() <= MESSAGE_LIMIT {
            self.connection.message(peer, data, true, Some(id))?;
        } else {
            let check = || self.check();
            let files = self.files(&check)?;
            let (descriptor, cipher) = files::prepare(&self.settings.identity, peer, data)?;
            files.upload(&descriptor, &cipher)?;
        }
        Ok(())
    }

    fn flush_outbox(&self) -> Result<()> {
        loop {
            let next = self.state()?.outbox.pop_front();
            let Some((peer, data)) = next else {
                return Ok(());
            };
            if !self.state()?.peers.contains(&peer) {
                continue;
            }
            let id = digest(&data)[..32].to_string();
            self.deliver(&peer, &id, &data)?;
        }
    }

    /// Applies one packet from a roster member; queues the reply to an attachment request.
    fn apply(&self, from: &str, data: &[u8]) -> Result<bool> {
        let Ok(packet) = serde_json::from_slice::<Value>(data) else {
            return Ok(false);
        };
        // Obsolete access/capability controls from old clients, and other versions.
        if packet["version"] != VERSION {
            return Ok(false);
        }
        match packet["kind"].as_str() {
            Some("mesh") => {
                let result = self
                    .vault
                    .command(json!({"op":"relay-mesh-receive","peer":from,"packet":packet}))?;
                Ok(result["changed"] == true)
            }
            Some("mesh-blob-req") => {
                let Some(id) = packet["attachmentId"].as_str().filter(|a| !a.is_empty()) else {
                    return Ok(false);
                };
                if let Ok(exported) = self
                    .vault
                    .command(json!({"op":"relay-mesh-blob-export","peer":from,"attachmentId":id}))
                {
                    let reply = json!({"version":VERSION,"kind":"mesh-blob-resp","meta":exported["meta"],"data":exported["data"]});
                    self.queue(from, canonical(&reply))?;
                }
                Ok(false)
            }
            Some("mesh-blob-resp") => {
                let result = self.vault.command(json!({"op":"relay-mesh-blob-receive","peer":from,"meta":packet["meta"],"data":packet["data"]}))?;
                Ok(result["ok"] == true)
            }
            _ => Ok(false),
        }
    }
}

/// True the first time this device sees `from/id` undecryptable in this process. The record
/// must outlive the session: the reconnect it triggers starts a new one.
fn first_undecryptable(device: &str, from: &str, id: &str) -> bool {
    static SEEN: std::sync::OnceLock<Mutex<HashSet<String>>> = std::sync::OnceLock::new();
    let Ok(mut seen) = SEEN.get_or_init(Default::default).lock() else {
        return false;
    };
    if seen.len() > 4096 {
        seen.clear();
    }
    seen.insert(format!("{device}/{from}/{id}"))
}

/// The on-demand attachment request packet for `relay-mesh-blob-export` on a peer.
pub fn blob_request(attachment: &str) -> Vec<u8> {
    canonical(&json!({"version":VERSION,"kind":"mesh-blob-req","attachmentId":attachment}))
}

fn unix_hours() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() / 3600)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn groups(closed: bool, invalid: bool) -> Value {
        let member = |id: &str| json!({"device":id,"name":id,"public_key":"","signing_key":"","manager":id == "mac"});
        let entry = json!({"version":1,"app":"passwordvault","group":"g","revision":2,"previous":"","invitation":"","request_hash":"","closed":closed,
            "members":[member("mac"), member("phone"), member("unpinned")]});
        json!({"group":"g","group_entry":{"payload":STANDARD.encode(canonical(&entry))},
            "trusted_peers":{"phone":"ab","mac":"cd"},"access_invalid":invalid})
    }

    #[test]
    fn roster_uses_pinned_members_and_excludes_self() {
        assert_eq!(
            roster(&groups(false, false), "mac").unwrap(),
            Some(vec!["phone".to_owned()])
        );
        assert_eq!(roster(&groups(true, false), "mac").unwrap(), None);
        assert_eq!(roster(&groups(false, true), "mac").unwrap(), None);
        assert_eq!(roster(&json!({}), "mac").unwrap(), None);
    }

    #[test]
    fn an_undecryptable_message_retries_once_per_device() {
        assert!(first_undecryptable("dev-test", "stranger", "id-1"));
        assert!(!first_undecryptable("dev-test", "stranger", "id-1"));
        assert!(first_undecryptable("dev-other", "stranger", "id-1"));
    }

    #[test]
    fn blob_requests_are_mesh_packets() {
        let packet: Value = serde_json::from_slice(&blob_request("att-1")).unwrap();
        assert_eq!(packet["version"], VERSION);
        assert_eq!(packet["kind"], "mesh-blob-req");
        assert_eq!(packet["attachmentId"], "att-1");
    }
}
