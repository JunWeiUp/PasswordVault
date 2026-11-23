//! Whole-record history is committed in the same encrypted transaction as the document.
use super::*;

pub(super) use crate::archive::HistoryRevision as Revision;

pub(super) fn enabled(conn: &Connection) -> Result<bool> {
    Ok(storage(conn.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='entry_history'",
        [],
        |r| r.get::<_, i64>(0),
    ))? != 0)
}
pub(super) fn table(conn: &Connection) -> Result<()> {
    storage(conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS entry_history(id TEXT PRIMARY KEY, payload BLOB NOT NULL, item_key BLOB)",
    ))
}
fn index_key(root: &[u8; 32], item: &str) -> Vec<u8> {
    subkey(root, format!("entry-history-index-v1/{item}").as_bytes()).to_vec()
}
fn decode(root: &[u8; 32], vault: &str, id: &str, bytes: &[u8]) -> Result<Revision> {
    let sealed: Sealed = serde_json::from_slice(bytes).map_err(|_| VaultError::InvalidData)?;
    let aad = serde_json::to_vec(&(vault, id)).map_err(|_| VaultError::InvalidData)?;
    let clear = unseal(&subkey(root, b"entry-history-v1"), &sealed, &aad)?;
    let revision: Revision = serde_json::from_slice(&clear).map_err(|_| VaultError::InvalidData)?;
    if revision.id != id {
        return Err(VaultError::Authentication);
    }
    Ok(revision)
}
/// Resumable schema migration is atomic, including when nested in a vault write.
/// Only one bounded batch of encrypted payloads is held while building the blind index.
fn ensure_index(conn: &Connection, root: &[u8; 32], vault: &str) -> Result<()> {
    let has_column: bool = storage(conn.query_row(
        "SELECT count(*) FROM pragma_table_info('entry_history') WHERE name='item_key'",
        [],
        |row| row.get::<_, i64>(0),
    ))? != 0;
    let pending = if has_column {
        storage(conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM entry_history WHERE item_key IS NULL)",
            [],
            |row| row.get::<_, bool>(0),
        ))?
    } else {
        true
    };
    if has_column && !pending {
        return storage(conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS entry_history_item ON entry_history(item_key)",
        ));
    }
    storage(conn.execute_batch("SAVEPOINT history_index_migration"))?;
    let result = (|| {
        if !has_column {
            storage(conn.execute_batch("ALTER TABLE entry_history ADD COLUMN item_key BLOB"))?;
        }
        loop {
            let batch = {
                let mut stmt = storage(conn.prepare(
                    "SELECT id,payload FROM entry_history WHERE item_key IS NULL LIMIT 256",
                ))?;
                let rows = storage(stmt.query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?))
                }))?;
                storage(rows.collect::<std::result::Result<Vec<_>, _>>())?
            };
            if batch.is_empty() {
                break;
            }
            for (id, payload) in batch {
                let revision = decode(root, vault, &id, &payload)?;
                storage(conn.execute(
                    "UPDATE entry_history SET item_key=?1 WHERE id=?2",
                    rusqlite::params![index_key(root, &revision.item_id), id],
                ))?;
            }
        }
        storage(conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS entry_history_item ON entry_history(item_key)",
        ))
    })();
    if result.is_ok() {
        storage(conn.execute_batch("RELEASE history_index_migration"))?;
    } else {
        storage(conn.execute_batch(
            "ROLLBACK TO history_index_migration; RELEASE history_index_migration",
        ))?;
    }
    result
}
pub(super) fn page(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    item: &str,
    offset: u64,
    limit: u64,
) -> Result<(u64, Vec<Revision>)> {
    if !enabled(conn)? {
        return Ok((0, vec![]));
    }
    ensure_index(conn, root, vault)?;
    let key = index_key(root, item);
    let total = storage(conn.query_row(
        "SELECT count(*) FROM entry_history WHERE item_key=?1",
        [&key],
        |row| row.get::<_, u64>(0),
    ))?;
    let mut stmt=storage(conn.prepare("SELECT id,payload FROM entry_history WHERE item_key=?1 ORDER BY rowid DESC LIMIT ?2 OFFSET ?3"))?;
    let rows = storage(stmt.query_map(
        rusqlite::params![key, limit, offset.min(i64::MAX as u64)],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?)),
    ))?;
    let revisions = rows
        .map(|row| {
            let (id, payload) = storage(row)?;
            let revision = decode(root, vault, &id, &payload)?;
            if revision.item_id != item {
                return Err(VaultError::Authentication);
            }
            Ok(revision)
        })
        .collect::<Result<Vec<_>>>()?;
    Ok((total, revisions))
}
pub(super) fn read(conn: &Connection, root: &[u8; 32], vault: &str) -> Result<Vec<Revision>> {
    if !enabled(conn)? {
        return Ok(vec![]);
    }
    let mut stmt = storage(conn.prepare("SELECT id, payload FROM entry_history ORDER BY rowid"))?;
    let rows = storage(stmt.query_map([], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?))
    }))?;
    rows.map(|r| {
        let (id, bytes) = storage(r)?;
        decode(root, vault, &id, &bytes)
    })
    .collect()
}
pub(super) fn write(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    revision: &Revision,
) -> Result<()> {
    if revision.id.len() != 32 || revision.item_id.is_empty() || revision.item_id.len() > 256 {
        return Err(VaultError::InvalidData);
    }
    if !revision.item.is_null() {
        let mut item = revision.item.clone();
        normalize_item(&mut item)?;
        if item["id"] != revision.item_id {
            return Err(VaultError::InvalidData);
        }
    }
    table(conn)?;
    ensure_index(conn, root, vault)?;
    let aad = serde_json::to_vec(&(vault, &revision.id)).map_err(|_| VaultError::InvalidData)?;
    let bytes = Zeroizing::new(serde_json::to_vec(revision).map_err(|_| VaultError::InvalidData)?);
    let sealed = seal(&subkey(root, b"entry-history-v1"), &bytes, &aad)?;
    // An imported immutable revision cannot replace a different existing revision.
    let previous: Option<Vec<u8>> = storage(
        conn.query_row(
            "SELECT payload FROM entry_history WHERE id=?1",
            [&revision.id],
            |r| r.get(0),
        )
        .optional(),
    )?;
    if let Some(previous) = previous {
        let previous: Sealed =
            serde_json::from_slice(&previous).map_err(|_| VaultError::InvalidData)?;
        if unseal(&subkey(root, b"entry-history-v1"), &previous, &aad)?.as_slice()
            != bytes.as_slice()
        {
            return Err(VaultError::InvalidData);
        }
        return Ok(());
    }
    storage(conn.execute(
        "INSERT INTO entry_history(id,payload,item_key) VALUES(?1,?2,?3)",
        rusqlite::params![
            revision.id,
            serde_json::to_vec(&sealed).map_err(|_| VaultError::InvalidData)?,
            index_key(root, &revision.item_id)
        ],
    ))?;
    Ok(())
}
use rusqlite::OptionalExtension;

