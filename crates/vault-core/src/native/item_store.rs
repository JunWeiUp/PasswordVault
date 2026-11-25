//! Per-item encrypted SQLCipher storage (`vault_items`).
//!
//! Each item in the vault document is stored in its own authenticated AES-256-GCM row
//! (`item-v1` subkey, AAD bound to `(vault_id, item_id)`), updated incrementally inside
//! the same SQLCipher transaction as `vault_state`. Unchanged items are skipped via a
//! keyed digest, while `vault_state` remains intact for full backward compatibility with
//! existing vaults and older sync peers.
use super::*;
use rusqlite::OptionalExtension;
use std::collections::{HashMap, HashSet};

pub(super) fn enabled(conn: &Connection) -> Result<bool> {
    Ok(storage(conn.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='vault_items'",
        [],
        |r| r.get::<_, i64>(0),
    ))? != 0)
}

pub(super) fn table(conn: &Connection) -> Result<()> {
    storage(conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS vault_items(\
            id TEXT PRIMARY KEY,\
            item_type TEXT NOT NULL,\
            is_deleted INTEGER NOT NULL,\
            updated_at TEXT NOT NULL,\
            payload BLOB NOT NULL,\
            digest BLOB NOT NULL\
        );",
    ))
}

fn item_aad(vault_id: &str, item_id: &str) -> Result<Vec<u8>> {
    serde_json::to_vec(&(vault_id, item_id)).map_err(|_| VaultError::InvalidData)
}

fn item_digest(root: &[u8; 32], item_id: &str, clear: &[u8]) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(item_id.as_bytes());
    hasher.update([0]);
    hasher.update(clear);
    let content_hash = hasher.finalize();
    let mut purpose = Vec::with_capacity(15 + content_hash.len());
    purpose.extend_from_slice(b"item-digest-v1:");
    purpose.extend_from_slice(&content_hash);
    subkey(root, &purpose).to_vec()
}

fn upsert_item(
    conn: &Connection,
    root: &[u8; 32],
    vault_id: &str,
    item: &Value,
    check_existing_digest: bool,
) -> Result<()> {
    let id = item["id"].as_str().ok_or(VaultError::InvalidData)?;
    let item_type = item["type"].as_str().unwrap_or("");
    let is_deleted: i64 = if item["isDeleted"].as_bool().unwrap_or(false) {
        1
    } else {
        0
    };
    let updated_at = item["updatedAt"].as_str().unwrap_or("");
    let clear = Zeroizing::new(serde_json::to_vec(item).map_err(|_| VaultError::InvalidData)?);
    let digest = item_digest(root, id, &clear);
    if check_existing_digest {
        let existing: Option<Vec<u8>> = storage(
            conn.query_row("SELECT digest FROM vault_items WHERE id=?1", [id], |r| {
                r.get(0)
            })
            .optional(),
        )?;
        if existing.as_deref() == Some(digest.as_slice()) {
            return Ok(());
        }
    }
    let aad = item_aad(vault_id, id)?;
    let sealed = seal(&subkey(root, b"item-v1"), &clear, &aad)?;
    let encrypted = serde_json::to_vec(&sealed).map_err(|_| VaultError::InvalidData)?;
    storage(conn.execute(
        "INSERT INTO vault_items(id,item_type,is_deleted,updated_at,payload,digest) \
         VALUES(?1,?2,?3,?4,?5,?6) \
         ON CONFLICT(id) DO UPDATE SET \
            item_type=excluded.item_type,\
            is_deleted=excluded.is_deleted,\
            updated_at=excluded.updated_at,\
            payload=excluded.payload,\
            digest=excluded.digest",
        rusqlite::params![id, item_type, is_deleted, updated_at, encrypted, digest],
    ))?;
    Ok(())
}

