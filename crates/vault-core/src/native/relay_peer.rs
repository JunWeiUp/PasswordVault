//! Explicitly enrolled peer libraries; encrypted locally, independent of relay group ACLs.
use super::*;
use crate::peer_sync::{Member, PeerPacket, PeerReplica};
use rusqlite::OptionalExtension;
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Library {
    replica: PeerReplica,
    baseline: Records,
    personal: bool,
    #[serde(default)]
    legacy_branches: Vec<(String, Value)>,
    #[serde(default)]
    hidden_history: BTreeSet<String>,
    #[serde(default)]
    local_attachments: BTreeSet<String>,
}
fn table(conn: &Connection) -> Result<()> {
    storage(conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS peer_libraries(id TEXT PRIMARY KEY,payload BLOB NOT NULL)",
    ))
}
pub(super) fn list(conn: &Connection) -> Result<Vec<String>> {
    let exists: i64 = storage(conn.query_row(
        "SELECT count(*) FROM sqlite_master WHERE name='peer_libraries'",
        [],
        |r| r.get(0),
    ))?;
    if exists == 0 {
        return Ok(vec![]);
    }
    let mut s = storage(conn.prepare("SELECT id FROM peer_libraries ORDER BY id"))?;
    let rows = storage(s.query_map([], |r| r.get(0)))?;
    rows.map(storage).collect()
}
fn load_library(conn: &Connection, root: &[u8; 32], vault: &str, id: &str) -> Result<Library> {
    let data: Vec<u8> = storage(conn.query_row(
        "SELECT payload FROM peer_libraries WHERE id=?1",
        [id],
        |r| r.get(0),
    ))?;
    let envelope: Sealed = serde_json::from_slice(&data).map_err(|_| VaultError::InvalidData)?;
    let aad = format!("{vault}:{id}");
    serde_json::from_slice(&unseal(
        &subkey(root, b"peer-libraries-v2"),
        &envelope,
        aad.as_bytes(),
    )?)
    .map_err(|_| VaultError::InvalidData)
}
fn save(conn: &Connection, root: &[u8; 32], vault: &str, l: &Library) -> Result<()> {
    let id = &l.replica.library;
    let aad = format!("{vault}:{id}");
    let plain = Zeroizing::new(serde_json::to_vec(l).map_err(|_| VaultError::InvalidData)?);
    let envelope = seal(&subkey(root, b"peer-libraries-v2"), &plain, aad.as_bytes())?;
    storage(conn.execute("INSERT INTO peer_libraries(id,payload) VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",rusqlite::params![id,serde_json::to_vec(&envelope).map_err(|_|VaultError::InvalidData)?]))?;
    Ok(())
}
fn selected(doc: &Document, l: &Library) -> bool {
    match doc.settings["activePeerLibrary"]
        .as_str()
        .filter(|s| !s.is_empty())
    {
        Some(id) => id == l.replica.library && !l.personal,
        None => l.personal,
    }
}
fn save_view(conn: &Connection, root: &[u8; 32], vault: &str, doc: &Document) -> Result<()> {
    // A library switch is navigation, not an edit or a deletion in either history.
    let plain = Zeroizing::new(serde_json::to_vec(doc).map_err(|_| VaultError::InvalidData)?);
    let sealed = seal(&subkey(root, b"document"), &plain, vault.as_bytes())?;
    storage(conn.execute(
        "UPDATE vault_state SET payload=?1 WHERE id=1",
        [serde_json::to_vec(&sealed).map_err(|_| VaultError::InvalidData)?],
    ))?;
    Ok(())
}
fn personal_snapshot(conn: &Connection, root: &[u8; 32], vault: &str) -> Result<Records> {
    let bytes: Vec<u8> = storage(conn.query_row(
        "SELECT payload FROM peer_personal_snapshot WHERE id=1",
        [],
        |r| r.get(0),
    ))?;
    let sealed: Sealed = serde_json::from_slice(&bytes).map_err(|_| VaultError::InvalidData)?;
    serde_json::from_slice(&unseal(
        &subkey(root, b"peer-personal-snapshot-v2"),
        &sealed,
        vault.as_bytes(),
    )?)
    .map_err(|_| VaultError::InvalidData)
}
fn store_personal(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    records: &Records,
) -> Result<()> {
    storage(conn.execute_batch("CREATE TABLE IF NOT EXISTS peer_personal_snapshot(id INTEGER PRIMARY KEY CHECK(id=1),payload BLOB NOT NULL)"))?;
    let plain = Zeroizing::new(serde_json::to_vec(records).map_err(|_| VaultError::InvalidData)?);
    let sealed = seal(
        &subkey(root, b"peer-personal-snapshot-v2"),
        &plain,
        vault.as_bytes(),
    )?;
    storage(conn.execute("INSERT INTO peer_personal_snapshot(id,payload) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",[serde_json::to_vec(&sealed).map_err(|_|VaultError::InvalidData)?]))?;
    Ok(())
}
fn selected_library(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    doc: &Document,
) -> Result<Option<Library>> {
    for id in list(conn)? {
        let l = load_library(conn, root, vault, &id)?;
        if selected(doc, &l) && !l.replica.controls.is_empty() {
            return Ok(Some(l));
        }
    }
    Ok(None)
}
pub(in crate::native) fn editable_document(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    doc: &Document,
) -> Result<Document> {
    let mut result = doc.clone();
    result.settings["_peerLibraryName"] = json!("");
    let active = doc.settings["activePeerLibrary"]
        .as_str()
        .is_some_and(|s| !s.is_empty());
    result.settings["_peerLibraryRole"] = json!(if active { "blocked" } else { "admin" });
    result.settings["_peerLibraryReadOnly"] = json!(active);
    if let Some(l) = selected_library(conn, root, vault, doc)? {
        let role = l
            .replica
            .members()
            .ok()
            .and_then(|m| m.get(&l.replica.device))
            .map(|m| &m.role);
        result.settings["_peerLibraryRole"] =
            serde_json::to_value(role).map_err(|_| VaultError::InvalidData)?;
        result.settings["_peerLibraryReadOnly"] = json!(
            l.replica.frozen
                || !l.replica.has_local_access()
                || !matches!(
                    role,
                    Some(
                        crate::peer_sync::LibraryRole::Admin
                            | crate::peer_sync::LibraryRole::Editor
                    )
                )
        );
        if !l.personal {
            result.settings["_peerLibraryName"] = json!(l
                .replica
                .resolved()
                .get("library-name")
                .and_then(Value::as_str)
                .unwrap_or("Family library"));
        }
        for item in &mut result.items {
            let key = format!("item:{}", item["id"].as_str().unwrap_or(""));
            item["_peerBaseHeads"] = json!(l
                .replica
                .heads(&key)
                .iter()
                .map(|o| &o.id)
                .collect::<Vec<_>>());
            item["_peerLibrary"] = json!(l.replica.library);
        }
    }
    Ok(result)
}
pub(in crate::native) fn prepare_save(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    doc: &Document,
    item: &Value,
) -> Result<Value> {
    let mut item = item.clone();
    if let Some(l) = selected_library(conn, root, vault, doc)? {
        let key = format!(
            "item:{}",
            item["id"].as_str().ok_or(VaultError::InvalidData)?
        );
        if item
            .get("_peerLibrary")
            .is_some_and(|id| id.as_str() != Some(l.replica.library.as_str()))
            || !l
                .replica
                .edit_base_matches(&key, item.get("_peerBaseHeads"))
        {
            return Err(VaultError::StaleEdit);
        }
    } else if item.get("_peerLibrary").is_some() {
        return Err(VaultError::StaleEdit);
    }
    let fields = item.as_object_mut().ok_or(VaultError::InvalidData)?;
    fields.remove("_peerBaseHeads");
    fields.remove("_peerLibrary");
    Ok(item)
}
pub(in crate::native) fn save_result(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    doc: &Document,
    id: &str,
) -> Result<Value> {
    if let Some(l) = selected_library(conn, root, vault, doc)? {
        Ok(
            json!({"ok":true,"peerBaseHeads":l.replica.heads(&format!("item:{id}")).iter().map(|o|&o.id).collect::<Vec<_>>(),"peerLibrary":l.replica.library}),
        )
    } else {
        Ok(json!({"ok":true}))
    }
}
fn committed_attachment_refs(library: &Library) -> Result<std::collections::HashSet<String>> {
    let mut refs = std::collections::HashSet::new();
    for value in library
        .baseline
        .values()
        .chain(library.replica.operations.values().map(|o| &o.value))
    {
        crate::archive::item_attachment_refs(value, &mut refs)?;
    }
    Ok(refs)
}
fn require_attachment_scope(
    value: &Value,
    known: &std::collections::HashSet<String>,
    provided: &BTreeSet<String>,
) -> Result<()> {
    let mut refs = std::collections::HashSet::new();
    crate::archive::item_attachment_refs(value, &mut refs)?;
    if refs
        .iter()
        .any(|id| !known.contains(id) && !provided.contains(id))
    {
        return Err(VaultError::Authentication);
    }
    Ok(())
}
pub(in crate::native) fn register_local_attachment(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    doc: &Document,
    id: &str,
) -> Result<()> {
    if let Some(mut library) = selected_library(conn, root, vault, doc)? {
        library.replica.require_write_access()?;
        library.local_attachments.insert(id.into());
        save(conn, root, vault, &library)?;
    }
    Ok(())
}
pub(in crate::native) fn forget_local_attachment(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    doc: &Document,
    id: &str,
) -> Result<()> {
    if let Some(mut library) = selected_library(conn, root, vault, doc)? {
        library.local_attachments.remove(id);
        save(conn, root, vault, &library)?;
    }
    Ok(())
}
pub(in crate::native) fn readable_documents(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    doc: &Document,
) -> Result<Vec<(String, Document)>> {
    let mut personal = doc.clone();
    if doc.settings["activePeerLibrary"]
        .as_str()
        .is_some_and(|s| !s.is_empty())
    {
        install(&mut personal, &personal_snapshot(conn, root, vault)?)?;
    }
    personal.settings["activePeerLibrary"] = json!("");
    let mut result = vec![(String::new(), personal)];
    for id in list(conn)? {
        let l = load_library(conn, root, vault, &id)?;
        if l.personal
            || l.replica.frozen
            || !l
                .replica
                .members()
                .is_ok_and(|m| m.contains_key(&l.replica.device))
        {
            continue;
        }
        let mut document = doc.clone();
        let mut values = l.baseline;
        values.extend(l.replica.resolved());
        install(&mut document, &values)?;
        document.settings["activePeerLibrary"] = json!(id);
        result.push((id, document));
    }
    Ok(result)
}
pub(in crate::native) fn with_library_records(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    doc: &Document,
) -> Result<Document> {
    let mut result = doc.clone();
    if doc.settings["activePeerLibrary"]
        .as_str()
        .is_some_and(|s| !s.is_empty())
    {
        result.items.extend(
            personal_snapshot(conn, root, vault)?
                .into_iter()
                .filter(|(k, v)| k.starts_with("item:") && !v.is_null())
                .map(|(_, v)| v),
        );
    }
    for id in list(conn)? {
        let l = load_library(conn, root, vault, &id)?;
        result.items.extend(
            l.baseline
                .into_iter()
                .filter(|(k, v)| k.starts_with("item:") && !v.is_null())
                .map(|(_, v)| v),
        );
        result.items.extend(
            l.replica
                .operations
                .values()
                .filter(|o| o.key.starts_with("item:") && !o.value.is_null())
                .map(|o| o.value.clone()),
        );
    }
    Ok(result)
}
pub(in crate::native) fn backup_document(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    doc: &Document,
) -> Result<Document> {
    let mut result = doc.clone();
    if doc.settings["activePeerLibrary"]
        .as_str()
        .is_some_and(|s| !s.is_empty())
    {
        install(&mut result, &personal_snapshot(conn, root, vault)?)?;
    }
    result
        .settings
        .as_object_mut()
        .ok_or(VaultError::InvalidData)?
        .remove("activePeerLibrary");
    let mut snapshots = Vec::new();
    for id in list(conn)? {
        let l = load_library(conn, root, vault, &id)?;
        if l.personal || l.replica.controls.is_empty() {
            continue;
        }
        let packet = PeerPacket {
            version: 2,
            library: l.replica.library.clone(),
            controls: l.replica.controls.clone(),
            operations: l.replica.operations.values().cloned().collect(),
        };
        snapshots.push(json!({"packet":packet,"records":l.baseline}));
    }
    if !snapshots.is_empty() {
        result.settings["peerLibrarySnapshots"] = json!(snapshots);
    }
    Ok(result)
}
pub(in crate::native) fn restore_snapshots(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    snapshots: &Value,
) -> Result<()> {
    if snapshots.is_null() {
        return Ok(());
    }
    let snapshots = snapshots.as_array().ok_or(VaultError::InvalidData)?;
    if snapshots.len() > 256 {
        return Err(VaultError::InvalidData);
    }
    table(conn)?;
    for snapshot in snapshots {
        let packet: PeerPacket = serde_json::from_value(snapshot["packet"].clone())
            .map_err(|_| VaultError::InvalidData)?;
        let replica = PeerReplica::recover_copy(&packet, format!("recovered-{}", new_id()))?;
        let baseline: Records = serde_json::from_value(snapshot["records"].clone())
            .map_err(|_| VaultError::InvalidData)?;
        let mut test = Document::default();
        install(&mut test, &baseline)?;
        let l = Library {
            replica,
            baseline,
            personal: false,
            legacy_branches: vec![],
            hidden_history: BTreeSet::new(),
            local_attachments: BTreeSet::new(),
        };
        save(conn, root, vault, &l)?;
    }
    Ok(())
}
pub(super) fn capture(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    doc: &Document,
) -> Result<()> {
    for id in list(conn)? {
        let mut l = load_library(conn, root, vault, &id)?;
        if !selected(doc, &l) || l.replica.controls.is_empty() {
            continue;
        }
        let now = records(doc);
        let known = committed_attachment_refs(&l)?;
        let keys: BTreeSet<_> = now.keys().chain(l.baseline.keys()).cloned().collect();
        for k in keys {
            if k != "categories" && !k.starts_with("item:") {
                continue;
            }
            let value = now.get(&k).cloned().unwrap_or(Value::Null);
            if l.baseline.get(&k).unwrap_or(&Value::Null) != &value {
                require_attachment_scope(&value, &known, &l.local_attachments)?;
                l.replica.write(k, value)?;
            }
        }
        l.baseline = now;
        save(conn, root, vault, &l)?;
    }
    Ok(())
}
fn receive_chunk(session: &mut DiskVault, request: &Value) -> Result<Value> {
    let sender = string(request, "sender")?;
    let envelope = &request["envelope"];
    let open = session.open()?;
    let root = open.root.clone();
    let vault = open.header.vault_id.clone();
    storage(open.connection.execute_batch("CREATE TABLE IF NOT EXISTS peer_chunks(id INTEGER PRIMARY KEY CHECK(id=1),payload BLOB NOT NULL)"))?;
    let payload: Option<Vec<u8>> = storage(
        open.connection
            .query_row("SELECT payload FROM peer_chunks WHERE id=1", [], |r| {
                r.get(0)
            })
            .optional(),
    )?;
    let mut chunks: crate::peer_sync::ChunkAssembler = if let Some(payload) = payload {
        let sealed: Sealed =
            serde_json::from_slice(&payload).map_err(|_| VaultError::InvalidData)?;
        serde_json::from_slice(&unseal(
            &subkey(&root, b"peer-chunks-v2"),
            &sealed,
            vault.as_bytes(),
        )?)
        .map_err(|_| VaultError::InvalidData)?
    } else {
        Default::default()
    };
    let complete = chunks.ingest(sender, envelope)?;
    let write = |conn: &Connection, chunks: &crate::peer_sync::ChunkAssembler| -> Result<()> {
        let plain =
            Zeroizing::new(serde_json::to_vec(chunks).map_err(|_| VaultError::InvalidData)?);
        let sealed = seal(&subkey(&root, b"peer-chunks-v2"), &plain, vault.as_bytes())?;
        storage(conn.execute("INSERT INTO peer_chunks(id,payload) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",[serde_json::to_vec(&sealed).map_err(|_|VaultError::InvalidData)?]))?;
        Ok(())
    };
    write(&open.connection, &chunks)?;
    if let Some(complete) = complete {
        let mut next = request.clone();
        next["envelope"] = complete;
        let result = command(session, &next)?;
        chunks.forget(sender, string(envelope, "transfer")?);
        write(&session.open()?.connection, &chunks)?;
        Ok(result)
    } else {
        Ok(json!({"ok":true,"partial":true}))
    }
}
impl DiskVault {
    /// Mutate the personal source atomically without changing the visible family.
    pub(in crate::native) fn mutate_personal_passkey(
        &mut self,
        operation: impl FnOnce(&mut Document) -> Result<Value>,
    ) -> Result<Value> {
        let open = self.open()?;
        if open.document.settings["activePeerLibrary"]
            .as_str()
            .is_none_or(|id| id.is_empty())
        {
            return self.mutate(operation);
        }
        let mut before = open.document.clone();
        install(
            &mut before,
            &personal_snapshot(&open.connection, &open.root, &open.header.vault_id)?,
        )?;
        before.settings["activePeerLibrary"] = json!("");
        let mut next = before.clone();
        let result = operation(&mut next)?;
        let tx = storage(open.connection.transaction())?;
        // History must compare against the personal source, not the visible family.
        save_view(&tx, &open.root, &open.header.vault_id, &before)?;
        save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
        store_personal(&tx, &open.root, &open.header.vault_id, &records(&next))?;
        let mut visible = open.document.clone();
        visible.format_version = visible.format_version.max(next.format_version);
        save_view(&tx, &open.root, &open.header.vault_id, &visible)?;
        storage(tx.commit())?;
        open.document = visible;
        Ok(result)
    }
}
pub(super) fn command(session: &mut DiskVault, request: &Value) -> Result<Value> {
    let op = string(request, "op")?;
    guard_device_sync(session.open()?.document.format_version, op)?;
    if ["relay-peer-join", "relay-peer-receive"].contains(&op)
        && request["envelope"]["protocol"] == "peer-v2-chunk"
    {
        return receive_chunk(session, request);
    }
    let open = session.open()?;
    if op == "relay-peer-list" {
        let mut libraries = Vec::new();
        for id in list(&open.connection)? {
            let l = load_library(&open.connection, &open.root, &open.header.vault_id, &id)?;
            libraries.push(json!({"id":id,"personal":l.personal,"name":l.replica.resolved().get("library-name").and_then(Value::as_str).map(|s|json!(s)).unwrap_or(json!(id)),"role":l.replica.members().ok().and_then(|m|m.get(&l.replica.device)).map(|m|&m.role)}));
        }
        return Ok(
            json!({"libraries":libraries,"active":open.document.settings["activePeerLibrary"]}),
        );
    }
    if op == "relay-peer-switch" {
        let target = string(request, "library")?;
        let active = open.document.settings["activePeerLibrary"]
            .as_str()
            .unwrap_or("");
        if active == target {
            return Ok(json!({"ok":true}));
        }
        let mut next = open.document.clone();
        let destination = if target.is_empty() {
            personal_snapshot(&open.connection, &open.root, &open.header.vault_id)?
        } else {
            let l = load_library(&open.connection, &open.root, &open.header.vault_id, target)?;
            if l.personal || l.replica.controls.is_empty() {
                return Err(VaultError::InvalidData);
            }
            let mut records = l.baseline.clone();
            records.extend(l.replica.resolved());
            records
        };
        let tx = storage(open.connection.transaction())?;
        capture(&tx, &open.root, &open.header.vault_id, &open.document)?;
        if active.is_empty() {
            store_personal(
                &tx,
                &open.root,
                &open.header.vault_id,
                &records(&open.document),
            )?;
        }
        install(&mut next, &destination)?;
        next.format_version = next.format_version.max(6);
        next.settings["activePeerLibrary"] = json!(target);
        validate_files(&tx, &next)?;
        for id in list(&tx)? {
            let mut library = load_library(&tx, &open.root, &open.header.vault_id, &id)?;
            if selected(&next, &library) && !library.replica.controls.is_empty() {
                library.baseline = records(&next);
                save(&tx, &open.root, &open.header.vault_id, &library)?;
            }
        }
        save_view(&tx, &open.root, &open.header.vault_id, &next)?;
        storage(tx.commit())?;
        open.document = next;
        return Ok(json!({"ok":true}));
    }
    if op == "relay-peer-create" || op == "relay-peer-identity" {
        let device = string(request, "device")?.to_owned();
        let personal = request["personal"].as_bool().unwrap_or(false);
        if op == "relay-peer-identity" && personal && request["confirmPersonalSync"] != true {
            return Err(VaultError::Authentication);
        }
        if personal
            && list(&open.connection)?.iter().any(|id| {
                load_library(&open.connection, &open.root, &open.header.vault_id, id)
                    .is_ok_and(|l| l.personal)
            })
        {
            return Err(VaultError::AlreadyExists);
        }
        let mut replica = if op == "relay-peer-create" {
            PeerReplica::create(device)?
        } else {
            PeerReplica::identity(device)?
        };
        if op == "relay-peer-create" {
            if let Some(key) = request["transportKey"].as_str() {
                replica.authorize(
                    replica.device.clone(),
                    Some(Member {
                        public_key: replica.public_key(),
                        transport_key: key.into(),
                        role: crate::peer_sync::LibraryRole::Admin,
                    }),
                )?;
            }
        }
        // Identity waiting for an invitation has a local staging ID, never an implicit trust anchor.
        if replica.library.is_empty() {
            replica.library = format!("pending-{}", new_id());
        }
        let baseline = if personal
            && open.document.settings["activePeerLibrary"]
                .as_str()
                .is_some_and(|s| !s.is_empty())
        {
            personal_snapshot(&open.connection, &open.root, &open.header.vault_id)?
        } else if personal {
            records(&open.document)
        } else {
            Records::new()
        };
        if !replica.controls.is_empty() {
            replica.write("library-scope".into(), json!(personal))?;
            for (k, v) in &baseline {
                replica.write(k.clone(), v.clone())?;
            }
        }
        let out = json!({"library":replica.library,"device":replica.device,"publicKey":replica.public_key()});
        if !personal && !replica.controls.is_empty() {
            let name = request["name"].as_str().unwrap_or("Family library");
            if name.trim().is_empty() || name.len() > 128 {
                return Err(VaultError::InvalidData);
            }
            replica.write("library-name".into(), json!(name))?;
        }
        let mut legacy_branches = Vec::new();
        if personal && enabled(&open.connection)? {
            let legacy = super::load(&open.connection, &open.root, &open.header.vault_id)?;
            for (key, value) in legacy
                .canonical
                .iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .chain(
                    legacy
                        .pending
                        .values()
                        .map(|c| (c.key.clone(), c.value.clone())),
                )
                .chain(
                    legacy
                        .conflicts
                        .values()
                        .map(|c| (c.change.key.clone(), c.change.value.clone())),
                )
            {
                if baseline.get(&key) != Some(&value)
                    && !legacy_branches.contains(&(key.clone(), value.clone()))
                {
                    legacy_branches.push((key, value));
                }
            }
        }
        if !replica.controls.is_empty() {
            for (key, value) in &legacy_branches {
                replica.import_local(key.clone(), value.clone())?;
            }
            legacy_branches.clear();
        }
        let l = Library {
            replica,
            baseline,
            personal,
            legacy_branches,
            hidden_history: BTreeSet::new(),
            local_attachments: BTreeSet::new(),
        };
        let mut next = open.document.clone();
        next.format_version = next.format_version.max(6);
        let tx = storage(open.connection.transaction())?;
        table(&tx)?;
        if personal && op == "relay-peer-create" && enabled(&tx)? {
            if request["migrateLegacy"].as_bool() != Some(true) {
                return Err(VaultError::InvalidData);
            }
            // Preserve ALL previous pending changes and conflicts before explicit protocol conversion.
            storage(tx.execute_batch("CREATE TABLE IF NOT EXISTS personal_relay_archive(id INTEGER PRIMARY KEY,payload BLOB NOT NULL); INSERT INTO personal_relay_archive(payload) SELECT payload FROM personal_relay; DROP TABLE personal_relay;"))?;
        }
        save(&tx, &open.root, &open.header.vault_id, &l)?;
        save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
        storage(tx.commit())?;
        open.document = next;
        return Ok(out);
    }
    let id = string(request, "library")?;
    let mut l = load_library(&open.connection, &open.root, &open.header.vault_id, id)?;
    if op == "relay-peer-cancel-join" {
        if !l.replica.controls.is_empty() {
            return Err(VaultError::Authentication);
        }
        storage(
            open.connection
                .execute("DELETE FROM peer_libraries WHERE id=?1", [id]),
        )?;
        return Ok(json!({"ok":true}));
    }
    if op == "relay-peer-status" {
        return Ok(
            json!({"library":l.replica.library,"device":l.replica.device,"publicKey":l.replica.public_key(),"personal":l.personal,"generation":l.replica.generation(),"frozen":l.replica.frozen,"members":l.replica.members().ok(),"conflicts":l.replica.conflicts(),"records":l.replica.resolved(),"history":l.replica.operations}),
        );
    }
    if op == "relay-peer-history-status" || op == "relay-peer-history-enable" {
        return Ok(json!({"enabled":true,"ok":true}));
    }
    if op == "relay-peer-history-list" {
        let key = format!("item:{}", string(request, "id")?);
        let mut revisions: Vec<_> = l
            .replica
            .operations
            .values()
            .filter(|o| o.key == key && !l.hidden_history.contains(&o.id))
            .map(|o| history::Revision {
                id: o.id.clone(),
                item_id: string(request, "id").unwrap().into(),
                captured_at: o.captured_at,
                item: o.value.clone(),
            })
            .collect();
        revisions.sort_by(|a, b| b.captured_at.cmp(&a.captured_at).then(b.id.cmp(&a.id)));
        let total = revisions.len();
        let offset = request["offset"].as_u64().unwrap_or(0) as usize;
        let limit = request["limit"].as_u64().unwrap_or(100).clamp(1, 500) as usize;
        return Ok(
            json!({"total":total,"revisions":revisions.into_iter().skip(offset).take(limit).collect::<Vec<_>>() }),
        );
    }
    if op == "relay-peer-export" {
        let packet = l.replica.export(string(request, "peer")?)?;
        let changes: Vec<_> = packet
            .operations
            .iter()
            .map(|o| json!({"value":o.value}))
            .collect();
        return Ok(
            json!({"protocol":"peer-v2","packet":packet,"files":attachments(open,&json!({"changes":changes}))?}),
        );
    }
    let mut next = open.document.clone();
    let tx = storage(open.connection.transaction())?;
    match op {
        "relay-peer-rekey" => {
            if l.replica.members()?.get(&l.replica.device).map(|m| &m.role)
                != Some(&crate::peer_sync::LibraryRole::Admin)
            {
                return Err(VaultError::Authentication);
            }
            let packet = PeerPacket {
                version: 2,
                library: l.replica.library.clone(),
                controls: l.replica.controls.clone(),
                operations: l.replica.operations.values().cloned().collect(),
            };
            let mut replica =
                PeerReplica::recover_copy(&packet, string(request, "device")?.into())?;
            replica.authorize(
                replica.device.clone(),
                Some(Member {
                    public_key: replica.public_key(),
                    transport_key: string(request, "transportKey")?.into(),
                    role: crate::peer_sync::LibraryRole::Admin,
                }),
            )?;
            if next.settings["activePeerLibrary"] == id {
                next.settings["activePeerLibrary"] = json!(replica.library);
            }
            l.replica = replica;
            l.hidden_history.clear();
        }
        "relay-peer-authorize" => {
            let member = if request["member"].is_null() {
                None
            } else {
                Some(
                    serde_json::from_value::<Member>(request["member"].clone())
                        .map_err(|_| VaultError::InvalidData)?,
                )
            };
            l.replica
                .authorize(string(request, "peer")?.into(), member)?;
        }
        "relay-peer-join" | "relay-peer-receive" => {
            let incoming = &request["envelope"];
            let packet: PeerPacket = serde_json::from_value(incoming["packet"].clone())
                .map_err(|_| VaultError::InvalidData)?;
            let known = committed_attachment_refs(&l)?;
            let provided: BTreeSet<String> = incoming["files"]
                .as_array()
                .ok_or(VaultError::InvalidData)?
                .iter()
                .map(|file| string(&file["meta"], "id").map(str::to_owned))
                .collect::<Result<_>>()?;
            for operation in &packet.operations {
                require_attachment_scope(&operation.value, &known, &provided)?;
            }
            if op == "relay-peer-join" {
                l.replica.join(
                    &packet,
                    string(request, "expectedLibrary")?,
                    string(request, "founderKey")?,
                )?;
                if l.replica.scope()? != Some(l.personal) {
                    return Err(VaultError::Authentication);
                }
                if l.personal && enabled(&tx)? {
                    let legacy = super::load(&tx, &open.root, &open.header.vault_id)?;
                    for (key, value) in legacy
                        .canonical
                        .into_iter()
                        .chain(
                            legacy
                                .pending
                                .values()
                                .map(|c| (c.key.clone(), c.value.clone())),
                        )
                        .chain(
                            legacy
                                .conflicts
                                .values()
                                .map(|c| (c.change.key.clone(), c.change.value.clone())),
                        )
                    {
                        if !l
                            .replica
                            .operations
                            .values()
                            .any(|o| o.key == key && o.value == value)
                        {
                            l.replica.import_local(key, value)?;
                        }
                    }
                    storage(tx.execute_batch("CREATE TABLE IF NOT EXISTS personal_relay_archive(id INTEGER PRIMARY KEY,payload BLOB NOT NULL); INSERT INTO personal_relay_archive(payload) SELECT payload FROM personal_relay; DROP TABLE personal_relay;"))?;
                }
                for (key, value) in std::mem::take(&mut l.legacy_branches) {
                    l.replica.import_local(key, value)?;
                }
                if l.personal {
                    let incoming = l.replica.resolved();
                    let local = if next.settings["activePeerLibrary"]
                        .as_str()
                        .is_some_and(|s| !s.is_empty())
                    {
                        personal_snapshot(&tx, &open.root, &open.header.vault_id)?
                    } else {
                        records(&next)
                    };
                    for (key, value) in local {
                        if incoming.get(&key) != Some(&value) {
                            l.replica.import_local(key, value)?;
                        }
                    }
                }
            } else if let Err(err) = l.replica.receive(&packet) {
                if l.replica.frozen {
                    save(&tx, &open.root, &open.header.vault_id, &l)?;
                    storage(tx.commit())?;
                }
                return Err(err);
            }
            receive_files(&tx, &open.root, &open.header.vault_id, &incoming["files"])?;
        }
        "relay-peer-history-prune" => {
            let key = format!("item:{}", string(request, "id")?);
            let heads: BTreeSet<_> = l.replica.heads(&key).iter().map(|o| o.id.clone()).collect();
            for operation in l.replica.operations.values().filter(|o| o.key == key) {
                if !heads.contains(&operation.id) {
                    l.hidden_history.insert(operation.id.clone());
                }
            }
            save(&tx, &open.root, &open.header.vault_id, &l)?;
            storage(tx.commit())?;
            return Ok(json!({"ok":true,"retainedForSync":true}));
        }
        "relay-peer-history-restore" => {
            let item_id = string(request, "id")?;
            let key = format!("item:{item_id}");
            let operation = l
                .replica
                .operations
                .get(string(request, "revisionId")?)
                .ok_or(VaultError::InvalidData)?;
            if operation.key != key || operation.value.is_null() {
                return Err(VaultError::InvalidData);
            }
            let mut value = operation.value.clone();
            let time = string(request, "time")?;
            chrono::DateTime::parse_from_rfc3339(time).map_err(|_| VaultError::InvalidData)?;
            value["updatedAt"] = json!(time);
            l.replica.write(key, value)?;
        }
        "relay-peer-write" | "relay-peer-resolve" => {
            let key = string(request, "key")?;
            let value = request.get("value").ok_or(VaultError::InvalidData)?.clone();
            if op == "relay-peer-resolve" && l.replica.heads(key).len() < 2 {
                return Err(VaultError::InvalidData);
            }
            require_attachment_scope(
                &value,
                &committed_attachment_refs(&l)?,
                &l.local_attachments,
            )?;
            l.replica.write(key.into(), value)?;
        }
        _ => return Err(VaultError::Unsupported),
    }
    if l.personal {
        next.format_version = next.format_version.max(6);
        next.settings["entryHistoryEnabled"] = json!(true);
        history::table(&tx)?;
        for operation in l.replica.operations.values() {
            if let Some(item_id) = operation.key.strip_prefix("item:") {
                history::write(
                    &tx,
                    &open.root,
                    &open.header.vault_id,
                    &history::Revision {
                        id: operation.id.clone(),
                        item_id: item_id.into(),
                        captured_at: operation.captured_at,
                        item: operation.value.clone(),
                    },
                )?;
            }
        }
    }
    let is_selected = selected(&next, &l);
    let mut values = if is_selected {
        records(&next)
    } else {
        l.baseline.clone()
    };
    values.extend(l.replica.resolved());
    l.baseline = values.clone();
    if is_selected {
        install(&mut next, &values)?;
        l.baseline = records(&next);
        validate_files(&tx, &next)?;
    } else if l.personal {
        store_personal(&tx, &open.root, &open.header.vault_id, &values)?;
    }
    if id != l.replica.library {
        storage(tx.execute("DELETE FROM peer_libraries WHERE id=?1", [id]))?;
    }
    save(&tx, &open.root, &open.header.vault_id, &l)?;
    if is_selected {
        save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
    }
    storage(tx.commit())?;
    open.document = next;
    Ok(
        json!({"ok":true,"library":l.replica.library,"generation":l.replica.generation(),"publicKey":l.replica.public_key(),"device":l.replica.device,"personal":l.personal}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_peer_capture_conflict_and_restart() {
        let da = tempfile::tempdir().unwrap();
        let db = tempfile::tempdir().unwrap();
        let mut a = DiskVault::new(da.path()).unwrap();
        let mut b = DiskVault::new(db.path()).unwrap();
        a.create("a-fixture").unwrap();
        b.create("b-fixture").unwrap();
        let ai = command(
            &mut a,
            &json!({"op":"relay-peer-create","device":"phone-a","personal":true}),
        )
        .unwrap();
        let bi = command(
            &mut b,
            &json!({"op":"relay-peer-identity","device":"phone-b","personal":true,"confirmPersonalSync":true}),
        )
        .unwrap();
        let lib = ai["library"].as_str().unwrap();
        command(&mut a,&json!({"op":"relay-peer-authorize","library":lib,"peer":"phone-b","member":{"publicKey":bi["publicKey"],"role":"editor"}})).unwrap();
        let envelope = command(
            &mut a,
            &json!({"op":"relay-peer-export","library":lib,"peer":"phone-b"}),
        )
        .unwrap();
        command(&mut b,&json!({"op":"relay-peer-join","library":bi["library"],"expectedLibrary":lib,"founderKey":ai["publicKey"],"envelope":envelope})).unwrap();
        a.command(&json!({"op":"save","item":{"id":"example","type":"password","title":"A"}}))
            .unwrap();
        let old_draft = a.command(&json!({"op":"list"})).unwrap()["items"][0].clone();
        let sealed_draft = a
            .command(&json!({"op":"seal-drafts","items":[old_draft]}))
            .unwrap();
        b.command(&json!({"op":"save","item":{"id":"example","type":"password","title":"B"}}))
            .unwrap();
        let envelope = command(
            &mut a,
            &json!({"op":"relay-peer-export","library":lib,"peer":"phone-b"}),
        )
        .unwrap();
        command(
            &mut b,
            &json!({"op":"relay-peer-receive","library":lib,"envelope":envelope}),
        )
        .unwrap();
        let status = command(&mut b, &json!({"op":"relay-peer-status","library":lib})).unwrap();
        assert_eq!(
            status["conflicts"]["item:example"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        command(&mut b,&json!({"op":"relay-peer-resolve","library":lib,"key":"item:example","value":{"id":"example","type":"password","title":"chosen"}})).unwrap();
        let envelope = command(
            &mut b,
            &json!({"op":"relay-peer-export","library":lib,"peer":"phone-a"}),
        )
        .unwrap();
        command(
            &mut a,
            &json!({"op":"relay-peer-receive","library":lib,"envelope":envelope}),
        )
        .unwrap();
        a.lock();
        a.unlock("a-fixture").unwrap();
        assert_eq!(a.open().unwrap().document.items[0]["title"], "chosen");
        let restoration = a.command(
            &json!({"op":"restore-drafts","payload":sealed_draft["payload"],"richNotes":true}),
        );
        assert!(
            matches!(restoration, Err(VaultError::StaleEdit)),
            "{restoration:?}"
        );
        assert_eq!(a.open().unwrap().document.items[0]["title"], "chosen");
        assert!(a.open().unwrap().document.items[0]
            .get("_peerBaseHeads")
            .is_none());
    }
    #[test]
    fn personal_mutation_failure_preserves_family_and_disk() {
        let d = tempfile::tempdir().unwrap();
        let mut vault = DiskVault::new(d.path()).unwrap();
        vault.create("synthetic-local-test").unwrap();
        let family = command(
            &mut vault,
            &json!({"op":"relay-peer-create","device":"phone","personal":false,"name":"Family"}),
        )
        .unwrap()["library"]
            .clone();
        command(
            &mut vault,
            &json!({"op":"relay-peer-switch","library":family}),
        )
        .unwrap();
        let before = serde_json::to_value(&vault.open().unwrap().document).unwrap();
        let failure = vault.mutate_personal_passkey(|doc| {
            doc.items.push(json!({"id":"must-not-persist"}));
            Err(VaultError::Authentication)
        });
        assert!(matches!(failure, Err(VaultError::Authentication)));
        assert_eq!(
            serde_json::to_value(&vault.open().unwrap().document).unwrap(),
            before
        );
        vault.lock();
        vault.unlock("synthetic-local-test").unwrap();
        assert_eq!(
            serde_json::to_value(&vault.open().unwrap().document).unwrap(),
            before
        );
        command(&mut vault, &json!({"op":"relay-peer-switch","library":""})).unwrap();
        assert!(vault.open().unwrap().document.items.is_empty());
    }
    #[test]
    fn migration_requires_explicit_consent_and_archives_legacy() {
        let d = tempfile::tempdir().unwrap();
        let mut a = DiskVault::new(d.path()).unwrap();
        a.create("fixture").unwrap();
        a.relay_command(
            &json!({"op":"relay-init","role":"mobile","group":"g","device":"phone","hub":"mac"}),
        )
        .unwrap();
        assert!(command(
            &mut a,
            &json!({"op":"relay-peer-create","device":"phone","personal":true})
        )
        .is_err());
        assert!(enabled(&a.open().unwrap().connection).unwrap());
        command(&mut a,&json!({"op":"relay-peer-create","device":"phone","personal":true,"migrateLegacy":true})).unwrap();
        assert!(!enabled(&a.open().unwrap().connection).unwrap());
        let count: i64 = a
            .open()
            .unwrap()
            .connection
            .query_row("SELECT count(*) FROM personal_relay_archive", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(count, 1);
    }
    #[test]
    fn family_switch_keeps_personal_data_history_and_backup_separate() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = DiskVault::new(dir.path()).unwrap();
        vault.create("fixture-password").unwrap();
        vault
            .command(&json!({"op":"save","item":{"id":"same","type":"password","title":"Private"}}))
            .unwrap();
        vault
            .history_command(&json!({"op":"history-enable"}))
            .unwrap();
        let family = command(
            &mut vault,
            &json!({"op":"relay-peer-create","device":"phone","personal":false,"name":"Family"}),
        )
        .unwrap()["library"]
            .as_str()
            .unwrap()
            .to_owned();
        command(
            &mut vault,
            &json!({"op":"relay-peer-switch","library":family}),
        )
        .unwrap();
        assert!(vault.open().unwrap().document.items.is_empty());
        vault
            .command(&json!({"op":"save","item":{"id":"same","type":"password","title":"Shared"}}))
            .unwrap();
        let history = vault
            .history_command(&json!({"op":"history-list","id":"same"}))
            .unwrap();
        assert_eq!(history["revisions"][0]["item"]["title"], "Shared");
        assert_eq!(history["total"], 1);
        {
            let open = vault.open().unwrap();
            let documents = readable_documents(
                &open.connection,
                &open.root,
                &open.header.vault_id,
                &open.document,
            )
            .unwrap();
            assert_eq!(documents.len(), 2);
            assert_eq!(documents[0].0, "");
            assert_eq!(documents[0].1.items[0]["title"], "Private");
            assert_eq!(documents[1].1.items[0]["title"], "Shared");
            let library =
                load_library(&open.connection, &open.root, &open.header.vault_id, &family).unwrap();
            let mut frozen = library.clone();
            frozen.replica.frozen = true;
            save(&open.connection, &open.root, &open.header.vault_id, &frozen).unwrap();
            assert_eq!(
                readable_documents(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &open.document
                )
                .unwrap()
                .len(),
                1
            );
            let mut removed = library.clone();
            removed
                .replica
                .authorize(
                    "other-admin".into(),
                    Some(Member {
                        public_key: hex::encode([7; 32]),
                        transport_key: String::new(),
                        role: crate::peer_sync::LibraryRole::Admin,
                    }),
                )
                .unwrap();
            removed.replica.authorize("phone".into(), None).unwrap();
            save(
                &open.connection,
                &open.root,
                &open.header.vault_id,
                &removed,
            )
            .unwrap();
            assert_eq!(
                readable_documents(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &open.document
                )
                .unwrap()
                .len(),
                1
            );
            save(
                &open.connection,
                &open.root,
                &open.header.vault_id,
                &library,
            )
            .unwrap();
        }
        let archive = vault.archive("fixture-backup-password").unwrap();
        command(&mut vault, &json!({"op":"relay-peer-switch","library":""})).unwrap();
        assert_eq!(vault.open().unwrap().document.items[0]["title"], "Private");
        let history = vault
            .history_command(&json!({"op":"history-list","id":"same"}))
            .unwrap();
        assert_eq!(history["revisions"][0]["item"]["title"], "Private");
        let restored_dir = tempfile::tempdir().unwrap();
        let mut restored = DiskVault::new(restored_dir.path()).unwrap();
        restored
            .import_archive(&archive, "fixture-backup-password", Some("new-password"))
            .unwrap();
        assert_eq!(
            restored.open().unwrap().document.items[0]["title"],
            "Private"
        );
        let libraries = command(&mut restored, &json!({"op":"relay-peer-list"})).unwrap();
        let recovered = libraries["libraries"][0]["id"].as_str().unwrap();
        assert_ne!(recovered, family);
        command(
            &mut restored,
            &json!({"op":"relay-peer-switch","library":recovered}),
        )
        .unwrap();
        assert_eq!(
            restored.open().unwrap().document.items[0]["title"],
            "Shared"
        );
        let renewed=command(&mut restored,&json!({"op":"relay-peer-rekey","library":recovered,"device":"replacement-phone","transportKey":"a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209"})).unwrap(); // gitleaks:allow -- synthetic fixture or non-secret expression
        assert_ne!(renewed["library"], recovered);
        assert_eq!(renewed["device"], "replacement-phone");
        assert_eq!(
            restored.open().unwrap().document.items[0]["title"],
            "Shared"
        );
        let status = command(
            &mut restored,
            &json!({"op":"relay-peer-status","library":renewed["library"]}),
        )
        .unwrap();
        assert_eq!(status["members"].as_object().unwrap().len(), 1);
    }
    #[test]
    fn reader_backup_receipt_cannot_confirm_after_library_freezes_or_revokes_access() {
        let a_dir = tempfile::tempdir().unwrap();
        let b_dir = tempfile::tempdir().unwrap();
        let mut a = DiskVault::new(a_dir.path()).unwrap();
        let mut b = DiskVault::new(b_dir.path()).unwrap();
        a.create("owner fixture passphrase").unwrap();
        b.create("reader fixture passphrase").unwrap();
        let owner = command(
            &mut a,
            &json!({"op":"relay-peer-create","device":"owner","personal":false,"name":"Family"}),
        )
        .unwrap();
        let library = owner["library"].as_str().unwrap();
        command(&mut a, &json!({"op":"relay-peer-switch","library":library})).unwrap();
        // Seed an existing shared credential explicitly. Public registration always
        // targets the personal vault, irrespective of the selected family view.
        let (record, response) = crate::passkey_create_system(
            "example.com",
            b"reader-fixture",
            "Reader fixture",
            &[1; 32],
        )
        .unwrap();
        let created = serde_json::to_value(response).unwrap();
        a.mutate(|doc| {
            doc.upsert(json!({"id":"shared-passkey-fixture","type":concat!("pass", "word"),"title":"Shared fixture","passkeys":[serde_json::to_value(&record).unwrap()]}))?;
            Ok(json!({}))
        }).unwrap();
        let identity = command(
            &mut b,
            &json!({"op":"relay-peer-identity","device":"reader","personal":false}),
        )
        .unwrap();
        command(&mut a,&json!({"op":"relay-peer-authorize","library":library,"peer":"reader","member":{"publicKey":identity["publicKey"],"role":"reader"}})).unwrap();
        let envelope = command(
            &mut a,
            &json!({"op":"relay-peer-export","library":library,"peer":"reader"}),
        )
        .unwrap();
        command(&mut b,&json!({"op":"relay-peer-join","library":identity["library"],"expectedLibrary":library,"founderKey":owner["publicKey"],"envelope":envelope})).unwrap();
        command(&mut b, &json!({"op":"relay-peer-switch","library":library})).unwrap();
        let index = b.passkey_command(&json!({"op":"passkey-index"})).unwrap();
        let item_id = index["passkeys"][0]["itemId"].as_str().unwrap();
        let exported=b.passkey_backup_command(&json!({"op":"passkey-backup-export","credentialId":created["id"],"itemId":item_id,"library":library,"currentPassword":"reader fixture passphrase","backupPassword":"separate backup fixture"})).unwrap();
        let archive = crate::archive::decode_archive(
            exported["content"].as_str().unwrap(),
            "separate backup fixture",
        )
        .unwrap();
        assert_eq!(archive.manifest.document.items.len(), 1);
        assert_eq!(
            archive.manifest.document.items[0]["passkeys"][0]["backupState"],
            true
        );
        assert_eq!(
            b.open().unwrap().document.items[0]["passkeys"][0]["backupState"],
            false
        );
        let confirm = json!({"op":"passkey-backup-confirm","credentialId":created["id"],"itemId":item_id,"library":library,"currentPassword":"reader fixture passphrase","receipt":exported["receipt"],"actualArchiveHash":hex::encode(Sha256::digest(exported["content"].as_str().unwrap().as_bytes()))});
        let open = b.open().unwrap();
        let original =
            load_library(&open.connection, &open.root, &open.header.vault_id, library).unwrap();
        let mut frozen = original.clone();
        frozen.replica.frozen = true;
        save(&open.connection, &open.root, &open.header.vault_id, &frozen).unwrap();
        assert!(matches!(
            b.passkey_backup_command(&confirm),
            Err(VaultError::Authentication)
        ));
        let open = b.open().unwrap();
        save(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            &original,
        )
        .unwrap();
        command(
            &mut a,
            &json!({"op":"relay-peer-authorize","library":library,"peer":"reader","member":null}),
        )
        .unwrap();
        // Deliver the valid signed control update explicitly; the removed recipient is
        // intentionally no longer eligible for a normal data export.
        let notice = command(
            &mut a,
            &json!({"op":"relay-peer-export","library":library,"peer":"owner"}),
        )
        .unwrap();
        command(
            &mut b,
            &json!({"op":"relay-peer-receive","library":library,"envelope":notice}),
        )
        .unwrap();
        assert!(matches!(
            b.passkey_backup_command(&confirm),
            Err(VaultError::Authentication)
        ));
    }
    #[test]
    fn family_enrollment_never_merges_personal_records_or_accepts_scope_override() {
        let a_dir = tempfile::tempdir().unwrap();
        let b_dir = tempfile::tempdir().unwrap();
        let mut a = DiskVault::new(a_dir.path()).unwrap();
        let mut b = DiskVault::new(b_dir.path()).unwrap();
        a.create("owner fixture").unwrap();
        b.create("reader fixture").unwrap();
        b.command(&json!({"op":"save","item":{"id":"private","type":"secureNote","title":"PRIVATE_CANARY"}})).unwrap();
        let owner = command(
            &mut a,
            &json!({"op":"relay-peer-create","device":"owner","personal":false}),
        )
        .unwrap();
        let library = owner["library"].as_str().unwrap();
        assert!(command(
            &mut b,
            &json!({"op":"relay-peer-identity","device":"reader","personal":true})
        )
        .is_err());
        let wrong=command(&mut b,&json!({"op":"relay-peer-identity","device":"reader","personal":true,"confirmPersonalSync":true})).unwrap();
        command(&mut a,&json!({"op":"relay-peer-authorize","library":library,"peer":"reader","member":{"publicKey":wrong["publicKey"],"role":"editor"}})).unwrap();
        let envelope = command(
            &mut a,
            &json!({"op":"relay-peer-export","library":library,"peer":"reader"}),
        )
        .unwrap();
        assert!(command(&mut b,&json!({"op":"relay-peer-join","library":wrong["library"],"expectedLibrary":library,"founderKey":owner["publicKey"],"envelope":envelope})).is_err());
        assert_eq!(
            b.open().unwrap().document.items[0]["title"],
            "PRIVATE_CANARY"
        );
        command(
            &mut b,
            &json!({"op":"relay-peer-cancel-join","library":wrong["library"]}),
        )
        .unwrap();
        let right = command(
            &mut b,
            &json!({"op":"relay-peer-identity","device":"reader","personal":false}),
        )
        .unwrap();
        command(&mut a,&json!({"op":"relay-peer-authorize","library":library,"peer":"reader","member":{"publicKey":right["publicKey"],"role":"reader"}})).unwrap();
        let envelope = command(
            &mut a,
            &json!({"op":"relay-peer-export","library":library,"peer":"reader"}),
        )
        .unwrap();
        command(&mut b,&json!({"op":"relay-peer-join","library":right["library"],"expectedLibrary":library,"founderKey":owner["publicKey"],"envelope":envelope})).unwrap();
        let exported = command(
            &mut b,
            &json!({"op":"relay-peer-export","library":library,"peer":"owner"}),
        )
        .unwrap();
        assert!(!exported.to_string().contains("PRIVATE_CANARY"));
        command(&mut b, &json!({"op":"relay-peer-switch","library":library})).unwrap();
        let doc = b.command(&json!({"op":"list"})).unwrap();
        assert_eq!(doc["settings"]["_peerLibraryRole"], "reader");
        assert_eq!(doc["settings"]["_peerLibraryReadOnly"], true);
        assert!(b.command(&json!({"op":"save","item":{"id":"denied","type":"secureNote","title":"Reader cannot write"}})).is_err());
        assert!(b.open().unwrap().document.items.is_empty());
        command(&mut b, &json!({"op":"relay-peer-switch","library":""})).unwrap();
        assert_eq!(
            b.open().unwrap().document.items[0]["title"],
            "PRIVATE_CANARY"
        );
        let other = command(
            &mut b,
            &json!({"op":"relay-peer-create","device":"reader","personal":false}),
        )
        .unwrap();
        command(
            &mut b,
            &json!({"op":"relay-peer-switch","library":other["library"]}),
        )
        .unwrap();
        b.command(&json!({"op":"save","item":{"id":"family-only","type":"secureNote","title":"FAMILY_ONLY_CANARY"}})).unwrap();
        let personal_owner = command(
            &mut a,
            &json!({"op":"relay-peer-create","device":"owner","personal":true}),
        )
        .unwrap();
        let personal_id = personal_owner["library"].as_str().unwrap();
        let personal_join=command(&mut b,&json!({"op":"relay-peer-identity","device":"reader","personal":true,"confirmPersonalSync":true})).unwrap();
        command(&mut a,&json!({"op":"relay-peer-authorize","library":personal_id,"peer":"reader","member":{"publicKey":personal_join["publicKey"],"role":"editor"}})).unwrap();
        let envelope = command(
            &mut a,
            &json!({"op":"relay-peer-export","library":personal_id,"peer":"reader"}),
        )
        .unwrap();
        command(&mut b,&json!({"op":"relay-peer-join","library":personal_join["library"],"expectedLibrary":personal_id,"founderKey":personal_owner["publicKey"],"envelope":envelope})).unwrap();
        let outgoing = command(
            &mut b,
            &json!({"op":"relay-peer-export","library":personal_id,"peer":"owner"}),
        )
        .unwrap()
        .to_string();
        assert!(outgoing.contains("PRIVATE_CANARY"));
        assert!(!outgoing.contains("FAMILY_ONLY_CANARY"));
        assert_eq!(
            b.open().unwrap().document.items[0]["title"],
            "FAMILY_ONLY_CANARY"
        );
    }
    #[test]
    fn incoming_family_cannot_borrow_private_attachment_uuid_without_the_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let mut victim = DiskVault::new(dir.path()).unwrap();
        victim.create("victim fixture").unwrap();
        victim.command(&json!({"op":"save","item":{"id":"collision","type":"secureNote","title":"Private note"}})).unwrap();
        victim.prepare_rich().unwrap();
        let meta = notes::AttachmentMeta {
            id: new_id(),
            note_id: "collision".into(),
            name: "private.txt".into(),
            mime: "text/plain".into(),
            size: 15,
        };
        let secret = b"PRIVATE_CONTENT";
        {
            let open = victim.open().unwrap();
            notes::table(&open.connection).unwrap();
            notes::write(
                &open.connection,
                &open.root,
                &open.header.vault_id,
                &meta,
                secret,
            )
            .unwrap();
        }
        let rich = json!({"id":"collision","type":"secureNote","title":"Private note","noteFormat":"rich-v1","noteDocument":{"type":"doc","content":[{"type":"vaultAttachment","attrs":{"attachmentId":meta.id}}]}});
        victim
            .command(&json!({"op":"save","item":rich,"richNotes":true}))
            .unwrap();
        let identity = command(
            &mut victim,
            &json!({"op":"relay-peer-identity","device":"victim","personal":false}),
        )
        .unwrap();
        let mut attacker = PeerReplica::create("attacker".into()).unwrap();
        attacker
            .write("library-scope".into(), json!(false))
            .unwrap();
        attacker
            .authorize(
                "victim".into(),
                Some(Member {
                    public_key: identity["publicKey"].as_str().unwrap().into(),
                    transport_key: String::new(),
                    role: crate::peer_sync::LibraryRole::Editor,
                }),
            )
            .unwrap();
        let initial = json!({"packet":attacker.export("victim").unwrap(),"files":[]});
        command(&mut victim,&json!({"op":"relay-peer-join","library":identity["library"],"expectedLibrary":attacker.library,"founderKey":attacker.public_key(),"envelope":initial})).unwrap();
        let mut stolen = rich;
        stolen["title"] = json!("Family reference");
        attacker.write("item:collision".into(), stolen).unwrap();
        let packet = attacker.export("victim").unwrap();
        let empty = json!({"packet":packet,"files":[]});
        assert!(command(
            &mut victim,
            &json!({"op":"relay-peer-receive","library":attacker.library,"envelope":empty})
        )
        .is_err());
        let bad = json!({"packet":packet,"files":[{"meta":meta,"data":STANDARD.encode(b"FORGED_CONTENT!")}]});
        assert!(command(
            &mut victim,
            &json!({"op":"relay-peer-receive","library":attacker.library,"envelope":bad})
        )
        .is_err());
        assert_eq!(
            victim.open().unwrap().document.items[0]["title"],
            "Private note"
        );
        let actual =
            json!({"packet":packet,"files":[{"meta":meta,"data":STANDARD.encode(secret)}]});
        command(
            &mut victim,
            &json!({"op":"relay-peer-receive","library":attacker.library,"envelope":actual}),
        )
        .unwrap();
        assert_eq!(
            victim.open().unwrap().document.items[0]["title"],
            "Private note"
        );
        let exported = command(
            &mut victim,
            &json!({"op":"relay-peer-export","library":attacker.library,"peer":"attacker"}),
        )
        .unwrap();
        assert_eq!(exported["files"][0]["data"], STANDARD.encode(secret));
    }
}