const MANUAL_COALESCE_MS: u64 = 5 * 60 * 1000;

#[derive(Clone, Default)]
pub(super) struct HistoryMeta {
    pub item_id: Option<String>,
    pub actor_type: Option<String>,
    pub actor: Option<String>,
    pub summary: Option<String>,
    pub milestone: bool,
    pub coalesce: bool,
}

impl HistoryMeta {
    pub(super) fn parse(raw: &Value, item_id: Option<&str>) -> Result<Option<Self>> {
        if raw.is_null() {
            return Ok(None);
        }
        let obj = raw.as_object().ok_or(VaultError::InvalidData)?;
        let bounded = |key: &str, max: usize| -> Result<Option<String>> {
            match obj.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(s)) => {
                    let t = s.trim();
                    if t.chars().count() > max || t.chars().any(char::is_control) {
                        return Err(VaultError::InvalidData);
                    }
                    Ok((!t.is_empty()).then(|| t.to_owned()))
                }
                _ => Err(VaultError::InvalidData),
            }
        };
        let actor_type = bounded("actorType", 32)?;
        if let Some(ref kind) = actor_type {
            if !matches!(
                kind.as_str(),
                "user" | "ai" | "milestone" | "restore" | "sync"
            ) {
                return Err(VaultError::InvalidData);
            }
        }
        Ok(Some(Self {
            item_id: item_id.map(str::to_owned),
            actor_type,
            actor: bounded("actor", 120)?,
            summary: bounded("summary", 240)?,
            milestone: obj
                .get("milestone")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            coalesce: obj
                .get("coalesce")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        }))
    }
}

