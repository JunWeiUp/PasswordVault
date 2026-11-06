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
fn page(
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

pub(super) fn capture(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    next: &Document,
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
        load_document(conn, root, vault)?
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
            write(
                conn,
                root,
                vault,
                &Revision {
                    id: new_id(),
                    item_id: item["id"].as_str().unwrap().into(),
                    captured_at: now,
                    item: item.clone(),
                },
            )?;
        }
    }
    for item in &next.items {
        if previous_items
            .get(item["id"].as_str().ok_or(VaultError::InvalidData)?)
            .copied()
            == Some(item)
        {
            continue;
        }
        if page(
            conn,
            root,
            vault,
            item["id"].as_str().ok_or(VaultError::InvalidData)?,
            0,
            1,
        )?
        .1
        .first()
        .is_some_and(|r| r.item == *item)
        {
            continue;
        }
        write(
            conn,
            root,
            vault,
            &Revision {
                id: new_id(),
                item_id: item["id"].as_str().unwrap().into(),
                captured_at: now,
                item: item.clone(),
            },
        )?;
    }
    for item in &previous.items {
        if !next_ids.contains(item["id"].as_str().ok_or(VaultError::InvalidData)?) {
            write(
                conn,
                root,
                vault,
                &Revision {
                    id: new_id(),
                    item_id: item["id"].as_str().unwrap().into(),
                    captured_at: now,
                    item: Value::Null,
                },
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
                self.open()?;
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
                    storage(fs::rename(temp.path(), &destination))?;
                    storage(File::open(&self.directory).and_then(|f| f.sync_all()))?;
                }
                let open = self.open()?;
                let mut next = open.document.clone();
                next.format_version = next.format_version.max(5);
                next.settings["entryHistoryEnabled"] = json!(true);
                let tx = storage(open.connection.transaction())?;
                table(&tx)?;
                save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
                storage(tx.commit())?;
                open.document = next;
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
            "history-prune" => {
                let id = text("id")?;
                let open = self.open()?;
                let current = open
                    .document
                    .items
                    .iter()
                    .find(|i| i["id"] == id)
                    .ok_or(VaultError::InvalidData)?;
                authorize_item_write(&open.document, current)?;
                let revisions = read(&open.connection, &open.root, &open.header.vault_id)?;
                let tx = storage(open.connection.transaction())?;
                for revision in revisions.iter().filter(|r| r.item_id == id) {
                    storage(tx.execute("DELETE FROM entry_history WHERE id=?1", [&revision.id]))?;
                }
                capture(&tx, &open.root, &open.header.vault_id, &open.document)?;
                if !relay::retains_attachments(&tx)? {
                    let retained = with_history(
                        &open.document,
                        &read(&tx, &open.root, &open.header.vault_id)?,
                    );
                    let mut used = std::collections::HashSet::new();
                    for item in &retained.items {
                        crate::archive::item_attachment_refs(item, &mut used)?;
                    }
                    for meta in notes::metas(&tx)? {
                        if !used.contains(&meta.id) {
                            storage(
                                tx.execute("DELETE FROM note_attachments WHERE id=?1", [&meta.id]),
                            )?;
                        }
                    }
                }
                storage(tx.commit())?;
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
                self.validate_note_save(&json!({"item":item,"richNotes":true}))?;
                self.mutate(|doc| {
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
                &Revision {
                    id: format!("{n:032x}"),
                    item_id: item.into(),
                    captured_at: n,
                    item: json!({"id":item,"type":"secureNote","title":format!("Revision {n}")}),
                },
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
            &Revision {
                id: format!("{:032x}", 1),
                item_id: "fixture".into(),
                captured_at: 1,
                item: Value::Null,
            },
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
