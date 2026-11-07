//! Native rich-note storage. No editor or attachment plaintext is written outside SQLCipher.
use super::*;
use std::collections::HashSet;

pub(super) use crate::archive::{
    attachment_aad as aad, validate_attachments as validate, AttachmentMeta, ARCHIVE_LIMIT,
    FILE_LIMIT, NOTE_LIMIT,
};
pub(super) fn table(conn: &Connection) -> Result<()> {
    storage(conn.execute_batch("CREATE TABLE IF NOT EXISTS note_attachments(id TEXT PRIMARY KEY, note_id TEXT NOT NULL, metadata TEXT NOT NULL, payload BLOB NOT NULL); CREATE INDEX IF NOT EXISTS note_attachments_owner ON note_attachments(note_id)"))
}
pub(super) fn metas(conn: &Connection) -> Result<Vec<AttachmentMeta>> {
    table(conn)?;
    let mut query = storage(conn.prepare("SELECT metadata FROM note_attachments ORDER BY id"))?;
    let rows = storage(query.query_map([], |row| row.get::<_, String>(0)))?;
    rows.map(|row| serde_json::from_str(&storage(row)?).map_err(|_| VaultError::InvalidData))
        .collect()
}
fn metas_for_note(conn: &Connection, note_id: &str) -> Result<Vec<AttachmentMeta>> {
    table(conn)?;
    let mut query = storage(
        conn.prepare("SELECT metadata FROM note_attachments WHERE note_id=?1 ORDER BY id"),
    )?;
    let rows = storage(query.query_map([note_id], |row| row.get::<_, String>(0)))?;
    rows.map(|row| serde_json::from_str(&storage(row)?).map_err(|_| VaultError::InvalidData))
        .collect()
}
pub(super) fn read(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    meta: &AttachmentMeta,
) -> Result<Zeroizing<Vec<u8>>> {
    let bytes: Vec<u8> = storage(conn.query_row(
        "SELECT payload FROM note_attachments WHERE id=?1",
        [&meta.id],
        |row| row.get(0),
    ))?;
    let sealed = serde_json::from_slice(&bytes).map_err(|_| VaultError::InvalidData)?;
    let bytes = unseal(
        &subkey(root, b"note-attachments-v1"),
        &sealed,
        &aad(vault, meta)?,
    )?;
    if bytes.len() != meta.size || bytes.len() > FILE_LIMIT {
        return Err(VaultError::InvalidData);
    }
    Ok(bytes)
}
pub(super) fn write(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    meta: &AttachmentMeta,
    bytes: &[u8],
) -> Result<()> {
    let sealed = seal(
        &subkey(root, b"note-attachments-v1"),
        bytes,
        &aad(vault, meta)?,
    )?;
    storage(conn.execute("INSERT INTO note_attachments(id,note_id,metadata,payload) VALUES(?1,?2,?3,?4) ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata,payload=excluded.payload",
        rusqlite::params![meta.id, meta.note_id, serde_json::to_string(meta).map_err(|_| VaultError::InvalidData)?, serde_json::to_vec(&sealed).map_err(|_| VaultError::InvalidData)?]))?;
    Ok(())
}
pub(super) fn guard_legacy_write(doc: &Document, request: &Value) -> Result<()> {
    if request["richNotes"] == true {
        return Ok(());
    }
    let item = &request["item"];
    if item["noteFormat"] == "rich-v1"
        || doc
            .items
            .iter()
            .any(|old| old["id"] == item["id"] && old["noteFormat"] == "rich-v1")
    {
        return Err(VaultError::Unsupported);
    }
    Ok(())
}
impl DiskVault {
    pub(super) fn collect_note_attachments(&mut self) -> Result<Value> {
        let open = self.open()?;
        if relay::retains_attachments(&open.connection)? {
            return Ok(json!({"ok":true}));
        }
        let mut used = HashSet::new();
        for item in &open.document.items {
            crate::archive::item_attachment_refs(item, &mut used)?;
        }
        for revision in history::read(&open.connection, &open.root, &open.header.vault_id)? {
            crate::archive::item_attachment_refs(&revision.item, &mut used)?;
        }
        let attachments = metas(&open.connection)?;
        let tx = storage(open.connection.transaction())?;
        for meta in attachments {
            if !used.contains(&meta.id) {
                storage(tx.execute("DELETE FROM note_attachments WHERE id=?1", [&meta.id]))?;
            }
        }
        storage(tx.commit())?;
        Ok(json!({"ok":true}))
    }
    pub(super) fn remove_note_record(&mut self, id: &str) -> Result<Value> {
        let open = self.open()?;
        if let Some(note) = open.document.items.iter().find(|n| n["id"] == id) {
            authorize_item_write(&open.document, note)?;
            if note["sharedVaultId"]
                .as_str()
                .is_some_and(|s| !s.is_empty())
            {
                return Err(VaultError::Unsupported);
            }
        }
        let mut next = open.document.clone();
        next.items.retain(|n| n["id"] != id);
        table(&open.connection)?;
        let tx = storage(open.connection.transaction())?;
        if !relay::retains_attachments(&tx)? {
            storage(tx.execute("DELETE FROM note_attachments WHERE note_id=?1", [id]))?;
        }
        save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
        // Permanent deletion retains its existing privacy semantics, including history.
        for revision in history::read(&tx, &open.root, &open.header.vault_id)? {
            if revision.item_id == id {
                storage(tx.execute("DELETE FROM entry_history WHERE id=?1", [&revision.id]))?;
            }
        }
        storage(tx.commit())?;
        open.document = next;
        Ok(json!({"ok":true}))
    }
    pub(super) fn prepare_rich(&mut self) -> Result<()> {
        if self.open()?.document.format_version >= 3 {
            return Ok(());
        }
        // Copy the complete encrypted vault before its first incompatible write.
        let destination = self.directory.join("before-rich-notes");
        if !destination.exists() {
            let temp = storage(
                tempfile::Builder::new()
                    .prefix(".rich-backup-")
                    .tempdir_in(&self.directory),
            )?;
            for file in ["header.json", "vault.sqlite"] {
                let bytes = storage(fs::read(self.directory.join(file)))?;
                atomic_write(&temp.path().join(file), &bytes)?;
            }
            storage(fs::rename(temp.path(), &destination))?;
            storage(crate::native_file_ops::sync_directory(&self.directory))?;
        }

        Ok(())
    }
    pub(super) fn validate_note_save(&mut self, request: &Value) -> Result<()> {
        let open = self.open()?;
        guard_legacy_write(&open.document, request)?;
        if request["item"]["noteFormat"] == "rich-v1" || request["item"]["type"] == "device" {
            authorize_item_write(&open.document, &request["item"])?;
            if let Some(old) = open
                .document
                .items
                .iter()
                .find(|n| n["id"] == request["item"]["id"])
            {
                authorize_item_write(&open.document, old)?;
            }
            if request["item"]["sharedVaultId"]
                .as_str()
                .is_some_and(|s| !s.is_empty())
            {
                return Err(VaultError::Unsupported);
            }
            // Immutable prior revisions were checked when committed/imported. Saving one
            // note must not decrypt unrelated history or every other library's records.
            let mut candidate = Document {
                format_version: open.document.format_version,
                ..Document::default()
            };
            candidate.upsert(request["item"].clone())?;
            let id = request["item"]["id"]
                .as_str()
                .ok_or(VaultError::InvalidData)?;
            validate(&candidate, &metas_for_note(&open.connection, id)?)?;
            self.prepare_rich()?;
        }
        Ok(())
    }
    fn import_attachment(
        &mut self,
        note_id: &str,
        name: &str,
        mime: &str,
        bytes: &[u8],
    ) -> Result<String> {
        if bytes.len() > FILE_LIMIT || name.is_empty() || name.len() > 1024 || mime.len() > 128 {
            return Err(VaultError::InvalidData);
        }
        let open = self.open()?;
        let note = open
            .document
            .items
            .iter()
            .find(|n| {
                n["id"] == note_id
                    && matches!(n["type"].as_str(), Some("secureNote" | "device"))
                    && n["isDeleted"] != true
            })
            .ok_or(VaultError::InvalidData)?;
        authorize_item_write(&open.document, note)?;
        if note["sharedVaultId"]
            .as_str()
            .is_some_and(|s| !s.is_empty())
        {
            return Err(VaultError::Unsupported);
        }
        let total: usize = metas(&open.connection)?
            .iter()
            .filter(|m| m.note_id == note_id)
            .map(|m| m.size)
            .sum();
        if total + bytes.len() > NOTE_LIMIT {
            return Err(VaultError::InvalidData);
        }
        self.prepare_rich()?;
        let open = self.open()?;
        let meta = AttachmentMeta {
            id: new_id(),
            note_id: note_id.into(),
            name: name.into(),
            mime: mime.into(),
            size: bytes.len(),
        };
        let mut next = open.document.clone();
        next.format_version = next.format_version.max(3);
        let tx = storage(open.connection.transaction())?;
        relay::peer::register_local_attachment(
            &tx,
            &open.root,
            &open.header.vault_id,
            &next,
            &meta.id,
        )?;
        write(&tx, &open.root, &open.header.vault_id, &meta, bytes)?;
        save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
        storage(tx.commit())?;
        open.document = next;
        serde_json::to_string(&meta).map_err(|_| VaultError::InvalidData)
    }
    fn read_attachment(&mut self, note_id: &str, id: &str) -> Result<Vec<u8>> {
        let open = self.open()?;
        if !open.document.items.iter().any(|n| {
            n["id"] == note_id && matches!(n["type"].as_str(), Some("secureNote" | "device"))
        }) {
            return Err(VaultError::InvalidData);
        }
        let meta = metas(&open.connection)?
            .into_iter()
            .find(|m| m.id == id && m.note_id == note_id)
            .ok_or(VaultError::InvalidData)?;
        Ok(read(&open.connection, &open.root, &open.header.vault_id, &meta)?.to_vec())
    }
    fn discard_attachment(&mut self, note_id: &str, id: &str) -> Result<()> {
        let open = self.open()?;
        let note = open
            .document
            .items
            .iter()
            .find(|n| n["id"] == note_id && n["isDeleted"] != true)
            .ok_or(VaultError::InvalidData)?;
        authorize_item_write(&open.document, note)?;
        let mut used = HashSet::new();
        crate::archive::item_attachment_refs(note, &mut used)?;
        for revision in history::read(&open.connection, &open.root, &open.header.vault_id)? {
            crate::archive::item_attachment_refs(&revision.item, &mut used)?;
        }
        let retained = relay::peer::with_library_records(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            &open.document,
        )?;
        for item in retained.items {
            crate::archive::item_attachment_refs(&item, &mut used)?;
        }
        if used.contains(id) {
            return Err(VaultError::InvalidData);
        }
        relay::peer::forget_local_attachment(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            &open.document,
            id,
        )?;
        storage(open.connection.execute(
            "DELETE FROM note_attachments WHERE id=?1 AND note_id=?2",
            rusqlite::params![id, note_id],
        ))?;
        Ok(())
    }
    pub(super) fn archive(&mut self, password: &str) -> Result<String> {
        let open = self.open()?;
        let attachments = metas(&open.connection)?;
        let history = history::read(&open.connection, &open.root, &open.header.vault_id)?;
        let document = relay::peer::backup_document(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            &open.document,
        )?;
        crate::archive::encode_archive(
            &document,
            attachments,
            history,
            history::enabled(&open.connection)?,
            password,
            |meta| read(&open.connection, &open.root, &open.header.vault_id, meta),
        )
    }
    pub(super) fn import_archive(
        &mut self,
        input: &str,
        password: &str,
        create_password: Option<&str>,
    ) -> Result<Value> {
        let decoded = crate::archive::decode_archive(input, password)?;
        let archive = decoded.archive;
        let root = decoded.root;
        let manifest = decoded.manifest;
        let creating = create_password.is_some();
        if let Some(password) = create_password {
            self.create_document(password, Document::default())?;
        }
        let result = (|| {
            self.prepare_rich()?;
            let open = self.open()?;
            if open.document.settings["activePeerLibrary"]
                .as_str()
                .is_some_and(|s| !s.is_empty())
            {
                return Err(VaultError::Unsupported);
            }
            let mut next = open.document.clone();
            if creating {
                next.format_version = manifest.document.format_version;
            }
            let snapshots = manifest.document.settings["peerLibrarySnapshots"].clone();
            let count = next.merge(manifest.document)?;
            let existing = metas(&open.connection)?;
            // IDs are immutable. A conflicting blob must never replace a local attachment.
            for meta in &manifest.attachments {
                if let Some(old) = existing.iter().find(|old| old.id == meta.id) {
                    let bytes = unseal(
                        &subkey(&root, b"note-attachments-v1"),
                        &archive.files[&meta.id],
                        &aad(&archive.header.vault_id, meta)?,
                    )?;
                    if serde_json::to_vec(old).ok() != serde_json::to_vec(meta).ok()
                        || read(&open.connection, &open.root, &open.header.vault_id, old)?
                            .as_slice()
                            != bytes.as_slice()
                    {
                        return Err(VaultError::InvalidData);
                    }
                }
            }
            let mut combined = existing.clone();
            combined.extend(
                manifest
                    .attachments
                    .iter()
                    .filter(|m| !existing.iter().any(|old| old.id == m.id))
                    .cloned(),
            );
            let mut combined_history =
                history::read(&open.connection, &open.root, &open.header.vault_id)?;
            combined_history.extend(manifest.history.clone());
            let mut validation = relay::peer::with_library_records(
                &open.connection,
                &open.root,
                &open.header.vault_id,
                &history::with_history(&next, &combined_history),
            )?;
            if !snapshots.is_null() {
                validation.settings["peerLibrarySnapshots"] = snapshots.clone();
            }
            validate(&validation, &combined)?;
            let tx = storage(open.connection.transaction())?;
            if archive.version == 4 {
                next.settings["entryHistoryEnabled"] = json!(true);
                history::table(&tx)?;
                for revision in &manifest.history {
                    history::write(&tx, &open.root, &open.header.vault_id, revision)?;
                }
            }
            for meta in &manifest.attachments {
                let data = unseal(
                    &subkey(&root, b"note-attachments-v1"),
                    &archive.files[&meta.id],
                    &aad(&archive.header.vault_id, meta)?,
                )?;
                relay::peer::register_local_attachment(
                    &tx,
                    &open.root,
                    &open.header.vault_id,
                    &next,
                    &meta.id,
                )?;
                write(&tx, &open.root, &open.header.vault_id, meta, &data)?;
            }
            relay::peer::restore_snapshots(&tx, &open.root, &open.header.vault_id, &snapshots)?;
            save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
            storage(tx.commit())?;
            open.document = next;
            Ok(json!({"imported":count}))
        })();
        if result.is_err() && creating {
            self.lock();
            let _ = fs::remove_dir_all(&self.directory);
        }
        result
    }
}
#[uniffi::export]
impl VaultSession {
    pub fn import_note_attachment(
        &self,
        note_id: String,
        name: String,
        mime: String,
        data: Vec<u8>,
    ) -> Result<String> {
        let data = Zeroizing::new(data);
        self.inner
            .lock()
            .map_err(|_| VaultError::Storage)?
            .import_attachment(&note_id, &name, &mime, &data)
    }
    pub fn read_note_attachment(&self, note_id: String, id: String) -> Result<Vec<u8>> {
        self.inner
            .lock()
            .map_err(|_| VaultError::Storage)?
            .read_attachment(&note_id, &id)
    }
    pub fn discard_note_attachment(&self, note_id: String, id: String) -> Result<()> {
        self.inner
            .lock()
            .map_err(|_| VaultError::Storage)?
            .discard_attachment(&note_id, &id)
    }
}

