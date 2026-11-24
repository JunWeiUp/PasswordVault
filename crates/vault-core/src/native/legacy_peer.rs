//! Peer ("family") libraries were removed. A vault left switched into one returns to its
//! personal records once, on unlock. The old `peer_libraries` and `peer_personal_snapshot`
//! tables stay on disk untouched; nothing reads them any more.
use super::*;
use rusqlite::OptionalExtension;

type Records = std::collections::BTreeMap<String, Value>;

const SETTINGS: [&str; 4] = [
    "activePeerLibrary",
    "_peerLibraryRole",
    "_peerLibraryReadOnly",
    "_peerLibraryName",
];

fn snapshot(conn: &Connection, root: &[u8; 32], vault: &str) -> Result<Option<Records>> {
    let present: i64 = storage(conn.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='peer_personal_snapshot'",
        [],
        |r| r.get(0),
    ))?;
    if present == 0 {
        return Ok(None);
    }
    let bytes: Option<Vec<u8>> = storage(
        conn.query_row(
            "SELECT payload FROM peer_personal_snapshot WHERE id=1",
            [],
            |r| r.get(0),
        )
        .optional(),
    )?;
    let Some(bytes) = bytes else {
        return Ok(None);
    };
    let sealed: Sealed = serde_json::from_slice(&bytes).map_err(|_| VaultError::InvalidData)?;
    let plain = unseal(
        &subkey(root, b"peer-personal-snapshot-v2"),
        &sealed,
        vault.as_bytes(),
    )?;
    serde_json::from_slice(&plain)
        .map(Some)
        .map_err(|_| VaultError::InvalidData)
}

/// Restores the personal records if `document` is still switched into a peer library.
pub(super) fn leave(
    connection: &mut Connection,
    root: &[u8; 32],
    vault: &str,
    document: Document,
) -> Result<()> {
    let active = document.settings["activePeerLibrary"]
        .as_str()
        .is_some_and(|s| !s.is_empty());
    if !active {
        return Ok(());
    }
    let mut next = document;
    // Without a saved personal snapshot the library's records are all that is left: keep them
    // as personal records rather than hide them.
    if let Some(records) = snapshot(connection, root, vault)? {
        relay::install(&mut next, &records)?;
    }
    next.format_version = next.format_version.max(6);
    if let Some(settings) = next.settings.as_object_mut() {
        for key in SETTINGS {
            settings.remove(key);
        }
    }
    let plain = Zeroizing::new(serde_json::to_vec(&next).map_err(|_| VaultError::InvalidData)?);
    let sealed = seal(&subkey(root, b"document"), &plain, vault.as_bytes())?;
    let tx = storage(connection.transaction())?;
    storage(tx.execute(
        "UPDATE vault_state SET payload=?1 WHERE id=1",
        [serde_json::to_vec(&sealed).map_err(|_| VaultError::InvalidData)?],
    ))?;
    queries::rebuild(&tx, root, vault, &next)?;
    storage(tx.commit())?;
    Ok(())
}

/// Whether this vault may still be switched into a peer library (cheap; no decryption).
/// Switching into a library always saved the personal snapshot first, so vaults that never
/// switched skip the check and keep their lazy unlock.
pub(super) fn possible(conn: &Connection) -> Result<bool> {
    let present: i64 = storage(conn.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='peer_personal_snapshot'",
        [],
        |r| r.get(0),
    ))?;
    Ok(present > 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_view(open: &OpenVault, doc: &Document) {
        let plain = serde_json::to_vec(doc).unwrap();
        let sealed = seal(
            &subkey(&open.root, b"document"),
            &plain,
            open.header.vault_id.as_bytes(),
        )
        .unwrap();
        open.connection
            .execute(
                "UPDATE vault_state SET payload=?1 WHERE id=1",
                [serde_json::to_vec(&sealed).unwrap()],
            )
            .unwrap();
    }

    fn ids(vault: &mut DiskVault) -> Vec<String> {
        let doc = vault.open().unwrap().document.clone();
        doc.items
            .iter()
            .map(|i| i["id"].as_str().unwrap().to_owned())
            .collect()
    }

    /// A vault left switched into a family library returns to its personal records on unlock;
    /// the library view and its settings are gone, and later unlocks change nothing.
    #[test]
    fn unlock_leaves_a_peer_library_and_restores_personal_records() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = DiskVault::new(dir.path()).unwrap();
        vault.create("fixture").unwrap();
        vault
            .command(
                &json!({"op":"save","item":{"id":"mine","type":"password","title":"Personal"}}),
            )
            .unwrap();
        {
            let open = vault.open().unwrap();
            let personal = Records::from([
                ("item:mine".to_owned(), open.document.items[0].clone()),
                ("categories".to_owned(), json!([])),
            ]);
            open.connection
                .execute_batch("CREATE TABLE peer_personal_snapshot(id INTEGER PRIMARY KEY CHECK(id=1),payload BLOB NOT NULL)")
                .unwrap();
            let sealed = seal(
                &subkey(&open.root, b"peer-personal-snapshot-v2"),
                &serde_json::to_vec(&personal).unwrap(),
                open.header.vault_id.as_bytes(),
            )
            .unwrap();
            open.connection
                .execute(
                    "INSERT INTO peer_personal_snapshot(id,payload) VALUES(1,?1)",
                    [serde_json::to_vec(&sealed).unwrap()],
                )
                .unwrap();
            let mut library = open.document.clone();
            library.items = vec![json!({"id":"family","type":"password","title":"Family"})];
            library.settings["activePeerLibrary"] = json!("lib-1");
            library.settings["_peerLibraryName"] = json!("Family");
            write_view(open, &library);
        }
        vault.lock();
        vault.unlock("fixture").unwrap();
        assert_eq!(ids(&mut vault), ["mine"]);
        let settings = vault.open().unwrap().document.settings.clone();
        assert!(settings.get("activePeerLibrary").is_none());
        assert!(settings.get("_peerLibraryName").is_none());

        vault.lock();
        vault.unlock("fixture").unwrap();
        assert_eq!(ids(&mut vault), ["mine"]);
    }

    /// Vaults that never switched into a library are not touched.
    #[test]
    fn vaults_outside_a_library_are_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = DiskVault::new(dir.path()).unwrap();
        vault.create("fixture").unwrap();
        vault
            .command(
                &json!({"op":"save","item":{"id":"mine","type":"password","title":"Personal"}}),
            )
            .unwrap();
        vault
            .open()
            .unwrap()
            .connection
            .execute_batch("CREATE TABLE peer_personal_snapshot(id INTEGER PRIMARY KEY CHECK(id=1),payload BLOB NOT NULL)")
            .unwrap();
        vault.lock();
        vault.unlock("fixture").unwrap();
        assert_eq!(ids(&mut vault), ["mine"]);
    }
}