pub(super) fn capture(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    next: &Document,
) -> Result<()> {
    capture_with_meta(conn, root, vault, next, None)
}

pub(super) fn capture_with_meta(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    next: &Document,
    meta: Option<&HistoryMeta>,
) -> Result<()> {
    if !enabled(conn)?
        || next.settings["activePeerLibrary"]
            .as_str()
            .is_some_and(|s| !s.is_empty())
    {
        return Ok(());
    }
    let exists: bool = storage(conn.query_row("SELECT count(*) FROM vault_state", [], |r| {
        r.get::<_, i64>(0)
    }))? > 0;
    let previous = if exists {
        load_document_raw(conn, root, vault)?
    } else {
        Document::default()
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| VaultError::InvalidData)?
        .as_millis() as u64;
    ensure_index(conn, root, vault)?;
    let known = {
        let mut stmt = storage(conn.prepare("SELECT DISTINCT item_key FROM entry_history"))?;
        let rows = storage(stmt.query_map([], |row| row.get::<_, Vec<u8>>(0)))?;
        storage(rows.collect::<std::result::Result<std::collections::HashSet<_>, _>>())?
    };
    let previous_items: std::collections::HashMap<_, _> = previous
        .items
        .iter()
        .map(|item| (item["id"].as_str().unwrap_or(""), item))
        .collect();
    let next_ids: std::collections::HashSet<_> = next
        .items
        .iter()
        .filter_map(|item| item["id"].as_str())
        .collect();
    for item in &previous.items {
        if !known.contains(&index_key(
            root,
            item["id"].as_str().ok_or(VaultError::InvalidData)?,
        )) {
            let mut full = item.clone();
            note_bodies::hydrate_item(conn, root, vault, &mut full)?;
            write(
                conn,
                root,
                vault,
                &Revision::plain(new_id(), item["id"].as_str().unwrap().into(), now, full),
            )?;
        }
    }
    for item in &next.items {
        let id = item["id"].as_str().ok_or(VaultError::InvalidData)?;
        let item_meta = meta.filter(|m| m.item_id.as_deref().is_none_or(|target| target == id));
        let force_milestone = item_meta.is_some_and(|m| m.milestone);
        // Untouched split notes skip hydration in O(1); non-split notes compare directly when previous wasn't split.
        if !force_milestone && previous_items.get(id).copied() == Some(item) {
            continue;
        }
        let mut full = item.clone();
        note_bodies::hydrate_item(conn, root, vault, &mut full)?;
        let (total, latest_rows) = page(conn, root, vault, id, 0, 1)?;
        if !force_milestone && latest_rows.first().is_some_and(|r| r.item == full) {
            continue;
        }
        // Coalesce continuous manual note drafts within 5 minutes, while keeping the baseline,
        // milestones, AI updates, restores, and attachment changes intact.
        if full["type"] == "secureNote"
            && total >= 2
            && item_meta.is_some_and(|m| {
                m.coalesce && !m.milestone && matches!(m.actor_type.as_deref(), None | Some("user"))
            })
        {
            if let Some(latest) = latest_rows.first() {
                let latest_is_manual = latest.milestone != Some(true)
                    && matches!(latest.actor_type.as_deref(), None | Some("user"));
                let within_window = now.saturating_sub(latest.captured_at) < MANUAL_COALESCE_MS;
                let mut old_refs = std::collections::HashSet::new();
                let mut new_refs = std::collections::HashSet::new();
                let same_attachments =
                    crate::archive::item_attachment_refs(&latest.item, &mut old_refs).is_ok()
                        && crate::archive::item_attachment_refs(&full, &mut new_refs).is_ok()
                        && old_refs == new_refs;
                if latest_is_manual && within_window && same_attachments {
                    storage(conn.execute("DELETE FROM entry_history WHERE id=?1", [&latest.id]))?;
                }
            }
        }
        write(
            conn,
            root,
            vault,
            &Revision {
                id: new_id(),
                item_id: id.into(),
                captured_at: now,
                item: full,
                actor_type: item_meta.and_then(|m| m.actor_type.clone()),
                actor: item_meta.and_then(|m| m.actor.clone()),
                summary: item_meta.and_then(|m| m.summary.clone()),
                milestone: item_meta.and_then(|m| m.milestone.then_some(true)),
            },
        )?;
    }
    for item in &previous.items {
        if !next_ids.contains(item["id"].as_str().ok_or(VaultError::InvalidData)?) {
            write(
                conn,
                root,
                vault,
                &Revision::plain(
                    new_id(),
                    item["id"].as_str().unwrap().into(),
                    now,
                    Value::Null,
                ),
            )?;
        }
    }
    Ok(())
}

