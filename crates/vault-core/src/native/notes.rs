//! Native rich-note storage. Attachment bytes are encrypted in 64 KiB chunks under
//! `<vault_dir>/blobs/<id>.pvblob` with authenticated pointers sealed inside SQLCipher.
use super::*;
use std::collections::HashSet;
use std::io::{Read, Write};

pub(super) use crate::archive::{
    attachment_aad as aad, validate_attachments as validate, AttachmentMeta, ARCHIVE_LIMIT,
    FILE_LIMIT, NOTE_LIMIT,
};
pub(super) fn table(conn: &Connection) -> Result<()> {
    storage(conn.execute_batch("CREATE TABLE IF NOT EXISTS note_attachments(id TEXT PRIMARY KEY, note_id TEXT NOT NULL, metadata TEXT NOT NULL, payload BLOB NOT NULL); CREATE INDEX IF NOT EXISTS note_attachments_owner ON note_attachments(note_id)"))?;
    note_blobs::table(conn)
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
struct HashingWriter<W> {
    inner: W,
    hasher: Sha256,
}
impl<W: Write> Write for HashingWriter<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let n = self.inner.write(buf)?;
        self.hasher.update(&buf[..n]);
        Ok(n)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}
pub(super) fn read_to_writer(
    vault_dir: &Path,
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    meta: &AttachmentMeta,
    writer: impl Write,
) -> Result<(usize, String)> {
    let payload: Vec<u8> = storage(conn.query_row(
        "SELECT payload FROM note_attachments WHERE id=?1",
        [&meta.id],
        |row| row.get(0),
    ))?;
    let mut hashing = HashingWriter {
        inner: writer,
        hasher: Sha256::new(),
    };
    let written =
        if let Some(pointer) = note_blobs::try_decode_pointer(&payload, root, vault, meta)? {
            note_blobs::read_blob_to_writer(vault_dir, root, vault, &pointer, &mut hashing)?
        } else {
            let sealed = serde_json::from_slice(&payload).map_err(|_| VaultError::InvalidData)?;
            let bytes = unseal(
                &subkey(root, b"note-attachments-v1"),
                &sealed,
                &aad(vault, meta)?,
            )?;
            if bytes.len() != meta.size || bytes.len() > FILE_LIMIT {
                return Err(VaultError::InvalidData);
            }
            storage(hashing.write_all(&bytes))?;
            bytes.len()
        };
    storage(hashing.flush())?;
    if written != meta.size || written > FILE_LIMIT {
        return Err(VaultError::InvalidData);
    }
    Ok((written, hex::encode(hashing.hasher.finalize())))
}
pub(super) fn read(
    vault_dir: &Path,
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    meta: &AttachmentMeta,
) -> Result<Zeroizing<Vec<u8>>> {
    let mut out = Zeroizing::new(Vec::with_capacity(meta.size.min(1024 * 1024)));
    read_to_writer(vault_dir, conn, root, vault, meta, &mut *out)?;
    Ok(out)
}
pub(super) fn write_from_reader(
    vault_dir: &Path,
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    meta: &mut AttachmentMeta,
    reader: impl Read,
    max_size: usize,
) -> Result<Option<String>> {
    table(conn)?;
    let written = note_blobs::write_blob_from_reader(
        vault_dir,
        conn,
        root,
        vault,
        reader,
        max_size.min(FILE_LIMIT),
    )?;
    meta.size = written.pointer.size;
    let payload = note_blobs::encode_envelope(root, vault, meta, &written.pointer)?;
    let meta_json = serde_json::to_string(meta).map_err(|_| VaultError::InvalidData)?;
    if let Err(err) = (|| -> Result<()> {
        storage(conn.execute(
            "INSERT INTO note_attachments(id,note_id,metadata,payload) VALUES(?1,?2,?3,?4) ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata,payload=excluded.payload",
            rusqlite::params![meta.id, meta.note_id, meta_json, payload],
        ))?;
        note_blobs::record_ref(conn, &meta.id, &written.pointer)?;
        Ok(())
    })() {
        if written.created_new_file {
            note_blobs::remove_file_if_unused(vault_dir, &written.pointer.blob_id);
        }
        return Err(err);
    }
    Ok(written.created_new_file.then_some(written.pointer.blob_id))
}
pub(super) fn write(
    vault_dir: &Path,
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    meta: &AttachmentMeta,
    bytes: &[u8],
) -> Result<Option<String>> {
    if bytes.len() != meta.size || bytes.len() > FILE_LIMIT {
        return Err(VaultError::InvalidData);
    }
    let mut meta_copy = meta.clone();
    write_from_reader(
        vault_dir,
        conn,
        root,
        vault,
        &mut meta_copy,
        bytes,
        FILE_LIMIT,
    )
}
pub(super) fn list_note_attachments(conn: &Connection, note_id: &str) -> Result<Value> {
    let list = metas_for_note(conn, note_id)?;
    let mut out = Vec::with_capacity(list.len());
    for meta in list {
        let info = note_blobs::info_for_attachment(conn, &meta.id)?;
        let (storage_kind, blob_id, chunks) = match info {
            Some(i) => ("pvblob-v1", Some(i.blob_id), Some(i.chunks)),
            None => ("inline", None, None),
        };
        out.push(json!({
            "id": meta.id,
            "noteId": meta.note_id,
            "name": meta.name,
            "mime": meta.mime,
            "size": meta.size,
            "storage": storage_kind,
            "blobId": blob_id,
            "chunks": chunks,
        }));
    }
    Ok(json!({"attachments": out}))
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
fn open_source_regular_readonly(path: &Path) -> Result<File> {
    if !path.is_absolute() {
        return Err(VaultError::InvalidData);
    }
    let sm = storage(fs::symlink_metadata(path))?;
    if !sm.file_type().is_file() {
        return Err(VaultError::InvalidData);
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(0x0100 | 0x0004); // O_NOFOLLOW | O_NONBLOCK
    }
    let file = storage(options.open(path))?;
    let meta = storage(file.metadata())?;
    if !meta.is_file() {
        return Err(VaultError::InvalidData);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if meta.dev() != sm.dev() || meta.ino() != sm.ino() {
            return Err(VaultError::InvalidData);
        }
    }
    Ok(file)
}

impl DiskVault {
    pub(super) fn collect_note_attachments(&mut self) -> Result<Value> {
        let vault_dir = self.directory.clone();
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
                note_blobs::delete_ref(&tx, &meta.id)?;
            }
        }
        storage(tx.commit())?;
        let _ = note_blobs::prune_unreferenced(&vault_dir, &open.connection);
        Ok(json!({"ok":true}))
    }
    pub(super) fn remove_note_record(&mut self, id: &str) -> Result<Value> {
        let vault_dir = self.directory.clone();
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
        let retains = relay::retains_attachments(&open.connection)?;
        let tx = storage(open.connection.transaction())?;
        if !retains {
            note_blobs::delete_refs_for_note(&tx, id)?;
            storage(tx.execute("DELETE FROM note_attachments WHERE note_id=?1", [id]))?;
        }
        note_bodies::delete_for_note(&tx, id)?;
        save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
        // Permanent deletion retains its existing privacy semantics, including history.
        for revision in history::read(&tx, &open.root, &open.header.vault_id)? {
            if revision.item_id == id {
                storage(tx.execute("DELETE FROM entry_history WHERE id=?1", [&revision.id]))?;
            }
        }
        storage(tx.commit())?;
        if !retains {
            let _ = note_blobs::prune_unreferenced(&vault_dir, &open.connection);
        }
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
            note_blobs::copy_blobs_dir(&self.directory, temp.path())?;
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
    fn import_attachment_reader(
        &mut self,
        note_id: &str,
        name: &str,
        mime: &str,
        reader: impl Read,
        expected_max: usize,
    ) -> Result<String> {
        if expected_max > FILE_LIMIT || name.is_empty() || name.len() > 1024 || mime.len() > 128 {
            return Err(VaultError::InvalidData);
        }
        let vault_dir = self.directory.clone();
        let remaining = {
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
            NOTE_LIMIT
                .checked_sub(total)
                .ok_or(VaultError::InvalidData)?
        };
        let allowed_max = expected_max.min(FILE_LIMIT).min(remaining);
        self.prepare_rich()?;
        let open = self.open()?;
        let mut meta = AttachmentMeta {
            id: new_id(),
            note_id: note_id.into(),
            name: name.into(),
            mime: mime.into(),
            size: 0,
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
        let created_blob = write_from_reader(
            &vault_dir,
            &tx,
            &open.root,
            &open.header.vault_id,
            &mut meta,
            reader,
            allowed_max,
        )?;
        let commit_res = (|| -> Result<()> {
            save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
            storage(tx.commit())
        })();
        if let Err(err) = commit_res {
            if let Some(blob_id) = created_blob {
                note_blobs::remove_file_if_unused(&vault_dir, &blob_id);
            }
            return Err(err);
        }
        open.document = next;
        serde_json::to_string(&meta).map_err(|_| VaultError::InvalidData)
    }
    fn import_attachment(
        &mut self,
        note_id: &str,
        name: &str,
        mime: &str,
        bytes: &[u8],
    ) -> Result<String> {
        if bytes.len() > FILE_LIMIT {
            return Err(VaultError::InvalidData);
        }
        self.import_attachment_reader(note_id, name, mime, bytes, bytes.len())
    }
    fn import_attachment_file(
        &mut self,
        note_id: &str,
        path: &str,
        name: &str,
        mime: &str,
    ) -> Result<String> {
        let file = open_source_regular_readonly(Path::new(path))?;
        let file_len = storage(file.metadata())?.len();
        if file_len > FILE_LIMIT as u64 {
            return Err(VaultError::InvalidData);
        }
        self.import_attachment_reader(
            note_id,
            name,
            mime,
            file.take(FILE_LIMIT as u64 + 1),
            FILE_LIMIT,
        )
    }
    fn read_attachment(&mut self, note_id: &str, id: &str) -> Result<Vec<u8>> {
        let vault_dir = self.directory.clone();
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
        Ok(read(
            &vault_dir,
            &open.connection,
            &open.root,
            &open.header.vault_id,
            &meta,
        )?
        .to_vec())
    }
    fn export_attachment_file(
        &mut self,
        note_id: &str,
        id: &str,
        dest_path: &str,
        readonly: bool,
    ) -> Result<String> {
        let dest = Path::new(dest_path);
        if !dest.is_absolute() {
            return Err(VaultError::InvalidData);
        }
        let parent = dest.parent().ok_or(VaultError::InvalidData)?;
        if !parent.is_dir() {
            return Err(VaultError::Storage);
        }
        let vault_dir = self.directory.clone();
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
        let mut temp = storage(
            tempfile::Builder::new()
                .prefix(".pv-exp-")
                .tempfile_in(parent),
        )?;
        let (written, sha256) = read_to_writer(
            &vault_dir,
            &open.connection,
            &open.root,
            &open.header.vault_id,
            &meta,
            temp.as_file_mut(),
        )?;
        storage(temp.as_file().sync_all())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = if readonly { 0o400 } else { 0o600 };
            storage(fs::set_permissions(
                temp.path(),
                fs::Permissions::from_mode(mode),
            ))?;
        }
        storage(crate::native_file_ops::replace_synced(temp.path(), dest))?;
        serde_json::to_string(&json!({
            "id": meta.id,
            "noteId": meta.note_id,
            "name": meta.name,
            "mime": meta.mime,
            "size": written,
            "sha256": sha256,
        }))
        .map_err(|_| VaultError::InvalidData)
    }
    fn discard_attachment(&mut self, note_id: &str, id: &str) -> Result<()> {
        let vault_dir = self.directory.clone();
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
        note_blobs::delete_ref(&open.connection, id)?;
        storage(open.connection.execute(
            "DELETE FROM note_attachments WHERE id=?1 AND note_id=?2",
            rusqlite::params![id, note_id],
        ))?;
        let _ = note_blobs::prune_unreferenced(&vault_dir, &open.connection);
        Ok(())
    }
    pub(super) fn archive(&mut self, password: &str) -> Result<String> {
        let vault_dir = self.directory.clone();
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
            |meta| {
                read(
                    &vault_dir,
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    meta,
                )
            },
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
        let vault_dir = self.directory.clone();
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
                        || read(
                            &vault_dir,
                            &open.connection,
                            &open.root,
                            &open.header.vault_id,
                            old,
                        )?
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
            let mut created_blobs = Vec::new();
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
                if let Some(bid) = write(
                    &vault_dir,
                    &tx,
                    &open.root,
                    &open.header.vault_id,
                    meta,
                    &data,
                )? {
                    created_blobs.push(bid);
                }
            }
            relay::peer::restore_snapshots(&tx, &open.root, &open.header.vault_id, &snapshots)?;
            save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
            if let Err(err) = storage(tx.commit()) {
                for bid in created_blobs {
                    note_blobs::remove_file_if_unused(&vault_dir, &bid);
                }
                return Err(err);
            }
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

impl VaultSession {
    pub fn import_note_attachment_file(
        &self,
        note_id: String,
        path: String,
        name: String,
        mime: String,
    ) -> Result<String> {
        self.inner
            .lock()
            .map_err(|_| VaultError::Storage)?
            .import_attachment_file(&note_id, &path, &name, &mime)
    }
    pub fn export_note_attachment_file(
        &self,
        note_id: String,
        id: String,
        dest_path: String,
        readonly: bool,
    ) -> Result<String> {
        self.inner
            .lock()
            .map_err(|_| VaultError::Storage)?
            .export_attachment_file(&note_id, &id, &dest_path, readonly)
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
