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

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Meta {
    stamp: Stamp,
    seq: u64,
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
    if doc.settings["activePeerLibrary"]
        .as_str()
        .is_some_and(|s| !s.is_empty())
    {
        return Ok(true);
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
        let stamp = mesh.local_stamp();
        let seq = mesh.bump()?;
        mesh.meta.insert(key, Meta { stamp, seq });
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

impl DiskVault {
    pub(super) fn mesh_command(&mut self, request: &Value) -> Result<Value> {
        let vault_dir = self.directory.clone();
        let op = string(request, "op")?;
        if op == "relay-mesh-init" {
            return self.mesh_init(request);
        }
        let open = self.open()?;
        if !enabled(&open.connection)? {
            return Err(VaultError::Unsupported);
        }
        let mut mesh = load(&open.connection, &open.root, &open.header.vault_id)?;
        match op {
            "relay-mesh-peers" => {
                let peers: BTreeSet<String> = serde_json::from_value(request["peers"].clone())
                    .map_err(|_| VaultError::InvalidData)?;
                if peers.len() > 256 || !peers.iter().all(|p| valid_name(p)) {
                    return Err(VaultError::InvalidData);
                }
                let peers: BTreeSet<String> =
                    peers.into_iter().filter(|p| p != &mesh.device).collect();
                // A removed member stops receiving immediately; if re-added later it
                // starts from a complete resend.
                for gone in mesh.peers.difference(&peers).cloned().collect::<Vec<_>>() {
                    mesh.acked.remove(&gone);
                    mesh.ack_sent.remove(&gone);
                }
                mesh.peers = peers;
                store(&open.connection, &open.root, &open.header.vault_id, &mesh)?;
                Ok(json!({"ok":true,"peers":mesh.peers}))
            }
            "relay-mesh-export" => {
                let peer = string(request, "peer")?;
                if !mesh.peers.contains(peer) {
                    return Err(VaultError::Authentication);
                }
                let acked = *mesh.acked.get(peer).unwrap_or(&0);
                let current = mesh_records(&open.document);
                let mut records = serde_json::Map::new();
                let mut values = serde_json::Map::new();
                for (key, meta) in mesh.meta.iter().filter(|(_, m)| m.seq > acked) {
                    let mut value = current.get(key).cloned().unwrap_or(Value::Null);
                    if !value.is_null() && key.starts_with("item:") {
                        note_bodies::hydrate_item(
                            &open.connection,
                            &open.root,
                            &open.header.vault_id,
                            &mut value,
                        )?;
                    }
                    values.insert(key.clone(), value.clone());
                    records.insert(key.clone(), json!({"value":value,"stamp":meta.stamp}));
                }
                let ack = *mesh.received.get(peer).unwrap_or(&0);
                if records.is_empty() && mesh.ack_sent.get(peer) == Some(&ack) {
                    return Ok(json!({"packet":null}));
                }
                let (files, remote_files) = attachments_split(
                    &vault_dir,
                    open,
                    &json!({"records":values}),
                    INLINE_ATTACHMENT_LIMIT,
                    &mesh.device,
                )?;
                mesh.ack_sent.insert(peer.into(), ack);
                store(&open.connection, &open.root, &open.header.vault_id, &mesh)?;
                let mut packet = json!({
                    "version":PACKET_VERSION,"kind":"mesh","group":mesh.group,
                    "from":mesh.device,"to":peer,"formatVersion":open.document.format_version,
                    "upto":mesh.seq,"ack":ack,"records":records,"files":files
                });
                if remote_files.as_array().is_some_and(|a| !a.is_empty()) {
                    packet["remoteFiles"] = remote_files;
                }
                Ok(json!({"packet": packet}))
            }
            "relay-mesh-receive" => {
                let peer = string(request, "peer")?;
                if !mesh.peers.contains(peer) {
                    return Err(VaultError::Authentication);
                }
                let packet = &request["packet"];
                if packet["version"] != PACKET_VERSION || packet["kind"] != "mesh" {
                    return Err(VaultError::Unsupported);
                }
                if packet["group"] != mesh.group.as_str()
                    || packet["from"] != peer
                    || packet["to"] != mesh.device.as_str()
                {
                    return Err(VaultError::Authentication);
                }
                let format = packet["formatVersion"]
                    .as_u64()
                    .filter(|v| (2..=u64::from(crate::devices::DEVICES_FORMAT)).contains(v))
                    .ok_or(VaultError::Unsupported)? as u32;
                let upto = packet["upto"].as_u64().ok_or(VaultError::InvalidData)?;
                let ack = packet["ack"].as_u64().ok_or(VaultError::InvalidData)?;
                let incoming = packet["records"]
                    .as_object()
                    .ok_or(VaultError::InvalidData)?;
                if incoming.len() > 100_001 {
                    return Err(VaultError::InvalidData);
                }
                let now = now_ms();
                let mut next = open.document.clone();
                next.format_version = next.format_version.max(format);
                let mut working = mesh_records(&next);
                let tx = storage(open.connection.transaction())?;
                receive_files(
                    &vault_dir,
                    &tx,
                    &open.root,
                    &open.header.vault_id,
                    &packet["files"],
                )?;
                receive_remote_files(
                    &tx,
                    &open.root,
                    &open.header.vault_id,
                    peer,
                    &packet["remoteFiles"],
                )?;
                let mut changed = false;
                let mut applied = 0usize;
                for (key, record) in incoming {
                    if !valid_key(key) {
                        return Err(VaultError::InvalidData);
                    }
                    let stamp: Stamp = serde_json::from_value(record["stamp"].clone())
                        .map_err(|_| VaultError::InvalidData)?;
                    if stamp.0 > now.saturating_add(MAX_FUTURE_MS) || stamp.2.len() > 128 {
                        return Err(VaultError::InvalidData);
                    }
                    if stamp.0 > now.saturating_add(SKEW_NOTICE_MS) {
                        mesh.skew = true;
                    }
                    let value = record["value"].clone();
                    if key.starts_with("category:") && !(value.is_null() || value == json!(true)) {
                        return Err(VaultError::InvalidData);
                    }
                    if key.starts_with("item:") && !value.is_null() {
                        if value["id"].as_str() != key.strip_prefix("item:") {
                            return Err(VaultError::InvalidData);
                        }
                        let mut proposed = Document {
                            format_version: next.format_version,
                            ..Document::default()
                        };
                        proposed.items.push(value.clone());
                        let proposed = Document::parse(
                            &serde_json::to_vec(&proposed).map_err(|_| VaultError::InvalidData)?,
                        )?;
                        validate_files(&tx, &proposed)?;
                    }
                    let mut local = working.get(key).cloned().unwrap_or(Value::Null);
                    if !local.is_null() && key.starts_with("item:") {
                        note_bodies::hydrate_item(
                            &tx,
                            &open.root,
                            &open.header.vault_id,
                            &mut local,
                        )?;
                    }
                    // Existing legacy shared records never acquire new editing permission.
                    if !local.is_null()
                        && local != value
                        && (!local["sharedVaultId"].as_str().unwrap_or("").is_empty()
                            || !value["sharedVaultId"].as_str().unwrap_or("").is_empty())
                    {
                        continue;
                    }
                    let local_stamp = mesh
                        .meta
                        .get(key)
                        .map(|m| m.stamp.clone())
                        .unwrap_or_default();
                    mesh.observe(&stamp);
                    let wins = stamp > local_stamp
                        || (stamp == local_stamp
                            && local != value
                            && value_digest(&value) > value_digest(&local));

                    let concurrent_note = key.starts_with("item:")
                        && !local.is_null()
                        && !value.is_null()
                        && local != value
                        && local["type"] == "secureNote"
                        && value["type"] == "secureNote"
                        && local["isDeleted"] != true
                        && value["isDeleted"] != true
                        && local_stamp.0 > 0
                        && stamp.0 > 0
                        && !local_stamp.2.is_empty()
                        && !stamp.2.is_empty()
                        && local_stamp.2 != stamp.2;

                    if concurrent_note {
                        let note_id = key["item:".len()..].to_string();
                        let (winner, loser, loser_dev, winning_stamp) = if wins {
                            (&value, &local, mesh.device.as_str(), stamp.clone())
                        } else {
                            (&local, &value, peer, local_stamp.clone())
                        };
                        let base_item =
                            history::page(&tx, &open.root, &open.header.vault_id, &note_id, 0, 8)
                                .ok()
                                .and_then(|(_, revs)| {
                                    revs.into_iter().map(|r| r.item).find(|v| {
                                        v["note"] != winner["note"] && v["note"] != loser["note"]
                                    })
                                });
                        let merged = merge_concurrent_note(base_item.as_ref(), winner, loser);
                        if merged.has_overlap {
                            let rev_id = new_id();
                            history::write(
                                &tx,
                                &open.root,
                                &open.header.vault_id,
                                &history::Revision {
                                    id: rev_id.clone(),
                                    item_id: note_id.clone(),
                                    captured_at: if wins { local_stamp.0 } else { stamp.0 },
                                    item: loser.clone(),
                                    actor_type: Some("sync".into()),
                                    actor: Some(format!("并行分支 · {loser_dev}")),
                                    summary: Some(format!(
                                        "并发编辑保留分支（{}）",
                                        merged.conflict_section
                                    )),
                                    milestone: None,
                                },
                            )?;
                            mesh.note_conflicts.insert(
                                note_id.clone(),
                                NoteConflict {
                                    note_id,
                                    local_device: mesh.device.clone(),
                                    remote_device: peer.to_string(),
                                    revision_id: rev_id,
                                    captured_at: now,
                                    section: merged.conflict_section,
                                    auto_merged: merged.auto_merged,
                                    asset_guard: merged.asset_guard,
                                    retention_days: 30,
                                },
                            );
                        }
                        if merged.item != local {
                            working.insert(key.clone(), merged.item);
                            let next_stamp = if wins {
                                winning_stamp
                            } else {
                                mesh.local_stamp()
                            };
                            let seq = mesh.bump()?;
                            mesh.meta.insert(
                                key.clone(),
                                Meta {
                                    stamp: next_stamp,
                                    seq,
                                },
                            );
                            changed = true;
                            applied += 1;
                        } else if wins {
                            let seq = mesh.bump()?;
                            mesh.meta.insert(
                                key.clone(),
                                Meta {
                                    stamp: winning_stamp,
                                    seq,
                                },
                            );
                        }
                    } else if wins {
                        if local != value {
                            if value.is_null() {
                                working.remove(key);
                                if let Some(id) = key.strip_prefix("item:") {
                                    mesh.note_conflicts.remove(id);
                                }
                            } else {
                                working.insert(key.clone(), value);
                            }
                            let seq = mesh.bump()?;
                            mesh.meta.insert(key.clone(), Meta { stamp, seq });
                            changed = true;
                            applied += 1;
                        } else if let Some(meta) = mesh.meta.get_mut(key) {
                            meta.stamp = stamp;
                        } else {
                            let seq = mesh.bump()?;
                            mesh.meta.insert(key.clone(), Meta { stamp, seq });
                        }
                    } else if local != value && !value.is_null() && key.starts_with("item:") {
                        // Keep the older incoming edit recoverable from entry history.
                        history::write(
                            &tx,
                            &open.root,
                            &open.header.vault_id,
                            &history::Revision::plain(
                                new_id(),
                                key["item:".len()..].to_string(),
                                stamp.0,
                                value,
                            ),
                        )?;
                    }
                }
                let acked = mesh.acked.entry(peer.into()).or_default();
                *acked = (*acked).max(ack.min(mesh.seq));
                let received = mesh.received.entry(peer.into()).or_default();
                *received = (*received).max(upto);
                if !incoming.is_empty() {
                    mesh.ack_sent.remove(peer);
                }
                mesh.ensure_digests();
                if changed {
                    install_mesh(&mut next, &working)?;
                    validate_files(&tx, &next)?;
                    let persisted =
                        note_bodies::sync_and_strip(&tx, &open.root, &open.header.vault_id, &next)?;
                    mesh.baseline_digests = mesh_digests(&persisted);
                    mesh.baseline.clear();
                    store(&tx, &open.root, &open.header.vault_id, &mesh)?;
                    let saved = save_document_row_with_prev(
                        &tx,
                        &open.root,
                        &open.header.vault_id,
                        Some(&open.document),
                        &next,
                        None,
                    )?;
                    storage(tx.commit())?;
                    open.document = saved;
                    open.clear_hydrated_cache();
                } else {
                    store(&tx, &open.root, &open.header.vault_id, &mesh)?;
                    if next.format_version != open.document.format_version {
                        let saved = save_document_row_with_prev(
                            &tx,
                            &open.root,
                            &open.header.vault_id,
                            Some(&open.document),
                            &next,
                            None,
                        )?;
                        storage(tx.commit())?;
                        open.document = saved;
                    } else {
                        storage(tx.commit())?;
                    }
                }
                Ok(json!({
                    "ok": true,
                    "changed": changed,
                    "applied": applied,
                    "conflictCount": mesh.note_conflicts.len()
                }))
            }
            "relay-mesh-conflicts" => {
                let mut conflicts = Vec::new();
                let revs = history::read(&open.connection, &open.root, &open.header.vault_id)?;
                for cf in mesh.note_conflicts.values() {
                    let Some(mut local_item) = open
                        .document
                        .items
                        .iter()
                        .find(|i| i["id"] == cf.note_id && i["isDeleted"] != true)
                        .cloned()
                    else {
                        continue;
                    };
                    note_bodies::hydrate_item(
                        &open.connection,
                        &open.root,
                        &open.header.vault_id,
                        &mut local_item,
                    )?;
                    let remote_item = revs
                        .iter()
                        .find(|r| r.id == cf.revision_id && r.item_id == cf.note_id)
                        .map(|r| r.item.clone())
                        .unwrap_or(Value::Null);
                    conflicts.push(json!({
                        "noteId": cf.note_id,
                        "title": local_item["title"],
                        "localDevice": cf.local_device,
                        "remoteDevice": cf.remote_device,
                        "revisionId": cf.revision_id,
                        "capturedAt": cf.captured_at,
                        "section": cf.section,
                        "autoMerged": cf.auto_merged,
                        "assetGuard": cf.asset_guard,
                        "retentionDays": cf.retention_days,
                        "localItem": local_item,
                        "remoteItem": remote_item,
                    }));
                }
                Ok(json!({"conflicts": conflicts}))
            }
            "relay-mesh-resolve-conflict" => {
                let id = string(request, "id")?;
                let strategy = request["strategy"].as_str().unwrap_or("local");
                if !matches!(strategy, "local" | "remote" | "both" | "custom") {
                    return Err(VaultError::InvalidData);
                }
                let cf = mesh
                    .note_conflicts
                    .get(id)
                    .cloned()
                    .ok_or(VaultError::InvalidData)?;
                let mut local_item = open
                    .document
                    .items
                    .iter()
                    .find(|i| i["id"] == id)
                    .cloned()
                    .ok_or(VaultError::InvalidData)?;
                note_bodies::hydrate_item(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &mut local_item,
                )?;
                let remote_item =
                    history::read(&open.connection, &open.root, &open.header.vault_id)?
                        .into_iter()
                        .find(|r| r.id == cf.revision_id && r.item_id == id)
                        .map(|r| r.item);
                let resolved = match strategy {
                    "local" => local_item.clone(),
                    "remote" => {
                        let mut r = remote_item.ok_or(VaultError::InvalidData)?;
                        // Preserve R9 attachment union even when picking remote branch.
                        r = merge_concurrent_note(None, &r, &local_item).item;
                        r
                    }
                    "both" => {
                        let remote = remote_item.ok_or(VaultError::InvalidData)?;
                        let mut merged = merge_concurrent_note(None, &local_item, &remote).item;
                        let a_text = local_item["note"].as_str().unwrap_or("").trim();
                        let b_text = remote["note"].as_str().unwrap_or("").trim();
                        if !b_text.is_empty() && a_text != b_text {
                            let combined = format!(
                                "{a_text}\n\n---\n### 来自并行分支（{}）\n{b_text}",
                                cf.remote_device
                            );
                            merged["note"] = json!(combined);
                            if let Some(arr) = merged["noteDocument"]["content"].as_array_mut() {
                                arr.push(json!({"type":"horizontalRule"}));
                                arr.push(json!({"type":"heading","attrs":{"level":3},"content":[{"type":"text","text":format!("来自并行分支（{}）", cf.remote_device)}]}));
                                for line in b_text.lines().filter(|l| !l.trim().is_empty()) {
                                    arr.push(json!({"type":"paragraph","content":[{"type":"text","text":line}]}));
                                }
                            }
                        }
                        merged
                    }
                    "custom" => {
                        let custom = request
                            .get("item")
                            .cloned()
                            .ok_or(VaultError::InvalidData)?;
                        if custom["id"].as_str() != Some(id) {
                            return Err(VaultError::InvalidData);
                        }
                        custom
                    }
                    _ => return Err(VaultError::InvalidData),
                };
                let mut resolved_item = resolved;
                resolved_item["lastActor"] = json!("分支合并 · 我");
                resolved_item["lastSummary"] = json!(format!(
                    "已解决并行分支（策略：{strategy}，原分支保留 {} 天）",
                    cf.retention_days
                ));
                let mut next = open.document.clone();
                next.upsert(resolved_item.clone())?;
                mesh.note_conflicts.remove(id);
                let tx = storage(open.connection.transaction())?;
                store(&tx, &open.root, &open.header.vault_id, &mesh)?;
                let meta = history::HistoryMeta {
                    item_id: Some(id.to_owned()),
                    actor_type: Some("user".into()),
                    actor: Some("分支合并 · 我".into()),
                    summary: Some(format!("解决并行分支（{}）", cf.section)),
                    milestone: false,
                    coalesce: false,
                };
                let saved = save_document_row_with_prev(
                    &tx,
                    &open.root,
                    &open.header.vault_id,
                    Some(&open.document),
                    &next,
                    Some(&meta),
                )?;
                storage(tx.commit())?;
                open.document = saved;
                open.invalidate_hydrated(id);
                Ok(json!({
                    "ok": true,
                    "item": resolved_item,
                    "conflictCount": mesh.note_conflicts.len()
                }))
            }
            "relay-mesh-blob-export" => {
                let peer = string(request, "peer")?;
                let attachment_id = string(request, "attachmentId")?;
                if !mesh.peers.contains(peer) {
                    return Err(VaultError::Authentication);
                }
                let meta = notes::metas(&open.connection)?
                    .into_iter()
                    .find(|m| m.id == attachment_id)
                    .ok_or(VaultError::InvalidData)?;
                if notes::is_remote(&open.connection, &meta.id)? {
                    return Err(VaultError::Unsupported);
                }
                let bytes = notes::read(
                    &vault_dir,
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &meta,
                )?;
                Ok(json!({
                    "meta": meta,
                    "data": STANDARD.encode(bytes.as_slice()),
                }))
            }
            "relay-mesh-blob-receive" => {
                let peer = string(request, "peer")?;
                if !mesh.peers.contains(peer) {
                    return Err(VaultError::Authentication);
                }
                let meta: notes::AttachmentMeta = serde_json::from_value(request["meta"].clone())
                    .map_err(|_| VaultError::InvalidData)?;
                let bytes = Zeroizing::new(
                    STANDARD
                        .decode(string(request, "data")?)
                        .map_err(|_| VaultError::InvalidData)?,
                );
                if bytes.len() != meta.size || bytes.len() > crate::archive::FILE_LIMIT {
                    return Err(VaultError::InvalidData);
                }
                let tx = storage(open.connection.transaction())?;
                let existing = notes::metas(&tx)?;
                if let Some(old) = existing.iter().find(|m| m.id == meta.id) {
                    if serde_json::to_value(old).ok() != serde_json::to_value(&meta).ok() {
                        return Err(VaultError::InvalidData);
                    }
                    if !notes::is_remote(&tx, &old.id)?
                        && notes::read(&vault_dir, &tx, &open.root, &open.header.vault_id, old)?
                            .as_slice()
                            != bytes.as_slice()
                    {
                        return Err(VaultError::InvalidData);
                    }
                }
                notes::write(
                    &vault_dir,
                    &tx,
                    &open.root,
                    &open.header.vault_id,
                    &meta,
                    &bytes,
                )?;
                storage(tx.commit())?;
                Ok(json!({"ok": true, "id": meta.id, "state": "ready"}))
            }
            _ => Err(VaultError::Unsupported),
        }
    }

    pub(super) fn mesh_status(&mut self) -> Result<Option<Value>> {
        let open = self.open()?;
        if !enabled(&open.connection)? {
            return Ok(None);
        }
        let mesh = load(&open.connection, &open.root, &open.header.vault_id)?;
        let peers: BTreeMap<_, _> = mesh
            .peers
            .iter()
            .map(|p| {
                let acked = *mesh.acked.get(p).unwrap_or(&0);
                (
                    p.clone(),
                    json!({"unsent": mesh.meta.values().filter(|m| m.seq > acked).count()}),
                )
            })
            .collect();
        let remote_assets = notes::count_remote(&open.connection).unwrap_or(0);
        let note_conflicts: Vec<&NoteConflict> = mesh.note_conflicts.values().collect();
        Ok(Some(json!({
            "enabled":true,"mode":"mesh","group":mesh.group,"device":mesh.device,
            "peers":peers,"pending":0,"conflictCount":note_conflicts.len(),
            "noteConflicts":note_conflicts,"remoteAssetCount":remote_assets,"skew":mesh.skew,
            "migratedFrom":mesh.migrated_from,"archivedConflicts":mesh.archived_conflicts
        })))
    }

    pub(super) fn mesh_detach(&mut self, request: &Value) -> Result<Option<Value>> {
        let open = self.open()?;
        if !enabled(&open.connection)? {
            return Ok(None);
        }
        let mesh = load(&open.connection, &open.root, &open.header.vault_id)?;
        if string(request, "group")? != mesh.group || string(request, "device")? != mesh.device {
            return Err(VaultError::Authentication);
        }
        let tx = storage(open.connection.transaction())?;
        storage(tx.execute_batch("CREATE TABLE IF NOT EXISTS personal_mesh_archive(id INTEGER PRIMARY KEY, payload BLOB NOT NULL); INSERT INTO personal_mesh_archive(payload) SELECT payload FROM personal_mesh; DROP TABLE personal_mesh;"))?;
        storage(tx.commit())?;
        Ok(Some(json!({"ok":true})))
    }

    fn mesh_init(&mut self, request: &Value) -> Result<Value> {
        let group = string(request, "group")?;
        let device = string(request, "device")?;
        if !valid_name(group) || !valid_name(device) {
            return Err(VaultError::InvalidData);
        }
        {
            let open = self.open()?;
            if enabled(&open.connection)? {
                let mesh = load(&open.connection, &open.root, &open.header.vault_id)?;
                if mesh.group == group && mesh.device == device {
                    return Ok(json!({"ok":true,"already":true}));
                }
                return Err(VaultError::AlreadyExists);
            }
        }
        // Stable encrypted snapshot before the journal and history format change.
        let backup = self.directory.join("before-mesh-sync");
        if !backup.exists() {
            let stage = storage(
                tempfile::Builder::new()
                    .prefix(".mesh-backup-")
                    .tempdir_in(&self.directory),
            )?;
            protect_dir(stage.path())?;
            for file in ["header.json", "vault.sqlite"] {
                atomic_write(
                    &stage.path().join(file),
                    &storage(fs::read(self.directory.join(file)))?,
                )?;
            }
            note_blobs::copy_blobs_dir(&self.directory, stage.path())?;
            storage(fs::rename(stage.path(), &backup))?;
        }
        let open = self.open()?;
        let legacy = if super::enabled(&open.connection)? {
            Some(super::load(
                &open.connection,
                &open.root,
                &open.header.vault_id,
            )?)
        } else {
            None
        };
        let next = open.document.clone();
        let now = now_ms();
        let current = mesh_records(&next);
        let stamps = match &legacy {
            Some(state) if state.group == group => migrate(state, &next, device, now),
            _ => current
                .iter()
                .map(|(key, value)| {
                    let ms = crate::model::timestamp(value).max(0) as u64;
                    (key.clone(), Stamp(ms, 0, device.to_string()))
                })
                .collect(),
        };
        let tx = storage(open.connection.transaction())?;
        let persisted_next =
            note_bodies::sync_and_strip(&tx, &open.root, &open.header.vault_id, &next)?;
        let mut mesh = Mesh {
            version: 1,
            group: group.into(),
            device: device.into(),
            clock: (now, 0),
            seq: 0,
            meta: BTreeMap::new(),
            baseline: Records::new(),
            baseline_digests: mesh_digests(&persisted_next),
            peers: BTreeSet::new(),
            acked: BTreeMap::new(),
            received: BTreeMap::new(),
            ack_sent: BTreeMap::new(),
            skew: false,
            migrated_from: legacy.as_ref().map(|s| s.role.clone()),
            archived_conflicts: 0,
            note_conflicts: BTreeMap::new(),
        };
        for (key, stamp) in stamps {
            mesh.observe(&stamp);
            let seq = mesh.bump()?;
            mesh.meta.insert(key, Meta { stamp, seq });
        }
        history::table(&tx)?;
        if legacy.is_some() {
            storage(tx.execute_batch("CREATE TABLE IF NOT EXISTS personal_relay_archive(id INTEGER PRIMARY KEY, payload BLOB NOT NULL); INSERT INTO personal_relay_archive(payload) SELECT payload FROM personal_relay; DROP TABLE personal_relay;"))?;
        }
        storage(tx.execute_batch(
            "CREATE TABLE personal_mesh(id INTEGER PRIMARY KEY CHECK(id=1),payload BLOB NOT NULL)",
        ))?;
        store(&tx, &open.root, &open.header.vault_id, &mesh)?;
        // Saving first records the current version of every entry in history.
        let saved = save_document_row_with_prev(
            &tx,
            &open.root,
            &open.header.vault_id,
            Some(&open.document),
            &persisted_next,
            None,
        )?;
        if let Some(state) = &legacy {
            // Old hub conflicts become recoverable history instead of a blocking list.
            for conflict in state.conflicts.values() {
                if let Some(id) = conflict.change.key.strip_prefix("item:") {
                    if !conflict.change.value.is_null() {
                        history::write(
                            &tx,
                            &open.root,
                            &open.header.vault_id,
                            &history::Revision::plain(
                                new_id(),
                                id.to_string(),
                                now,
                                conflict.change.value.clone(),
                            ),
                        )?;
                        mesh.archived_conflicts += 1;
                    }
                }
            }
            store(&tx, &open.root, &open.header.vault_id, &mesh)?;
        }
        storage(tx.commit())?;
        let migrated = mesh.migrated_from.clone();
        open.document = saved;
        open.clear_hydrated_cache();
        Ok(json!({"ok":true,"migratedFrom":migrated,"archivedConflicts":mesh.archived_conflicts}))
    }
}

#[cfg(test)]
mod tests;