pub(super) fn with_history(doc: &Document, revisions: &[Revision]) -> Document {
    let mut all = doc.clone();
    all.items.extend(
        revisions
            .iter()
            .filter(|r| !r.item.is_null())
            .map(|r| r.item.clone()),
    );
    all
}

impl DiskVault {
    pub(super) fn ensure_history_enabled(&mut self) -> Result<()> {
        if enabled(&self.open()?.connection)? {
            return Ok(());
        }
        let destination = self.directory.join("before-entry-history");
        if !destination.exists() {
            let temp = storage(
                tempfile::Builder::new()
                    .prefix(".history-backup-")
                    .tempdir_in(&self.directory),
            )?;
            for file in ["header.json", "vault.sqlite"] {
                atomic_write(
                    &temp.path().join(file),
                    &storage(fs::read(self.directory.join(file)))?,
                )?;
            }
            note_blobs::copy_blobs_dir(&self.directory, temp.path())?;
            storage(fs::rename(temp.path(), &destination))?;
            storage(crate::native_file_ops::sync_directory(&self.directory))?;
        }
        let open = self.open()?;
        let mut next = open.document.clone();
        next.format_version = next.format_version.max(5);
        next.settings["entryHistoryEnabled"] = json!(true);
        let tx = storage(open.connection.transaction())?;
        table(&tx)?;
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
        Ok(())
    }
    pub(super) fn history_command(&mut self, request: &Value) -> Result<Value> {
        let text = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        if let Some(library) = self.open()?.document.settings["activePeerLibrary"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
        {
            let mut scoped = request.clone();
            scoped["library"] = json!(library);
            scoped["op"] = json!(text("op")?.replacen("history-", "relay-peer-history-", 1));
            return self.relay_command(&scoped);
        }
        match text("op")? {
            "history-enable" => {
                self.ensure_history_enabled()?;
                Ok(json!({"ok":true}))
            }
            "history-status" => Ok(json!({"enabled":enabled(&self.open()?.connection)?})),
            "history-list" => {
                let id = text("id")?;
                let offset = request["offset"].as_u64().unwrap_or(0);
                let limit = request["limit"].as_u64().unwrap_or(100).clamp(1, 500);
                let open = self.open()?;
                let (total, revisions) = page(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    id,
                    offset,
                    limit,
                )?;
                Ok(json!({"total":total,"revisions":revisions}))
            }
            "history-milestone" => {
                let id = text("id")?;
                let summary = text("summary")?.trim();
                if summary.is_empty()
                    || summary.chars().count() > 240
                    || summary.chars().any(char::is_control)
                {
                    return Err(VaultError::InvalidData);
                }
                self.ensure_history_enabled()?;
                let open = self.open()?;
                let mut current = open
                    .document
                    .items
                    .iter()
                    .find(|i| i["id"] == id && i["isDeleted"] != true)
                    .cloned()
                    .ok_or(VaultError::InvalidData)?;
                note_bodies::hydrate_item(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &mut current,
                )?;
                authorize_item_write(&open.document, &current)?;
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_err(|_| VaultError::InvalidData)?
                    .as_millis() as u64;
                let rev = Revision {
                    id: new_id(),
                    item_id: id.into(),
                    captured_at: now,
                    item: current,
                    actor_type: Some("milestone".into()),
                    actor: Some("里程碑 · 我".into()),
                    summary: Some(summary.to_owned()),
                    milestone: Some(true),
                };
                let tx = storage(open.connection.transaction())?;
                write(&tx, &open.root, &open.header.vault_id, &rev)?;
                storage(tx.commit())?;
                Ok(json!({"ok":true,"revision":rev}))
            }
            "history-prune" => {
                let id = text("id")?;
                let keep_milestones = request["keepMilestones"].as_bool().unwrap_or(false);
                let vault_dir = self.directory.clone();
                let open = self.open()?;
                let mut current = open
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
                    &mut current,
                )?;
                authorize_item_write(&open.document, &current)?;
                let revisions = read(&open.connection, &open.root, &open.header.vault_id)?;
                let tx = storage(open.connection.transaction())?;
                for revision in revisions
                    .iter()
                    .filter(|r| r.item_id == id && !(keep_milestones && r.milestone == Some(true)))
                {
                    storage(tx.execute("DELETE FROM entry_history WHERE id=?1", [&revision.id]))?;
                }
                let (_, remaining) = page(&tx, &open.root, &open.header.vault_id, id, 0, 1)?;
                if !remaining.first().is_some_and(|r| r.item == current) {
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map_err(|_| VaultError::InvalidData)?
                        .as_millis() as u64;
                    write(
                        &tx,
                        &open.root,
                        &open.header.vault_id,
                        &Revision::plain(new_id(), id.into(), now, current),
                    )?;
                }
                capture(&tx, &open.root, &open.header.vault_id, &open.document)?;
                let retains = relay::retains_attachments(&tx)?;
                if !retains {
                    let hydrated = note_bodies::hydrate(
                        &tx,
                        &open.root,
                        &open.header.vault_id,
                        open.document.clone(),
                    )?;
                    let retained =
                        with_history(&hydrated, &read(&tx, &open.root, &open.header.vault_id)?);
                    let mut used = std::collections::HashSet::new();
                    for item in &retained.items {
                        crate::archive::item_attachment_refs(item, &mut used)?;
                    }
                    for meta in notes::metas(&tx)? {
                        if !used.contains(&meta.id) {
                            storage(
                                tx.execute("DELETE FROM note_attachments WHERE id=?1", [&meta.id]),
                            )?;
                            storage(tx.execute(
                                "DELETE FROM note_attachment_state WHERE attachment_id=?1",
                                [&meta.id],
                            ))?;
                            note_blobs::delete_ref(&tx, &meta.id)?;
                        }
                    }
                }
                storage(tx.commit())?;
                if !retains {
                    let _ = note_blobs::prune_unreferenced(&vault_dir, &open.connection);
                }
                Ok(json!({"ok":true}))
            }
            "history-restore" => {
                let id = text("id")?;
                let revision_id = text("revisionId")?;
                let time = text("time")?;
                chrono::DateTime::parse_from_rfc3339(time).map_err(|_| VaultError::InvalidData)?;
                let open = self.open()?;
                let payload: Vec<u8> = storage(open.connection.query_row(
                    "SELECT payload FROM entry_history WHERE id=?1",
                    [revision_id],
                    |row| row.get(0),
                ))?;
                let revision = decode(&open.root, &open.header.vault_id, revision_id, &payload)?;
                if revision.item_id != id {
                    return Err(VaultError::InvalidData);
                }
                if revision.item.is_null() {
                    return Err(VaultError::InvalidData);
                }
                // Never use an old personal snapshot to escape current shared-library permissions.
                if let Some(current) = open.document.items.iter().find(|v| v["id"] == id) {
                    authorize_item_write(&open.document, current)?;
                    if current["sharedVaultId"] != revision.item["sharedVaultId"] {
                        return Err(VaultError::Authentication);
                    }
                }
                authorize_item_write(&open.document, &revision.item)?;
                let mut item = revision.item;
                item["updatedAt"] = json!(time);
                let meta = HistoryMeta {
                    item_id: Some(id.to_owned()),
                    actor_type: Some("restore".into()),
                    actor: Some("从历史恢复 · 我".into()),
                    summary: Some(
                        revision
                            .summary
                            .as_deref()
                            .map(|s| format!("恢复历史版本（{s}）"))
                            .unwrap_or_else(|| "从历史版本恢复".into()),
                    ),
                    milestone: false,
                    coalesce: false,
                };
                self.validate_note_save(&json!({"item":item,"richNotes":true}))?;
                self.mutate_with_history(Some(&meta), |doc| {
                    doc.upsert(item)?;
                    Ok(json!({"ok":true}))
                })
            }
            _ => Err(VaultError::Unsupported),
        }
    }
}

