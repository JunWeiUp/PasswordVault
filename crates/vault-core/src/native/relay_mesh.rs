//! Symmetric personal sync. Every member of the signed device group exchanges
//! whole-record values with every other member. The newest hybrid-logical stamp
//! wins; a losing incoming value is kept in entry history, and a losing local value
//! is already there because history captures every saved revision. Delivery
//! acknowledgements are internal resend bookkeeping only and are never a user step.
use super::*;

const MAX_FUTURE_MS: u64 = 7 * 24 * 60 * 60 * 1000;
const SKEW_NOTICE_MS: u64 = 5 * 60 * 1000;
const PACKET_VERSION: u64 = 3;

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
    baseline: Records,
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
}

pub(super) fn operation(op: &str) -> bool {
    matches!(
        op,
        "relay-mesh-init" | "relay-mesh-peers" | "relay-mesh-export" | "relay-mesh-receive"
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
}

/// Records local edits. Returns whether the mesh journal handled this save.
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
    let now = mesh_records(doc);
    let keys: BTreeSet<_> = now.keys().chain(mesh.baseline.keys()).cloned().collect();
    let mut dirty = false;
    for key in keys {
        let value = now.get(&key).unwrap_or(&Value::Null);
        if mesh.baseline.get(&key).unwrap_or(&Value::Null) == value {
            continue;
        }
        let stamp = mesh.local_stamp();
        let seq = mesh.bump()?;
        mesh.meta.insert(key, Meta { stamp, seq });
        dirty = true;
    }
    if dirty {
        mesh.baseline = now;
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
                    let value = current.get(key).cloned().unwrap_or(Value::Null);
                    values.insert(key.clone(), value.clone());
                    records.insert(key.clone(), json!({"value":value,"stamp":meta.stamp}));
                }
                let ack = *mesh.received.get(peer).unwrap_or(&0);
                if records.is_empty() && mesh.ack_sent.get(peer) == Some(&ack) {
                    return Ok(json!({"packet":null}));
                }
                let files = attachments(&vault_dir, open, &json!({"records":values}))?;
                mesh.ack_sent.insert(peer.into(), ack);
                store(&open.connection, &open.root, &open.header.vault_id, &mesh)?;
                Ok(json!({"packet":{
                    "version":PACKET_VERSION,"kind":"mesh","group":mesh.group,
                    "from":mesh.device,"to":peer,"formatVersion":open.document.format_version,
                    "upto":mesh.seq,"ack":ack,"records":records,"files":files
                }}))
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
                    let local = working.get(key).cloned().unwrap_or(Value::Null);
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
                    if wins {
                        if local != value {
                            if value.is_null() {
                                working.remove(key);
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
                if changed {
                    install_mesh(&mut next, &working)?;
                    validate_files(&tx, &next)?;
                    mesh.baseline = mesh_records(&next);
                }
                store(&tx, &open.root, &open.header.vault_id, &mesh)?;
                if changed || next.format_version != open.document.format_version {
                    save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
                }
                storage(tx.commit())?;
                open.document = next;
                Ok(json!({"ok":true,"changed":changed,"applied":applied}))
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
        Ok(Some(json!({
            "enabled":true,"mode":"mesh","group":mesh.group,"device":mesh.device,
            "peers":peers,"pending":0,"conflictCount":0,"skew":mesh.skew,
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
        let mut mesh = Mesh {
            version: 1,
            group: group.into(),
            device: device.into(),
            clock: (now, 0),
            seq: 0,
            meta: BTreeMap::new(),
            baseline: current,
            peers: BTreeSet::new(),
            acked: BTreeMap::new(),
            received: BTreeMap::new(),
            ack_sent: BTreeMap::new(),
            skew: false,
            migrated_from: legacy.as_ref().map(|s| s.role.clone()),
            archived_conflicts: 0,
        };
        for (key, stamp) in stamps {
            mesh.observe(&stamp);
            let seq = mesh.bump()?;
            mesh.meta.insert(key, Meta { stamp, seq });
        }
        let tx = storage(open.connection.transaction())?;
        history::table(&tx)?;
        if legacy.is_some() {
            storage(tx.execute_batch("CREATE TABLE IF NOT EXISTS personal_relay_archive(id INTEGER PRIMARY KEY, payload BLOB NOT NULL); INSERT INTO personal_relay_archive(payload) SELECT payload FROM personal_relay; DROP TABLE personal_relay;"))?;
        }
        storage(tx.execute_batch(
            "CREATE TABLE personal_mesh(id INTEGER PRIMARY KEY CHECK(id=1),payload BLOB NOT NULL)",
        ))?;
        store(&tx, &open.root, &open.header.vault_id, &mesh)?;
        // Saving first records the current version of every entry in history.
        save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
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
        open.document = load_document(&open.connection, &open.root, &open.header.vault_id)?;
        Ok(json!({"ok":true,"migratedFrom":migrated,"archivedConflicts":mesh.archived_conflicts}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn replica(dir: &std::path::Path, device: &str, peers: &[&str]) -> DiskVault {
        let mut vault = DiskVault::new(dir).unwrap();
        vault.create("fixture").unwrap();
        vault
            .relay_command(&json!({"op":"relay-mesh-init","group":"family","device":device}))
            .unwrap();
        vault
            .relay_command(&json!({"op":"relay-mesh-peers","peers":peers}))
            .unwrap();
        vault
    }
    fn save(vault: &mut DiskVault, id: &str, title: &str) {
        vault
            .command(&json!({"op":"save","item":{"id":id,"type":"password","title":title}}))
            .unwrap();
    }
    fn titles(vault: &mut DiskVault) -> BTreeMap<String, String> {
        vault
            .open()
            .unwrap()
            .document
            .items
            .iter()
            .map(|i| {
                (
                    i["id"].as_str().unwrap().into(),
                    i["title"].as_str().unwrap_or("").into(),
                )
            })
            .collect()
    }
    /// Delivers a pending packet; returns whether anything was sent.
    fn deliver(from: &mut DiskVault, from_id: &str, to: &mut DiskVault, to_id: &str) -> bool {
        let packet = from
            .relay_command(&json!({"op":"relay-mesh-export","peer":to_id}))
            .unwrap()["packet"]
            .clone();
        if packet.is_null() {
            return false;
        }
        to.relay_command(&json!({"op":"relay-mesh-receive","peer":from_id,"packet":packet}))
            .unwrap();
        true
    }
    fn settle(vaults: &mut [(&str, &mut DiskVault)]) {
        for _ in 0..8 {
            let mut sent = false;
            for i in 0..vaults.len() {
                for j in 0..vaults.len() {
                    if i == j {
                        continue;
                    }
                    let (a, b) = if i < j {
                        let (l, r) = vaults.split_at_mut(j);
                        (&mut l[i], &mut r[0])
                    } else {
                        let (l, r) = vaults.split_at_mut(i);
                        (&mut r[0], &mut l[j])
                    };
                    sent |= deliver(a.1, a.0, b.1, b.0);
                }
            }
            if !sent {
                return;
            }
        }
        panic!("replicas did not become idle");
    }
    fn history_titles(vault: &mut DiskVault, id: &str) -> Vec<String> {
        let open = vault.open().unwrap();
        history::read(&open.connection, &open.root, &open.header.vault_id)
            .unwrap()
            .into_iter()
            .filter(|r| r.item_id == id)
            .map(|r| r.item["title"].as_str().unwrap_or("").to_string())
            .collect()
    }

    #[test]
    fn edits_flow_both_ways_and_newest_wins_with_loser_in_history() {
        let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let mut a = replica(da.path(), "mac", &["phone"]);
        let mut b = replica(db.path(), "phone", &["mac"]);
        save(&mut a, "a1", "from mac");
        save(&mut b, "b1", "from phone");
        settle(&mut [("mac", &mut a), ("phone", &mut b)]);
        assert_eq!(titles(&mut a), titles(&mut b));
        assert_eq!(titles(&mut a).len(), 2);
        // Concurrent edits of the same record: the later stamp wins on both sides.
        save(&mut a, "a1", "mac edit");
        std::thread::sleep(std::time::Duration::from_millis(5));
        save(&mut b, "a1", "phone edit");
        settle(&mut [("mac", &mut a), ("phone", &mut b)]);
        assert_eq!(titles(&mut a)["a1"], "phone edit");
        assert_eq!(titles(&mut b)["a1"], "phone edit");
        assert!(history_titles(&mut a, "a1").contains(&"mac edit".to_string()));
        assert!(history_titles(&mut b, "a1").contains(&"mac edit".to_string()));
        // Idle replicas exchange nothing further.
        assert!(!deliver(&mut a, "mac", &mut b, "phone"));
        assert!(!deliver(&mut b, "phone", &mut a, "mac"));
    }

    #[test]
    fn three_replicas_converge_in_any_order_and_delete_versus_edit_uses_stamp() {
        let dirs: Vec<_> = (0..3).map(|_| tempfile::tempdir().unwrap()).collect();
        let mut a = replica(dirs[0].path(), "a", &["b", "c"]);
        let mut b = replica(dirs[1].path(), "b", &["a", "c"]);
        let mut c = replica(dirs[2].path(), "c", &["a", "b"]);
        save(&mut a, "x", "base");
        settle(&mut [("a", &mut a), ("b", &mut b), ("c", &mut c)]);
        b.command(&json!({"op":"remove","id":"x","richNotes":true}))
            .unwrap();
        assert!(!titles(&mut b).contains_key("x"));
        std::thread::sleep(std::time::Duration::from_millis(5));
        save(&mut c, "x", "edited after delete");
        // Deliver c first to a, then b's delete: arrival order must not matter.
        deliver(&mut c, "c", &mut a, "a");
        deliver(&mut b, "b", &mut a, "a");
        settle(&mut [("a", &mut a), ("b", &mut b), ("c", &mut c)]);
        let (ta, tb, tc) = (titles(&mut a), titles(&mut b), titles(&mut c));
        assert_eq!(ta, tb);
        assert_eq!(tb, tc);
        assert_eq!(ta.get("x").map(String::as_str), Some("edited after delete"));
    }

    #[test]
    fn unknown_or_removed_peers_and_future_stamps_are_rejected() {
        let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let mut a = replica(da.path(), "mac", &["phone"]);
        let mut b = replica(db.path(), "phone", &["mac"]);
        save(&mut a, "a1", "secret");
        assert!(matches!(
            a.relay_command(&json!({"op":"relay-mesh-export","peer":"stranger"})),
            Err(VaultError::Authentication)
        ));
        let packet = a
            .relay_command(&json!({"op":"relay-mesh-export","peer":"phone"}))
            .unwrap()["packet"]
            .clone();
        assert!(matches!(
            b.relay_command(&json!({"op":"relay-mesh-receive","peer":"stranger","packet":packet})),
            Err(VaultError::Authentication)
        ));
        let mut forged = packet.clone();
        forged["records"]["item:a1"]["stamp"] =
            json!([now_ms() + MAX_FUTURE_MS + 60_000, 0, "mac"]);
        assert!(b
            .relay_command(&json!({"op":"relay-mesh-receive","peer":"mac","packet":forged}))
            .is_err());
        assert!(titles(&mut b).is_empty());
        b.relay_command(&json!({"op":"relay-mesh-peers","peers":[]}))
            .unwrap();
        assert!(matches!(
            b.relay_command(&json!({"op":"relay-mesh-receive","peer":"mac","packet":packet})),
            Err(VaultError::Authentication)
        ));
        assert!(titles(&mut b).is_empty());
    }

    #[test]
    fn replay_is_idempotent_and_categories_merge() {
        let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let mut a = replica(da.path(), "mac", &["phone"]);
        let mut b = replica(db.path(), "phone", &["mac"]);
        a.command(&json!({"op":"category-add","name":"Work"})).ok();
        b.command(&json!({"op":"category-add","name":"Home"})).ok();
        save(&mut a, "a1", "one");
        let packet = a
            .relay_command(&json!({"op":"relay-mesh-export","peer":"phone"}))
            .unwrap()["packet"]
            .clone();
        b.relay_command(&json!({"op":"relay-mesh-receive","peer":"mac","packet":packet}))
            .unwrap();
        let replay = b
            .relay_command(&json!({"op":"relay-mesh-receive","peer":"mac","packet":packet}))
            .unwrap();
        assert_eq!(replay["changed"], false);
        settle(&mut [("mac", &mut a), ("phone", &mut b)]);
        let ca: BTreeSet<_> = a
            .open()
            .unwrap()
            .document
            .note_categories()
            .into_iter()
            .collect();
        let cb: BTreeSet<_> = b
            .open()
            .unwrap()
            .document
            .note_categories()
            .into_iter()
            .collect();
        assert_eq!(ca, cb);
        if ca.contains("Work") || cb.contains("Home") {
            assert!(ca.contains("Work") && ca.contains("Home"));
        }
    }

    #[test]
    fn legacy_hub_and_mobile_journals_migrate_without_losing_pending_edits() {
        let (dh, dm) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let mut hub = DiskVault::new(dh.path()).unwrap();
        hub.create("fixture").unwrap();
        hub.relay_command(
            &json!({"op":"relay-init","role":"hub","group":"family","device":"mac","hub":"mac"}),
        )
        .unwrap();
        hub.relay_command(&json!({"op":"relay-trust","peer":"phone"}))
            .unwrap();
        let mut phone = DiskVault::new(dm.path()).unwrap();
        phone.create("fixture").unwrap();
        phone.relay_command(&json!({"op":"relay-init","role":"mobile","group":"family","device":"phone","hub":"mac"})).unwrap();
        phone
            .relay_command(&json!({"op":"relay-trust","peer":"mac"}))
            .unwrap();
        save(&mut hub, "shared", "synced value");
        let snap = hub
            .relay_command(&json!({"op":"relay-export","peer":"phone"}))
            .unwrap();
        phone
            .relay_command(&json!({"op":"relay-receive","peer":"mac","packet":snap}))
            .unwrap();
        let changes = phone
            .relay_command(&json!({"op":"relay-export","peer":"mac"}))
            .unwrap();
        hub.relay_command(&json!({"op":"relay-receive","peer":"phone","packet":changes}))
            .unwrap();
        let snap = hub
            .relay_command(&json!({"op":"relay-export","peer":"phone"}))
            .unwrap();
        phone
            .relay_command(&json!({"op":"relay-receive","peer":"mac","packet":snap}))
            .unwrap();
        // Unconfirmed phone edit plus a conflicting hub edit made in the old protocol.
        save(&mut phone, "offline", "phone only, not yet confirmed");
        save(&mut phone, "shared", "phone conflicting edit");
        let changes = phone
            .relay_command(&json!({"op":"relay-export","peer":"mac"}))
            .unwrap();
        save(&mut hub, "shared", "mac newer edit");
        hub.relay_command(&json!({"op":"relay-receive","peer":"phone","packet":changes}))
            .unwrap();
        assert!(
            hub.relay_command(&json!({"op":"relay-status"})).unwrap()["conflicts"]
                .as_object()
                .unwrap()
                .is_empty()
                .then_some(())
                .is_none()
        );
        assert!(
            phone.relay_command(&json!({"op":"relay-status"})).unwrap()["pending"]
                .as_u64()
                .unwrap()
                >= 1
        );

        let migrated = hub
            .relay_command(&json!({"op":"relay-mesh-init","group":"family","device":"mac"}))
            .unwrap();
        assert_eq!(migrated["migratedFrom"], "hub");
        assert!(migrated["archivedConflicts"].as_u64().unwrap() >= 1);
        assert!(
            dh.path()
                .join("vault/before-mesh-sync/vault.sqlite")
                .exists()
                || dh.path().join("before-mesh-sync/vault.sqlite").exists()
        );
        phone
            .relay_command(&json!({"op":"relay-mesh-init","group":"family","device":"phone"}))
            .unwrap();
        hub.relay_command(&json!({"op":"relay-mesh-peers","peers":["phone"]}))
            .unwrap();
        phone
            .relay_command(&json!({"op":"relay-mesh-peers","peers":["mac"]}))
            .unwrap();
        assert_eq!(
            hub.relay_command(&json!({"op":"relay-status"})).unwrap()["mode"],
            "mesh"
        );
        settle(&mut [("mac", &mut hub), ("phone", &mut phone)]);
        let (th, tp) = (titles(&mut hub), titles(&mut phone));
        assert_eq!(th, tp);
        assert_eq!(th["offline"], "phone only, not yet confirmed");
        // The phone edit was still unconfirmed, so it carries a real timestamp stamp and wins;
        // the hub's version stays recoverable in history.
        assert_eq!(th["shared"], "phone conflicting edit");
        let kept = history_titles(&mut hub, "shared");
        assert!(kept.contains(&"mac newer edit".to_string()), "{kept:?}");
        // The old conflict list is gone and nothing waits for confirmation.
        let status = hub.relay_command(&json!({"op":"relay-status"})).unwrap();
        assert_eq!(status["conflictCount"], 0);
        assert_eq!(status["pending"], 0);
    }
}
