//! Encrypted split-table storage for secureNote bodies (`note_bodies`).
//! Each note body is sealed independently with AES-256-GCM inside SQLCipher,
//! keeping `vault_state` compact as personal knowledge-base notes scale.
use super::*;
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NoteBodyRecord {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    note_format: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    note_document: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    note_original: Option<Value>,
}

pub(super) fn enabled(conn: &Connection) -> Result<bool> {
    Ok(storage(conn.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='note_bodies'",
        [],
        |r| r.get::<_, i64>(0),
    ))? != 0)
}

pub(super) fn table(conn: &Connection) -> Result<()> {
    storage(conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS note_bodies(note_id TEXT PRIMARY KEY, payload BLOB NOT NULL, digest BLOB NOT NULL);",
    ))
}

pub(super) fn status(conn: &Connection) -> Result<Value> {
    if !enabled(conn)? {
        return Ok(json!({"enabled": false, "count": 0}));
    }
    let count: u64 = storage(conn.query_row("SELECT count(*) FROM note_bodies", [], |r| r.get(0)))?;
    Ok(json!({"enabled": true, "count": count}))
}

fn body_aad(vault_id: &str, note_id: &str) -> Result<Vec<u8>> {
    serde_json::to_vec(&(vault_id, note_id)).map_err(|_| VaultError::InvalidData)
}

fn body_digest(root: &[u8; 32], note_id: &str, clear: &[u8]) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(note_id.as_bytes());
    hasher.update([0]);
    hasher.update(clear);
    let content_hash = hasher.finalize();
    let mut purpose = Vec::with_capacity(20 + content_hash.len());
    purpose.extend_from_slice(b"note-body-digest-v1:");
    purpose.extend_from_slice(&content_hash);
    subkey(root, &purpose).to_vec()
}

fn extract_record(item: &Value) -> NoteBodyRecord {
    NoteBodyRecord {
        note: item.get("note").and_then(Value::as_str).map(str::to_owned),
        note_format: item
            .get("noteFormat")
            .and_then(Value::as_str)
            .map(str::to_owned),
        note_document: item.get("noteDocument").cloned(),
        note_original: item.get("noteOriginal").cloned(),
    }
}

fn note_preview(text: &str) -> String {
    text.chars().take(240).collect()
}

pub(super) fn is_split(item: &Value) -> bool {
    item.get("_bodySplit") == Some(&Value::Bool(true))
}

pub(super) fn strip_internal_markers(item: &mut Value) {
    if let Some(obj) = item.as_object_mut() {
        obj.remove("_bodySplit");
        obj.remove("_bodyDigest");
        obj.remove("_hasRichBody");
        obj.remove("_searchMeta");
    }
}