/// Synchronizes `vault_items` with `persisted` inside the caller's SQLCipher transaction.
/// When `previous` is supplied and the table already matches `previous.items.len()`,
/// only added, modified, or removed items touch SQLite and AES-GCM.
pub(super) fn sync_items(
    conn: &Connection,
    root: &[u8; 32],
    vault_id: &str,
    previous: Option<&Document>,
    persisted: &Document,
) -> Result<()> {
    table(conn)?;
    if let Some(prev) = previous {
        let row_count: i64 =
            storage(conn.query_row("SELECT count(*) FROM vault_items", [], |r| r.get(0)))?;
        if row_count as usize == prev.items.len() {
            let mut prev_by_id: HashMap<&str, &Value> = HashMap::with_capacity(prev.items.len());
            let mut prev_all_have_ids = true;
            for item in &prev.items {
                if let Some(id) = item["id"].as_str() {
                    prev_by_id.insert(id, item);
                } else {
                    prev_all_have_ids = false;
                    break;
                }
            }
            if prev_all_have_ids {
                let mut seen = HashSet::with_capacity(persisted.items.len());
                for item in &persisted.items {
                    let id = item["id"].as_str().ok_or(VaultError::InvalidData)?;
                    seen.insert(id);
                    if prev_by_id.get(id).copied() == Some(item) {
                        continue;
                    }
                    upsert_item(conn, root, vault_id, item, false)?;
                }
                for old_id in prev_by_id.keys() {
                    if !seen.contains(old_id) {
                        storage(conn.execute("DELETE FROM vault_items WHERE id=?1", [old_id]))?;
                    }
                }
                return Ok(());
            }
        }
    }

    let mut live_ids = HashSet::with_capacity(persisted.items.len());
    for item in &persisted.items {
        let id = item["id"].as_str().ok_or(VaultError::InvalidData)?;
        live_ids.insert(id.to_owned());
        upsert_item(conn, root, vault_id, item, true)?;
    }

    let mut stmt = storage(conn.prepare("SELECT id FROM vault_items"))?;
    let stored_ids: Vec<String> = storage(
        stmt.query_map([], |r| r.get::<_, String>(0))
            .and_then(|rows| rows.collect::<std::result::Result<Vec<_>, _>>()),
    )?;
    for stored_id in stored_ids {
        if !live_ids.contains(&stored_id) {
            storage(conn.execute("DELETE FROM vault_items WHERE id=?1", [&stored_id]))?;
        }
    }
    Ok(())
}

