//! Symmetric personal sync. Every member of the signed device group exchanges
//! whole-record values with every other member. The newest hybrid-logical stamp
//! wins; a losing incoming value is kept in entry history, and a losing local value
//! is already there because history captures every saved revision. Delivery
//! acknowledgements are internal resend bookkeeping only and are never a user step.
use super::*;

const MAX_FUTURE_MS: u64 = 7 * 24 * 60 * 60 * 1000;
const SKEW_NOTICE_MS: u64 = 5 * 60 * 1000;
const PACKET_VERSION: u64 = 3;
/// Attachments larger than 512 KiB sync as L1 metadata stubs (`remoteFiles`) first
/// and download on demand, eliminating head-of-line blocking for passwords and notes.
pub(super) const INLINE_ATTACHMENT_LIMIT: usize = 512 * 1024;

fn default_retention_days() -> u32 {
    30
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct NoteConflict {
    pub note_id: String,
    pub local_device: String,
    pub remote_device: String,
    pub revision_id: String,
    pub captured_at: u64,
    pub section: String,
    #[serde(default)]
    pub auto_merged: Vec<String>,
    #[serde(default)]
    pub asset_guard: String,
    #[serde(default = "default_retention_days")]
    pub retention_days: u32,
}

/// (wall-clock milliseconds, logical counter, device). Compared lexicographically;
/// the device identifier only breaks exact ties between different replicas.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct Stamp(pub u64, pub u32, pub String);

/// Per-key version vector: the latest `(ms, counter)` of each device whose edit this value
/// already includes. It tells a sequential edit (made on top of ours) from a concurrent one.
pub(super) type Versions = BTreeMap<String, (u64, u32)>;

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Meta {
    stamp: Stamp,
    seq: u64,
    /// Empty for records written before version vectors; see [`versions`].
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    vv: Versions,
}

/// Effective version vector of a value: the stored vector plus its own stamp (records from
/// older builds carry only the stamp).
pub(super) fn versions(stamp: &Stamp, vv: &Versions) -> Versions {
    let mut out = vv.clone();
    if !stamp.2.is_empty() {
        let own = out.entry(stamp.2.clone()).or_default();
        *own = (*own).max((stamp.0, stamp.1));
    }
    out
}

/// True when `a` already includes every edit `b` includes.
pub(super) fn includes(a: &Versions, b: &Versions) -> bool {
    b.iter()
        .all(|(device, v)| a.get(device).is_some_and(|mine| mine >= v))
}

pub(super) fn join(a: &Versions, b: &Versions) -> Versions {
    let mut out = a.clone();
    for (device, v) in b {
        let mine = out.entry(device.clone()).or_default();
        *mine = (*mine).max(*v);
    }
    out
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Mesh {
    version: u32,
    group: String,
    device: String,
    clock: (u64, u32),
    seq: u64,
    meta: BTreeMap<String, Meta>,
    /// Legacy full-record baseline retained only for transparent migration on load.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    baseline: Records,
    /// Compact SHA-256 content digests per key so `personal_mesh` never duplicates full note bodies.
    #[serde(default)]
    baseline_digests: BTreeMap<String, String>,
    peers: BTreeSet<String>,
    /// Highest local sequence each peer has confirmed receiving.
    acked: BTreeMap<String, u64>,
    /// Highest peer sequence received here; echoed back as that peer's ack.
    received: BTreeMap<String, u64>,
    /// Last ack value exported to each peer, so idle peers do not ping-pong.
    ack_sent: BTreeMap<String, u64>,
    #[serde(default)]
    skew: bool,
    #[serde(default)]
    migrated_from: Option<String>,
    #[serde(default)]
    archived_conflicts: usize,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    note_conflicts: BTreeMap<String, NoteConflict>,
    /// Set once every peer was sent a complete resend after the causal-merge fix (builds
    /// 7c396b6..fix could drop migrated records a peer did not have yet).
    #[serde(default)]
    resent_after_causal_fix: bool,
}

pub(super) fn operation(op: &str) -> bool {
    matches!(
        op,
        "relay-mesh-init"
            | "relay-mesh-peers"
            | "relay-mesh-export"
            | "relay-mesh-receive"
            | "relay-mesh-conflicts"
            | "relay-mesh-resolve-conflict"
            | "relay-mesh-blob-export"
            | "relay-mesh-blob-receive"
    )
}

pub(super) fn enabled(conn: &Connection) -> Result<bool> {
    Ok(storage(conn.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='personal_mesh'",
        [],
        |r| r.get::<_, i64>(0),
    ))? != 0)
}

fn load(conn: &Connection, root: &[u8; 32], vault: &str) -> Result<Mesh> {
    let data: Vec<u8> = storage(conn.query_row(
        "SELECT payload FROM personal_mesh WHERE id=1",
        [],
        |r| r.get(0),
    ))?;
    let sealed: Sealed = serde_json::from_slice(&data).map_err(|_| VaultError::InvalidData)?;
    serde_json::from_slice(&unseal(
        &subkey(root, b"personal-mesh-v1"),
        &sealed,
        vault.as_bytes(),
    )?)
    .map_err(|_| VaultError::InvalidData)
}

fn store(conn: &Connection, root: &[u8; 32], vault: &str, mesh: &Mesh) -> Result<()> {
    let data = Zeroizing::new(serde_json::to_vec(mesh).map_err(|_| VaultError::InvalidData)?);
    let sealed = seal(&subkey(root, b"personal-mesh-v1"), &data, vault.as_bytes())?;
    storage(conn.execute(
        "INSERT INTO personal_mesh(id,payload) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
        [serde_json::to_vec(&sealed).map_err(|_| VaultError::InvalidData)?],
    ))?;
    Ok(())
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Categories are separate keys so concurrent additions on two devices both survive.
fn mesh_records(doc: &Document) -> Records {
    let mut out = Records::new();
    for item in &doc.items {
        out.insert(
            format!("item:{}", item["id"].as_str().unwrap_or_default()),
            item.clone(),
        );
    }
    for name in doc.note_categories() {
        out.insert(format!("category:{name}"), json!(true));
    }
    out
}

fn install_mesh(doc: &mut Document, values: &Records) -> Result<()> {
    let previous = doc.note_categories();
    let wanted: BTreeSet<&str> = values
        .iter()
        .filter(|(_, v)| **v == json!(true))
        .filter_map(|(k, _)| k.strip_prefix("category:"))
        .collect();
    // Keep the local display order; append newly synchronized categories.
    let mut categories: Vec<String> = previous
        .iter()
        .filter(|c| wanted.contains(c.as_str()))
        .cloned()
        .collect();
    for name in &wanted {
        if !categories.iter().any(|c| c == name) {
            categories.push((*name).to_string());
        }
    }
    let items: Records = values
        .iter()
        .filter(|(k, v)| k.starts_with("item:") && !v.is_null())
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    // Removing a category clears it from notes locally as the originating device did;
    // those notes arrive as their own records, so only the explicit list changes here.
    let mut records = items;
    records.insert("categories".into(), json!(categories));
    install(doc, &records)
}

fn valid_key(key: &str) -> bool {
    if let Some(id) = key.strip_prefix("item:") {
        return !id.is_empty() && id.len() <= 256;
    }
    if let Some(name) = key.strip_prefix("category:") {
        return !name.is_empty() && name.len() <= 512;
    }
    false
}

fn value_digest(value: &Value) -> Vec<u8> {
    Sha256::digest(serde_json::to_vec(value).unwrap_or_default()).to_vec()
}

fn value_digest_hex(value: &Value) -> String {
    hex::encode(value_digest(value))
}

fn mesh_digests(doc: &Document) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for item in &doc.items {
        let key = format!("item:{}", item["id"].as_str().unwrap_or_default());
        out.insert(key, value_digest_hex(item));
    }
    for name in doc.note_categories() {
        out.insert(format!("category:{name}"), value_digest_hex(&json!(true)));
    }
    out
}

mod merge;
use merge::merge_concurrent_note;

impl Mesh {
    fn local_stamp(&mut self) -> Stamp {
        let now = now_ms();
        self.clock = if now > self.clock.0 {
            (now, 0)
        } else {
            (self.clock.0, self.clock.1.saturating_add(1))
        };
        Stamp(self.clock.0, self.clock.1, self.device.clone())
    }
    fn observe(&mut self, stamp: &Stamp) {
        if (stamp.0, stamp.1) > self.clock {
            self.clock = (stamp.0, stamp.1);
        }
    }
    fn bump(&mut self) -> Result<u64> {
        self.seq = self.seq.checked_add(1).ok_or(VaultError::InvalidData)?;
        Ok(self.seq)
    }
    fn ensure_digests(&mut self) {
        if self.baseline_digests.is_empty() && !self.baseline.is_empty() {
            for (k, v) in std::mem::take(&mut self.baseline) {
                self.baseline_digests.insert(k, value_digest_hex(&v));
            }
        } else {
            self.baseline.clear();
        }
    }
}

/// Records local edits using compact content digests (never hydrating untouched split notes).
/// Expects `doc` after `note_bodies::sync_and_strip` so split notes carry deterministic `_bodyDigest`.
pub(super) fn capture(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    doc: &Document,
) -> Result<bool> {
    if !enabled(conn)? {
        return Ok(false);
    }
    let mut mesh = load(conn, root, vault)?;
    let migrated_legacy = !mesh.baseline.is_empty();
    mesh.ensure_digests();
    let now = mesh_digests(doc);
    let keys: BTreeSet<_> = now
        .keys()
        .chain(mesh.baseline_digests.keys())
        .cloned()
        .collect();
    let mut dirty = false;
    for key in keys {
        let digest = now.get(&key);
        if mesh.baseline_digests.get(&key) == digest {
            continue;
        }
        let previous = mesh
            .meta
            .get(&key)
            .map(|m| versions(&m.stamp, &m.vv))
            .unwrap_or_default();
        let stamp = mesh.local_stamp();
        let seq = mesh.bump()?;
        let vv = versions(&stamp, &previous);
        mesh.meta.insert(key, Meta { stamp, seq, vv });
        dirty = true;
    }
    if dirty || migrated_legacy {
        mesh.baseline_digests = now;
        mesh.baseline.clear();
        store(conn, root, vault, &mesh)?;
    }
    Ok(true)
}

fn legacy_key(key: &str) -> &str {
    if key.starts_with("category:") {
        "categories"
    } else {
        key
    }
}

/// Builds stamps for an existing hub/mobile journal so nothing pending is lost:
/// synchronized values keep the hub revision order, unconfirmed mobile edits beat
/// them, and edits the old hub had already rejected lose (they remain in history).
fn migrate(legacy: &State, doc: &Document, device: &str, now: u64) -> BTreeMap<String, Stamp> {
    let mut stamps = BTreeMap::new();
    let current = mesh_records(doc);
    let legacy_stamp = |key: &str| {
        Stamp(
            0,
            legacy.revisions.get(legacy_key(key)).copied().unwrap_or(0) as u32,
            String::new(),
        )
    };
    let pending_stamp = |key: &str, value: &Value| -> Option<Stamp> {
        let change = legacy.pending.get(legacy_key(key))?;
        if legacy.blocked.contains(&change.id) {
            return Some(Stamp(0, change.base as u32, device.to_string()));
        }
        let ms = crate::model::timestamp(value).max(0) as u64;
        Some(Stamp(
            if ms == 0 { now } else { ms.max(1) },
            0,
            device.to_string(),
        ))
    };
    let mut keys: BTreeSet<String> = current.keys().cloned().collect();
    // Deletions: canonical/pending values that are absent from the current document.
    for (key, value) in legacy.canonical.iter() {
        if key.starts_with("item:") {
            keys.insert(key.clone());
        } else if key == "categories" {
            for name in value
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
            {
                keys.insert(format!("category:{name}"));
            }
        }
    }
    for (key, change) in &legacy.pending {
        if key.starts_with("item:") {
            keys.insert(key.clone());
        } else if key == "categories" {
            for name in change
                .value
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
            {
                keys.insert(format!("category:{name}"));
            }
        }
    }
    for key in keys {
        let value = current.get(&key).cloned().unwrap_or(Value::Null);
        let stamp = if legacy.role == "hub" {
            legacy_stamp(&key)
        } else {
            pending_stamp(&key, &value).unwrap_or_else(|| legacy_stamp(&key))
        };
        stamps.insert(key, stamp);
    }
    stamps
}

mod commands;
#[cfg(test)]
mod tests;