/// Writes changed `secureNote` bodies into `note_bodies`, removes deleted note rows,
/// and returns a lightweight `Document` for `vault_state` with bulky note bodies stripped.
/// Notes already in split (`_bodySplit: true`) form are left untouched in O(1).
pub(super) fn sync_and_strip(
    conn: &Connection,
    root: &[u8; 32],
    vault_id: &str,
    doc: &Document,
) -> Result<Document> {
    table(conn)?;
    let mut live_ids = HashSet::new();
    let mut stripped_items = Vec::with_capacity(doc.items.len());
    for item in &doc.items {
        if item["type"] != "secureNote" {
            stripped_items.push(item.clone());
            continue;
        }
        let note_id = item["id"].as_str().ok_or(VaultError::InvalidData)?;
        live_ids.insert(note_id.to_owned());
        if is_split(item) {
            // Untouched lazy note: retain existing encrypted row in `note_bodies` without re-hashing.
            stripped_items.push(item.clone());
            continue;
        }
        let record = extract_record(item);
        let clear =
            Zeroizing::new(serde_json::to_vec(&record).map_err(|_| VaultError::InvalidData)?);
        let digest = body_digest(root, note_id, &clear);
        let existing_digest: Option<Vec<u8>> = storage(
            conn.query_row(
                "SELECT digest FROM note_bodies WHERE note_id=?1",
                [note_id],
                |r| r.get(0),
            )
            .optional(),
        )?;
        if existing_digest.as_deref() != Some(digest.as_slice()) {
            let sealed = seal(
                &subkey(root, b"note-bodies-v1"),
                &clear,
                &body_aad(vault_id, note_id)?,
            )?;
            let encoded = serde_json::to_vec(&sealed).map_err(|_| VaultError::InvalidData)?;
            storage(conn.execute(
                "INSERT INTO note_bodies(note_id,payload,digest) VALUES(?1,?2,?3) ON CONFLICT(note_id) DO UPDATE SET payload=excluded.payload,digest=excluded.digest",
                rusqlite::params![note_id, encoded, digest],
            ))?;
        }
        let has_rich = item.get("noteDocument").is_some() || item.get("noteOriginal").is_some();
        let search_meta = if let Some(note_doc) = item.get("noteDocument") {
            let mut metadata = Vec::new();
            note_search_metadata(note_doc, 0, &mut metadata);
            let joined = metadata.join("\n");
            if joined.is_empty() {
                None
            } else {
                Some(joined.chars().take(4096).collect::<String>())
            }
        } else {
            None
        };
        let mut lite = item.clone();
        if let Some(obj) = lite.as_object_mut() {
            obj.remove("noteDocument");
            obj.remove("noteOriginal");
            if let Some(note_text) = &record.note {
                obj.insert("note".into(), json!(note_preview(note_text)));
            }
            obj.insert("_bodySplit".into(), Value::Bool(true));
            obj.insert("_bodyDigest".into(), json!(hex::encode(&digest)));
            if has_rich {
                obj.insert("_hasRichBody".into(), Value::Bool(true));
            } else {
                obj.remove("_hasRichBody");
            }
            if let Some(meta_text) = search_meta {
                obj.insert("_searchMeta".into(), json!(meta_text));
            } else {
                obj.remove("_searchMeta");
            }
        }
        stripped_items.push(lite);
    }
    let stored_ids = {
        let mut stmt = storage(conn.prepare("SELECT note_id FROM note_bodies"))?;
        let rows = storage(stmt.query_map([], |r| r.get::<_, String>(0)))?;
        storage(rows.collect::<std::result::Result<Vec<_>, _>>())?
    };
    for note_id in stored_ids {
        if !live_ids.contains(&note_id) {
            storage(conn.execute("DELETE FROM note_bodies WHERE note_id=?1", [&note_id]))?;
        }
    }
    Ok(Document {
        format_version: doc.format_version,
        items: stripped_items,
        shared_vaults: doc.shared_vaults.clone(),
        shared_members: doc.shared_members.clone(),
        settings: doc.settings.clone(),
    })
}

/// Hydrates a single `secureNote` marked `_bodySplit` from `note_bodies`, verifying AAD & integrity.
pub(super) fn hydrate_item(
    conn: &Connection,
    root: &[u8; 32],
    vault_id: &str,
    item: &mut Value,
) -> Result<bool> {
    if !is_split(item) {
        return Ok(false);
    }
    if !enabled(conn)? {
        return Err(VaultError::InvalidData);
    }
    let note_id = item["id"]
        .as_str()
        .ok_or(VaultError::InvalidData)?
        .to_owned();
    let bytes: Vec<u8> = storage(
        conn.query_row(
            "SELECT payload FROM note_bodies WHERE note_id=?1",
            [&note_id],
            |r| r.get(0),
        )
        .optional(),
    )?
    .ok_or(VaultError::InvalidData)?;
    let sealed: Sealed = serde_json::from_slice(&bytes).map_err(|_| VaultError::InvalidData)?;
    let clear = unseal(
        &subkey(root, b"note-bodies-v1"),
        &sealed,
        &body_aad(vault_id, &note_id)?,
    )?;
    let record: NoteBodyRecord =
        serde_json::from_slice(&clear).map_err(|_| VaultError::InvalidData)?;
    let obj = item.as_object_mut().ok_or(VaultError::InvalidData)?;
    obj.remove("_bodySplit");
    obj.remove("_bodyDigest");
    obj.remove("_hasRichBody");
    obj.remove("_searchMeta");
    if let Some(note_text) = record.note {
        obj.insert("note".into(), json!(note_text));
    } else {
        obj.remove("note");
    }
    if let Some(fmt) = record.note_format {
        obj.insert("noteFormat".into(), json!(fmt));
    }
    if let Some(doc_node) = record.note_document {
        obj.insert("noteDocument".into(), doc_node);
    }
    if let Some(orig) = record.note_original {
        obj.insert("noteOriginal".into(), orig);
    }
    Ok(true)
}

/// Hydrates any `secureNote` marked `_bodySplit` from `note_bodies`, verifying AAD & integrity.
pub(super) fn hydrate(
    conn: &Connection,
    root: &[u8; 32],
    vault_id: &str,
    mut doc: Document,
) -> Result<Document> {
    let needs_hydrate = doc.items.iter().any(is_split);
    if !needs_hydrate {
        return Ok(doc);
    }
    if !enabled(conn)? {
        return Err(VaultError::InvalidData);
    }
    for item in &mut doc.items {
        hydrate_item(conn, root, vault_id, item)?;
    }
    Ok(doc)
}

