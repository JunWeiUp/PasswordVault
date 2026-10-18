//! Personal-vault replication. The relay transports bytes; only the Mac commits revisions.
//! Every journal update shares the SQLCipher transaction with the document write.
use super::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

type Records = BTreeMap<String, Value>;
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Change {
    id: String,
    key: String,
    base: u64,
    value: Value,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Conflict {
    peer: String,
    change: Change,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct State {
    version: u32,
    role: String,
    group: String,
    device: String,
    hub: String,
    peers: BTreeSet<String>,
    revision: u64,
    cursor: u64,
    cursors: BTreeMap<String, u64>,
    baseline: Records,
    canonical: Records,
    revisions: BTreeMap<String, u64>,
    pending: BTreeMap<String, Change>,
    seen: BTreeMap<String, String>,
    conflicts: BTreeMap<String, Conflict>,
    receipts: BTreeMap<String, BTreeSet<String>>,
}
pub(super) fn enabled(conn: &Connection) -> Result<bool> {
    Ok(storage(conn.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='personal_relay'",
        [],
        |r| r.get::<_, i64>(0),
    ))? != 0)
}
// Archived sync state can reference attachments absent from the current document.
pub(super) fn retains_attachments(conn: &Connection) -> Result<bool> {
    Ok(enabled(conn)? || storage(conn.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='personal_relay_archive'",
        [], |r| r.get::<_, i64>(0),
    ))? != 0)
}
fn load(conn: &Connection, root: &[u8; 32], vault: &str) -> Result<State> {
    let data: Vec<u8> = storage(conn.query_row(
        "SELECT payload FROM personal_relay WHERE id=1",
        [],
        |r| r.get(0),
    ))?;
    let sealed: Sealed = serde_json::from_slice(&data).map_err(|_| VaultError::InvalidData)?;
    serde_json::from_slice(&unseal(
        &subkey(root, b"personal-relay-v1"),
        &sealed,
        vault.as_bytes(),
    )?)
    .map_err(|_| VaultError::InvalidData)
}
fn store(conn: &Connection, root: &[u8; 32], vault: &str, state: &State) -> Result<()> {
    let data = Zeroizing::new(serde_json::to_vec(state).map_err(|_| VaultError::InvalidData)?);
    let sealed = seal(&subkey(root, b"personal-relay-v1"), &data, vault.as_bytes())?;
    storage(conn.execute("INSERT INTO personal_relay(id,payload) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",[serde_json::to_vec(&sealed).map_err(|_|VaultError::InvalidData)?]))?;
    Ok(())
}
fn records(doc: &Document) -> Records {
    let mut out = Records::new();
    for item in &doc.items {
        out.insert(
            format!("item:{}", item["id"].as_str().unwrap_or_default()),
            item.clone(),
        );
    }
    out.insert("categories".into(), json!(doc.note_categories()));
    out
}
fn install(doc: &mut Document, values: &Records) -> Result<()> {
    doc.items = values
        .iter()
        .filter(|(k, v)| k.starts_with("item:") && !v.is_null())
        .map(|(_, v)| v.clone())
        .collect();
    doc.settings["noteCategories"] = values.get("categories").cloned().unwrap_or(json!([]));
    doc.format_version = 4;
    *doc = Document::parse(&serde_json::to_vec(doc).map_err(|_| VaultError::InvalidData)?)?;
    Ok(())
}
fn commit(state: &mut State, key: &str, value: Value) -> Result<()> {
    state.revision = state
        .revision
        .checked_add(1)
        .ok_or(VaultError::InvalidData)?;
    state.revisions.insert(key.into(), state.revision);
    state.canonical.insert(key.into(), value);
    Ok(())
}
pub(super) fn capture(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    doc: &Document,
) -> Result<()> {
    if !enabled(conn)? {
        return Ok(());
    }
    let mut state = load(conn, root, vault)?;
    let now = records(doc);
    let keys: BTreeSet<_> = now.keys().chain(state.baseline.keys()).cloned().collect();
    for key in keys {
        let value = now.get(&key).cloned().unwrap_or(Value::Null);
        if state.baseline.get(&key).unwrap_or(&Value::Null) == &value {
            continue;
        }
        if state.role == "hub" {
            commit(&mut state, &key, value)?;
        } else {
            let base = *state.revisions.get(&key).unwrap_or(&0);
            state.pending.insert(
                key.clone(),
                Change {
                    id: new_id(),
                    key,
                    base,
                    value,
                },
            );
        }
    }
    state.baseline = now;
    store(conn, root, vault, &state)
}
fn valid_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_".contains(&c))
}
fn string<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str().ok_or(VaultError::InvalidData)
}
fn attachments(open: &OpenVault, packet: &Value) -> Result<Value> {
    let mut needed = std::collections::HashSet::new();
    if let Some(records) = packet["records"].as_object() {
        for item in records.values() {
            notes::refs(&item["noteDocument"], &mut needed, 0)?;
        }
    }
    if let Some(changes) = packet["changes"].as_array() {
        for change in changes {
            notes::refs(&change["value"]["noteDocument"], &mut needed, 0)?;
        }
    }
    let mut files = Vec::new();
    for meta in notes::metas(&open.connection)? {
        if !needed.contains(&meta.id) {
            continue;
        }
        let bytes = notes::read(&open.connection, &open.root, &open.header.vault_id, &meta)?;
        files.push(json!({"meta":meta,"data":STANDARD.encode(bytes.as_slice())}));
    }
    Ok(json!(files))
}
fn receive_files(conn: &Connection, root: &[u8; 32], vault: &str, files: &Value) -> Result<()> {
    let files = files.as_array().ok_or(VaultError::InvalidData)?;
    if files.len() > 10000 {
        return Err(VaultError::InvalidData);
    }
    let existing = notes::metas(conn)?;
    let mut total = 0usize;
    let mut ids = BTreeSet::new();
    for file in files {
        let meta: notes::AttachmentMeta =
            serde_json::from_value(file["meta"].clone()).map_err(|_| VaultError::InvalidData)?;
        let bytes = Zeroizing::new(
            STANDARD
                .decode(string(file, "data")?)
                .map_err(|_| VaultError::InvalidData)?,
        );
        total = total
            .checked_add(bytes.len())
            .ok_or(VaultError::InvalidData)?;
        if bytes.len() != meta.size
            || bytes.len() > 25 * 1024 * 1024
            || total > 512 * 1024 * 1024
            || !ids.insert(meta.id.clone())
        {
            return Err(VaultError::InvalidData);
        }
        if let Some(old) = existing.iter().find(|m| m.id == meta.id) {
            if serde_json::to_value(old).ok() != serde_json::to_value(&meta).ok()
                || notes::read(conn, root, vault, old)?.as_slice() != bytes.as_slice()
            {
                return Err(VaultError::InvalidData);
            }
        } else {
            notes::write(conn, root, vault, &meta, &bytes)?;
        }
    }
    Ok(())
}
fn replace_attachment(node: &mut Value, old: &str, new: &str) {
    if node["attrs"]["attachmentId"] == old {
        node["attrs"]["attachmentId"] = json!(new);
    }
    if let Some(children) = node["content"].as_array_mut() {
        for child in children {
            replace_attachment(child, old, new);
        }
    }
}
fn validate_files(conn: &Connection, doc: &Document) -> Result<()> {
    let files = notes::metas(conn)?
        .into_iter()
        .filter(|m| doc.items.iter().any(|i| i["id"] == m.note_id))
        .collect::<Vec<_>>();
    notes::validate(doc, &files)
}
impl DiskVault {
    pub(super) fn relay_command(&mut self, request: &Value) -> Result<Value> {
        let op = string(request, "op")?;
        if op == "relay-init" {
            let role = string(request, "role")?;
            let group = string(request, "group")?;
            let device = string(request, "device")?;
            let hub = string(request, "hub")?;
            if !["hub", "mobile"].contains(&role)
                || ![group, device, hub].iter().all(|s| valid_name(s))
                || (role == "hub" && hub != device)
            {
                return Err(VaultError::InvalidData);
            }
            if enabled(&self.open()?.connection)? {
                return Err(VaultError::AlreadyExists);
            }
            // Stable encrypted snapshot before enabling the new document format.
            self.open()?;
            let backup = self.directory.join("before-personal-relay");
            if !backup.exists() {
                let stage = storage(
                    tempfile::Builder::new()
                        .prefix(".relay-backup-")
                        .tempdir_in(&self.directory),
                )?;
                protect_dir(stage.path())?;
                for file in ["header.json", "vault.sqlite"] {
                    atomic_write(
                        &stage.path().join(file),
                        &storage(fs::read(self.directory.join(file)))?,
                    )?;
                }
                storage(fs::rename(stage.path(), &backup))?;
            }
            let open = self.open()?;
            let mut next = open.document.clone();
            next.format_version = 4;
            let baseline = records(&next);
            let mut state = State {
                version: 1,
                role: role.into(),
                group: group.into(),
                device: device.into(),
                hub: hub.into(),
                peers: BTreeSet::new(),
                revision: 0,
                cursor: 0,
                cursors: BTreeMap::new(),
                baseline: baseline.clone(),
                canonical: Records::new(),
                revisions: BTreeMap::new(),
                pending: BTreeMap::new(),
                seen: BTreeMap::new(),
                conflicts: BTreeMap::new(),
                receipts: BTreeMap::new(),
            };
            for (key, value) in baseline {
                if role == "hub" {
                    commit(&mut state, &key, value)?;
                } else {
                    state.pending.insert(
                        key.clone(),
                        Change {
                            id: new_id(),
                            key,
                            base: 0,
                            value,
                        },
                    );
                }
            }
            let tx = storage(open.connection.transaction())?;
            storage(tx.execute_batch("CREATE TABLE personal_relay(id INTEGER PRIMARY KEY CHECK(id=1),payload BLOB NOT NULL)"))?;
            store(&tx, &open.root, &open.header.vault_id, &state)?;
            save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
            storage(tx.commit())?;
            open.document = next;
            return Ok(json!({"ok":true}));
        }
        let open = self.open()?;
        if !enabled(&open.connection)? {
            if op == "relay-status" {
                return Ok(json!({"enabled":false}));
            }
            return Err(VaultError::Unsupported);
        }
        let mut state = load(&open.connection, &open.root, &open.header.vault_id)?;
        if op == "relay-detach" {
            if string(request, "group")? != state.group
                || string(request, "device")? != state.device
            {
                return Err(VaultError::Authentication);
            }
            // Preserve the authenticated journal, including pending edits and conflicts.
            // A new group starts from the current document, never old receipts/tombstones.
            let tx = storage(open.connection.transaction())?;
            storage(tx.execute_batch("CREATE TABLE IF NOT EXISTS personal_relay_archive(id INTEGER PRIMARY KEY, payload BLOB NOT NULL); INSERT INTO personal_relay_archive(payload) SELECT payload FROM personal_relay; DROP TABLE personal_relay;"))?;
            storage(tx.commit())?;
            return Ok(json!({"ok":true}));
        }

        if op == "relay-status" {
            let conflicts:BTreeMap<_,_>=state.conflicts.iter().map(|(id,c)|(id,json!({"peer":c.peer,"change":c.change,"local":state.canonical.get(&c.change.key)}))).collect();
            return Ok(
                json!({"enabled":true,"role":state.role,"group":state.group,"device":state.device,"hub":state.hub,"peers":state.peers,"revision":state.revision,"cursor":state.cursor,"pending":state.pending.len(),"conflicts":conflicts}),
            );
        }
        if op == "relay-export" {
            let peer = string(request, "peer")?;
            if !state.peers.contains(peer) {
                return Err(VaultError::Authentication);
            }
            let packet = if state.role == "hub" {
                let cursor = *state.cursors.get(peer).unwrap_or(&0);
                let values: Records = state
                    .canonical
                    .iter()
                    .filter(|(key, _)| state.revisions.get(*key).copied().unwrap_or(0) > cursor)
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect();
                json!({"version":1,"group":state.group,"hub":state.hub,"kind":"snapshot","baseCursor":cursor,"revision":state.revision,"records":values,"revisions":state.revisions,"receipts":state.receipts.get(peer)})
            } else {
                json!({"version":1,"group":state.group,"hub":state.hub,"kind":"changes","cursor":state.cursor,"changes":state.pending.values().collect::<Vec<_>>()})
            };
            let mut packet = packet;
            packet["files"] = attachments(open, &packet)?;
            return Ok(packet);
        }
        let mut next = open.document.clone();
        let tx = storage(open.connection.transaction())?;
        match op {
            "relay-trust" | "relay-revoke" => {
                let peer = string(request, "peer")?;
                if !valid_name(peer)
                    || peer == state.device
                    || (state.role == "mobile" && peer != state.hub)
                {
                    return Err(VaultError::InvalidData);
                }
                if op == "relay-trust" {
                    state.peers.insert(peer.into());
                } else {
                    state.peers.remove(peer);
                }
            }
            "relay-receive" => {
                let peer = string(request, "peer")?;
                if !state.peers.contains(peer) {
                    return Err(VaultError::Authentication);
                }
                let packet = &request["packet"];
                if packet["version"] != 1
                    || packet["group"] != state.group
                    || packet["hub"] != state.hub
                {
                    return Err(VaultError::Authentication);
                }
                receive_files(&tx, &open.root, &open.header.vault_id, &packet["files"])?;
                if state.role == "hub" {
                    if packet["kind"] != "changes" {
                        return Err(VaultError::InvalidData);
                    }
                    let cursor = packet["cursor"].as_u64().ok_or(VaultError::InvalidData)?;
                    if cursor > state.revision {
                        return Err(VaultError::InvalidData);
                    }
                    // A peer restoring an older local copy may request a fresh baseline.
                    state.cursors.insert(peer.into(), cursor);
                    let changes: Vec<Change> = serde_json::from_value(packet["changes"].clone())
                        .map_err(|_| VaultError::InvalidData)?;
                    if changes.len() > 100001 {
                        return Err(VaultError::InvalidData);
                    }
                    for change in changes {
                        if !valid_name(&change.id)
                            || !(change.key == "categories" || change.key.starts_with("item:"))
                        {
                            return Err(VaultError::InvalidData);
                        }
                        if change.key.starts_with("item:")
                            && !change.value.is_null()
                            && change.value["id"].as_str() != change.key.strip_prefix("item:")
                        {
                            return Err(VaultError::InvalidData);
                        }
                        if !change.value.is_null() && change.key.starts_with("item:") {
                            let mut proposed = Document {
                                format_version: 4,
                                ..Document::default()
                            };
                            proposed.items.push(change.value.clone());
                            let proposed = Document::parse(
                                &serde_json::to_vec(&proposed)
                                    .map_err(|_| VaultError::InvalidData)?,
                            )?;
                            validate_files(&tx, &proposed)?;
                        }
                        // Existing legacy shared records never acquire new editing permission.
                        let old = state.canonical.get(&change.key).unwrap_or(&Value::Null);
                        if (!old["sharedVaultId"].as_str().unwrap_or("").is_empty()
                            || !change.value["sharedVaultId"]
                                .as_str()
                                .unwrap_or("")
                                .is_empty())
                            && !old.is_null()
                            && old != &change.value
                        {
                            return Err(VaultError::Unsupported);
                        }
                        let id = format!("{peer}:{}", change.id);
                        let digest = hex::encode(Sha256::digest(
                            serde_json::to_vec(&change).map_err(|_| VaultError::InvalidData)?,
                        ));
                        if let Some(prior) = state.seen.get(&id) {
                            if prior != &digest {
                                return Err(VaultError::Authentication);
                            }
                            continue;
                        }
                        if old == &change.value
                            || change.base == *state.revisions.get(&change.key).unwrap_or(&0)
                        {
                            if old != &change.value {
                                commit(&mut state, &change.key, change.value.clone())?;
                            }
                            state
                                .receipts
                                .entry(peer.into())
                                .or_default()
                                .insert(change.id.clone());
                        } else {
                            state.conflicts.insert(
                                id.clone(),
                                Conflict {
                                    peer: peer.into(),
                                    change: change.clone(),
                                },
                            );
                        }
                        state.seen.insert(id, digest);
                    }
                    install(&mut next, &state.canonical)?;
                } else {
                    if peer != state.hub || packet["kind"] != "snapshot" {
                        return Err(VaultError::Authentication);
                    }
                    let revision = packet["revision"].as_u64().ok_or(VaultError::InvalidData)?;
                    if revision < state.cursor {
                        return Ok(json!({"ok":true,"stale":true}));
                    }
                    let values: Records = serde_json::from_value(packet["records"].clone())
                        .map_err(|_| VaultError::InvalidData)?;
                    let revisions: BTreeMap<String, u64> =
                        serde_json::from_value(packet["revisions"].clone())
                            .map_err(|_| VaultError::InvalidData)?;
                    let receipts: BTreeSet<String> = if packet["receipts"].is_null() {
                        BTreeSet::new()
                    } else {
                        serde_json::from_value(packet["receipts"].clone())
                            .map_err(|_| VaultError::InvalidData)?
                    };
                    state.pending.retain(|_, c| !receipts.contains(&c.id));
                    let base = packet["baseCursor"]
                        .as_u64()
                        .ok_or(VaultError::InvalidData)?;
                    if base > state.cursor {
                        return Err(VaultError::InvalidData);
                    }
                    if base == 0 {
                        state.canonical = values;
                    } else {
                        state.canonical.extend(values);
                    }
                    state.revisions = revisions;
                    state.cursor = revision;
                    let mut overlay = state.canonical.clone();
                    for (key, c) in &state.pending {
                        overlay.insert(key.clone(), c.value.clone());
                    }
                    install(&mut next, &overlay)?;
                }
            }
            "relay-resolve" => {
                if state.role != "hub" {
                    return Err(VaultError::Authentication);
                }
                let id = string(request, "conflict")?;
                let conflict = state.conflicts.remove(id).ok_or(VaultError::InvalidData)?;
                match string(request, "choice")? {
                    "remote" => commit(
                        &mut state,
                        &conflict.change.key,
                        conflict.change.value.clone(),
                    )?,
                    "local" => {}
                    "both" => {
                        if conflict.change.key == "categories" {
                            let mut categories = BTreeSet::new();
                            for value in [
                                state.canonical.get("categories").unwrap_or(&Value::Null),
                                &conflict.change.value,
                            ] {
                                for category in value.as_array().ok_or(VaultError::InvalidData)? {
                                    categories.insert(
                                        category
                                            .as_str()
                                            .ok_or(VaultError::InvalidData)?
                                            .to_string(),
                                    );
                                }
                            }
                            commit(&mut state, "categories", json!(categories))?;
                        } else {
                            let mut value = if conflict.change.value.is_null() {
                                let local = state
                                    .canonical
                                    .get(&conflict.change.key)
                                    .cloned()
                                    .unwrap_or(Value::Null);
                                commit(&mut state, &conflict.change.key, Value::Null)?;
                                local
                            } else {
                                conflict.change.value.clone()
                            };
                            if !value.is_null() {
                                let id = new_id();
                                value["id"] = json!(id);
                                if value["noteFormat"] == "rich-v1" {
                                    let mut used = std::collections::HashSet::new();
                                    notes::refs(&value["noteDocument"], &mut used, 0)?;
                                    let available = notes::metas(&tx)?;
                                    for old_id in used {
                                        let old = available
                                            .iter()
                                            .find(|m| m.id == old_id)
                                            .ok_or(VaultError::InvalidData)?;
                                        let bytes = notes::read(
                                            &tx,
                                            &open.root,
                                            &open.header.vault_id,
                                            old,
                                        )?;
                                        let mut meta = old.clone();
                                        meta.id = new_id();
                                        meta.note_id = id.clone();
                                        replace_attachment(
                                            &mut value["noteDocument"],
                                            &old_id,
                                            &meta.id,
                                        );
                                        notes::write(
                                            &tx,
                                            &open.root,
                                            &open.header.vault_id,
                                            &meta,
                                            &bytes,
                                        )?;
                                    }
                                }
                                commit(&mut state, &format!("item:{id}"), value)?;
                            }
                        }
                    }
                    _ => return Err(VaultError::InvalidData),
                }
                state
                    .receipts
                    .entry(conflict.peer)
                    .or_default()
                    .insert(conflict.change.id);
                install(&mut next, &state.canonical)?;
            }
            _ => return Err(VaultError::Unsupported),
        }
        validate_files(&tx, &next)?;
        state.baseline = records(&next);
        store(&tx, &open.root, &open.header.vault_id, &state)?;
        save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
        storage(tx.commit())?;
        open.document = next;
        Ok(json!({"ok":true}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn failed_journal_write_rolls_back_document() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = DiskVault::new(dir.path()).unwrap();
        vault.create("fixture").unwrap();
        vault
            .relay_command(
                &json!({"op":"relay-init","role":"hub","group":"test","device":"mac","hub":"mac"}),
            )
            .unwrap();
        let open = vault.open().unwrap();
        open.connection.execute_batch("CREATE TRIGGER reject_relay BEFORE UPDATE ON personal_relay BEGIN SELECT RAISE(ABORT,'fixture failure'); END;").unwrap();
        assert!(vault
            .command(
                &json!({"op":"save","item":{"id":"a","type":"password","title":"never committed"}})
            )
            .is_err());
        assert!(vault.open().unwrap().document.items.is_empty());
        vault.lock();
        vault.unlock("fixture").unwrap();
        assert!(vault.open().unwrap().document.items.is_empty());
    }
    #[test]
    fn detach_archive_failure_preserves_binding_and_encrypted_history() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = DiskVault::new(dir.path()).unwrap();
        vault.create("fixture").unwrap();
        vault.relay_command(&json!({"op":"relay-init","role":"mobile","group":"test","device":"phone","hub":"mac"})).unwrap();
        let before = vault.relay_command(&json!({"op":"relay-status"})).unwrap();
        vault.open().unwrap().connection.execute_batch("CREATE TABLE personal_relay_archive(id INTEGER PRIMARY KEY,payload BLOB NOT NULL); CREATE TRIGGER reject_archive BEFORE INSERT ON personal_relay_archive BEGIN SELECT RAISE(ABORT,'fixture failure'); END;").unwrap();
        assert!(vault
            .relay_command(&json!({"op":"relay-detach","group":"test","device":"phone"}))
            .is_err());
        assert_eq!(
            vault.relay_command(&json!({"op":"relay-status"})).unwrap(),
            before
        );
        vault
            .open()
            .unwrap()
            .connection
            .execute_batch("DROP TRIGGER reject_archive")
            .unwrap();
        vault
            .relay_command(&json!({"op":"relay-detach","group":"test","device":"phone"}))
            .unwrap();
        let open = vault.open().unwrap();
        assert!(!enabled(&open.connection).unwrap());
        assert!(retains_attachments(&open.connection).unwrap());
        let archived: Vec<u8> = open
            .connection
            .query_row("SELECT payload FROM personal_relay_archive", [], |row| {
                row.get(0)
            })
            .unwrap();
        let sealed: Sealed = serde_json::from_slice(&archived).unwrap();
        let raw = unseal(
            &subkey(&open.root, b"personal-relay-v1"),
            &sealed,
            open.header.vault_id.as_bytes(),
        )
        .unwrap();
        let history: State = serde_json::from_slice(&raw).unwrap();
        assert_eq!(history.group, "test");
        assert_eq!(
            history.pending.len() as u64,
            before["pending"].as_u64().unwrap()
        );
    }
}