/// O(1) authenticated single-item lookup from `vault_items`.
/// Returns `Ok(None)` when the table does not yet exist (pre-migration vault) or the id is absent.
#[allow(dead_code)]
pub(super) fn get_item(
    conn: &Connection,
    root: &[u8; 32],
    vault_id: &str,
    item_id: &str,
) -> Result<Option<Value>> {
    if !enabled(conn)? {
        return Ok(None);
    }
    let encrypted: Option<Vec<u8>> = storage(
        conn.query_row(
            "SELECT payload FROM vault_items WHERE id=?1",
            [item_id],
            |r| r.get(0),
        )
        .optional(),
    )?;
    let Some(bytes) = encrypted else {
        return Ok(None);
    };
    let sealed: Sealed = serde_json::from_slice(&bytes).map_err(|_| VaultError::InvalidData)?;
    let aad = item_aad(vault_id, item_id)?;
    let clear = unseal(&subkey(root, b"item-v1"), &sealed, &aad)?;
    let item: Value = serde_json::from_slice(&clear).map_err(|_| VaultError::InvalidData)?;
    Ok(Some(item))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_vault() -> (tempfile::TempDir, DiskVault) {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = DiskVault::new(&dir.path().join("vault")).unwrap();
        vault
            .command(&json!({"op": "create", "password": "fixture-password"}))
            .unwrap();
        (dir, vault)
    }

    fn save_item(vault: &mut DiskVault, id: &str, title: &str) {
        vault
            .command(&json!({
                "op": "save",
                "item": {
                    "id": id,
                    "type": "password",
                    "title": title,
                    "username": "alice",
                    "password": "synthetic-secret",
                    "updatedAt": "2026-01-01T00:00:00Z"
                }
            }))
            .unwrap();
    }

    #[test]
    fn incremental_writes_only_dirty_rows() {
        let (_dir, mut vault) = test_vault();
        save_item(&mut vault, "item-a", "Alpha");
        save_item(&mut vault, "item-b", "Beta");

        let open = vault.open().unwrap();
        let payload_a_before: Vec<u8> = open
            .connection
            .query_row(
                "SELECT payload FROM vault_items WHERE id='item-a'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let payload_b_before: Vec<u8> = open
            .connection
            .query_row(
                "SELECT payload FROM vault_items WHERE id='item-b'",
                [],
                |r| r.get(0),
            )
            .unwrap();

        // Modify only item-b; item-a's ciphertext (and random nonce) must remain untouched.
        save_item(&mut vault, "item-b", "Beta Updated");

        let open = vault.open().unwrap();
        let payload_a_after: Vec<u8> = open
            .connection
            .query_row(
                "SELECT payload FROM vault_items WHERE id='item-a'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let payload_b_after: Vec<u8> = open
            .connection
            .query_row(
                "SELECT payload FROM vault_items WHERE id='item-b'",
                [],
                |r| r.get(0),
            )
            .unwrap();

        assert_eq!(payload_a_before, payload_a_after);
        assert_ne!(payload_b_before, payload_b_after);

        let fetched = get_item(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            "item-b",
        )
        .unwrap()
        .unwrap();
        assert_eq!(fetched["title"], "Beta Updated");
    }

    #[test]
    fn deletions_prune_item_rows() {
        let (_dir, mut vault) = test_vault();
        save_item(&mut vault, "item-a", "Alpha");
        save_item(&mut vault, "item-b", "Beta");

        vault
            .command(&json!({"op": "remove", "id": "item-a"}))
            .unwrap();

        let open = vault.open().unwrap();
        assert!(get_item(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            "item-a"
        )
        .unwrap()
        .is_none());
        assert!(get_item(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            "item-b"
        )
        .unwrap()
        .is_some());
    }

    #[test]
    fn aad_rejects_swapped_or_tampered_item_rows() {
        let (_dir, mut vault) = test_vault();
        save_item(&mut vault, "item-a", "Alpha");
        save_item(&mut vault, "item-b", "Beta");

        let open = vault.open().unwrap();
        let payload_b: Vec<u8> = open
            .connection
            .query_row(
                "SELECT payload FROM vault_items WHERE id='item-b'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        // Swap item-b's ciphertext into item-a's row: AAD `(vault_id, item_id)` must reject it.
        open.connection
            .execute(
                "UPDATE vault_items SET payload=?1 WHERE id='item-a'",
                [payload_b],
            )
            .unwrap();
        let err = get_item(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            "item-a",
        )
        .unwrap_err();
        assert!(matches!(err, VaultError::Authentication));
    }

    #[test]
    fn legacy_vault_without_table_returns_none_and_backfills_on_save() {
        let (_dir, mut vault) = test_vault();
        save_item(&mut vault, "item-a", "Alpha");
        // Simulate a legacy vault where `vault_items` did not exist yet.
        vault
            .open()
            .unwrap()
            .connection
            .execute_batch("DROP TABLE vault_items;")
            .unwrap();
        {
            let open = vault.open().unwrap();
            assert!(!enabled(&open.connection).unwrap());
            assert!(get_item(
                &open.connection,
                &open.root,
                &open.header.vault_id,
                "item-a"
            )
            .unwrap()
            .is_none());
        }
        // Next save recreates and backfills all existing items.
        save_item(&mut vault, "item-b", "Beta");
        let open = vault.open().unwrap();
        assert!(enabled(&open.connection).unwrap());
        assert_eq!(
            get_item(
                &open.connection,
                &open.root,
                &open.header.vault_id,
                "item-a"
            )
            .unwrap()
            .unwrap()["title"],
            "Alpha"
        );
        assert_eq!(
            get_item(
                &open.connection,
                &open.root,
                &open.header.vault_id,
                "item-b"
            )
            .unwrap()
            .unwrap()["title"],
            "Beta"
        );
    }
}