pub(super) fn delete_for_note(conn: &Connection, note_id: &str) -> Result<()> {
    if enabled(conn)? {
        storage(conn.execute("DELETE FROM note_bodies WHERE note_id=?1", [note_id]))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_doc(note_body: &str) -> Document {
        Document {
            format_version: 3,
            items: vec![
                json!({
                    "id": "note-1",
                    "type": "secureNote",
                    "title": "持仓情况",
                    "category": "个人档案/财务与持仓",
                    "slug": "finance/portfolio",
                    "note": note_body,
                    "noteFormat": "rich-v1",
                    "noteDocument": {"type": "doc", "content": [{"type": "paragraph", "content": [{"type": "text", "text": note_body}]}]},
                    "noteOriginal": {"format": "plain", "source": "orig"}
                }),
                json!({
                    "id": "acc-1",
                    "type": "password",
                    "title": "GitHub",
                    "username": "lin",
                    "password": "secret"
                }),
            ],
            ..Document::default()
        }
    }

    #[test]
    fn split_and_hydrate_round_trips_and_keeps_vault_state_compact() {
        let conn = Connection::open_in_memory().unwrap();
        let root = [9u8; 32];
        let vault_id = "0123456789abcdef0123456789abcdef";
        let long_body = "持仓明细行 ".repeat(200);
        let doc = sample_doc(&long_body);

        let stripped = sync_and_strip(&conn, &root, vault_id, &doc).unwrap();
        assert_eq!(stripped.items[0]["_bodySplit"], true);
        assert!(stripped.items[0].get("noteDocument").is_none());
        assert!(stripped.items[0].get("noteOriginal").is_none());
        assert!(stripped.items[0]["note"].as_str().unwrap().chars().count() <= 240);
        assert_eq!(status(&conn).unwrap(), json!({"enabled": true, "count": 1}));

        let hydrated = hydrate(&conn, &root, vault_id, stripped).unwrap();
        assert!(hydrated.items[0].get("_bodySplit").is_none());
        assert_eq!(hydrated.items[0]["note"], long_body);
        assert_eq!(
            hydrated.items[0]["noteDocument"],
            doc.items[0]["noteDocument"]
        );
        assert_eq!(
            hydrated.items[0]["noteOriginal"],
            doc.items[0]["noteOriginal"]
        );
        assert_eq!(hydrated.items[1], doc.items[1]);
    }

    #[test]
    fn missing_or_swapped_note_body_fails_closed() {
        let conn = Connection::open_in_memory().unwrap();
        let root = [7u8; 32];
        let vault_id = "0123456789abcdef0123456789abcdef";
        let doc = sample_doc("secret holdings");
        let stripped = sync_and_strip(&conn, &root, vault_id, &doc).unwrap();

        // Wrong vault_id breaks AAD authentication.
        assert!(matches!(
            hydrate(
                &conn,
                &root,
                "fedcba9876543210fedcba9876543210",
                stripped.clone()
            ),
            Err(VaultError::Authentication)
        ));

        // Missing row fails closed.
        delete_for_note(&conn, "note-1").unwrap();
        assert!(matches!(
            hydrate(&conn, &root, vault_id, stripped),
            Err(VaultError::InvalidData)
        ));
    }

    #[test]
    fn unchanged_note_body_is_not_rewritten_and_removed_note_is_pruned() {
        let conn = Connection::open_in_memory().unwrap();
        let root = [3u8; 32];
        let vault_id = "0123456789abcdef0123456789abcdef";
        let mut doc = sample_doc("alpha");
        sync_and_strip(&conn, &root, vault_id, &doc).unwrap();
        let first_payload: Vec<u8> = conn
            .query_row(
                "SELECT payload FROM note_bodies WHERE note_id='note-1'",
                [],
                |r| r.get(0),
            )
            .unwrap();

        // Re-saving with unchanged note body preserves identical ciphertext (no redundant write).
        doc.items[1]["title"] = json!("GitHub Updated");
        sync_and_strip(&conn, &root, vault_id, &doc).unwrap();
        let second_payload: Vec<u8> = conn
            .query_row(
                "SELECT payload FROM note_bodies WHERE note_id='note-1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(first_payload, second_payload);

        // Removing the note prunes its split row.
        doc.items.retain(|i| i["id"] != "note-1");
        sync_and_strip(&conn, &root, vault_id, &doc).unwrap();
        assert_eq!(status(&conn).unwrap()["count"], 0);
    }
}