#[cfg(test)]
mod index_tests {
    use super::*;
    fn legacy_row(conn: &Connection, root: &[u8; 32], revision: &Revision) {
        let aad = serde_json::to_vec(&("fixture", &revision.id)).unwrap();
        let payload = seal(
            &subkey(root, b"entry-history-v1"),
            &serde_json::to_vec(revision).unwrap(),
            &aad,
        )
        .unwrap();
        conn.execute(
            "INSERT INTO entry_history(id,payload) VALUES(?1,?2)",
            rusqlite::params![revision.id, serde_json::to_vec(&payload).unwrap()],
        )
        .unwrap();
    }
    #[test]
    fn legacy_history_index_migration_is_atomic_and_paginated() {
        let conn = Connection::open_in_memory().unwrap();
        let root = [42; 32];
        conn.execute_batch("CREATE TABLE entry_history(id TEXT PRIMARY KEY,payload BLOB NOT NULL)")
            .unwrap();
        for n in 0..520 {
            let item = if n % 2 == 0 { "first" } else { "second" };
            legacy_row(
                &conn,
                &root,
                &Revision::plain(
                    format!("{n:032x}"),
                    item.into(),
                    n,
                    json!({"id":item,"type":"secureNote","title":format!("Revision {n}")}),
                ),
            );
        }
        let (total, rows) = page(&conn, &root, "fixture", "first", 3, 2).unwrap();
        assert_eq!(total, 260);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].captured_at, 512);
        let key: Vec<u8> = conn
            .query_row("SELECT item_key FROM entry_history LIMIT 1", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(key.len(), 32);
        assert_ne!(key, b"first");
        // Reading one item's page must not decrypt every unrelated historical record.
        conn.execute(
            "UPDATE entry_history SET payload=?1 WHERE id=?2",
            rusqlite::params![b"damaged-unrelated".as_slice(), format!("{:032x}", 519)],
        )
        .unwrap();
        assert_eq!(
            page(&conn, &root, "fixture", "first", 0, 2)
                .unwrap()
                .1
                .len(),
            2
        );
        assert!(page(&conn, &root, "fixture", "second", 0, 2).is_err());
        assert!(page(&conn, &[43; 32], "fixture", "first", 0, 1)
            .unwrap()
            .1
            .is_empty());
    }
    #[test]
    fn malformed_legacy_payload_does_not_leave_a_partial_index() {
        let conn = Connection::open_in_memory().unwrap();
        let root = [24; 32];
        conn.execute_batch("CREATE TABLE entry_history(id TEXT PRIMARY KEY,payload BLOB NOT NULL)")
            .unwrap();
        legacy_row(
            &conn,
            &root,
            &Revision::plain(format!("{:032x}", 1), "fixture".into(), 1, Value::Null),
        );
        conn.execute(
            "INSERT INTO entry_history VALUES('broken',?1)",
            [b"invalid".as_slice()],
        )
        .unwrap();
        assert!(ensure_index(&conn, &root, "fixture").is_err());
        let count: i64 = conn
            .query_row(
                "SELECT count(*) FROM pragma_table_info('entry_history') WHERE name='item_key'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 0);
        conn.execute("DELETE FROM entry_history WHERE id='broken'", [])
            .unwrap();
        assert_eq!(
            page(&conn, &root, "fixture", "fixture", 0, 10).unwrap().0,
            1
        );
    }
}