#[cfg(test)]
mod targeted_validation_tests {
    use super::*;
    #[test]
    fn saving_a_rich_note_does_not_decrypt_unrelated_history() {
        let directory = tempfile::tempdir().unwrap();
        let mut vault = DiskVault::new(directory.path()).unwrap();
        vault.create("synthetic validation fixture").unwrap();
        vault.command(&json!({"op":"save","item":{"id":"unrelated","type":"secureNote","title":"Unrelated","note":"prior"}})).unwrap();
        vault.command(&json!({"op":"history-enable"})).unwrap();
        vault
            .open()
            .unwrap()
            .connection
            .execute(
                "UPDATE entry_history SET payload=?1",
                [b"damaged-unrelated-history".as_slice()],
            )
            .unwrap();
        let item = json!({"id":"new-note","type":"secureNote","title":"Current","note":"body","noteFormat":"rich-v1","noteDocument":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"body"}]}]}});
        vault
            .command(&json!({"op":"save","richNotes":true,"item":item}))
            .unwrap();
        assert!(vault
            .command(&json!({"op":"history-list","id":"unrelated"}))
            .is_err());
        let mut damaged = item;
        damaged["noteDocument"] = json!({"type":"doc","content":[{"type":"vaultImage","attrs":{"attachmentId":"missing-owner-file"}}]});
        assert!(vault
            .command(&json!({"op":"save","richNotes":true,"item":damaged}))
            .is_err());
        let state = vault.command(&json!({"op":"list"})).unwrap();
        assert_eq!(state["items"][1]["note"], "body");
    }
}
