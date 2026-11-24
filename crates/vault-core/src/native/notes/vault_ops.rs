use super::*;

impl DiskVault {
    pub(in crate::native) fn collect_note_attachments(&mut self) -> Result<Value> {
        let vault_dir = self.directory.clone();
        let open = self.open()?;
        if relay::retains_attachments(&open.connection)? {
            return Ok(json!({"ok":true}));
        }
        let mut used = HashSet::new();
        let hydrated = note_bodies::hydrate(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            open.document.clone(),
        )?;
        for item in &hydrated.items {
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
                storage(tx.execute(
                    "DELETE FROM note_attachment_state WHERE attachment_id=?1",
                    [&meta.id],
                ))?;
                note_blobs::delete_ref(&tx, &meta.id)?;
            }
        }
        storage(tx.commit())?;
        let _ = note_blobs::prune_unreferenced(&vault_dir, &open.connection);
        Ok(json!({"ok":true}))
    }
    pub(in crate::native) fn remove_note_record(&mut self, id: &str) -> Result<Value> {
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
            storage(tx.execute(
                "DELETE FROM note_attachment_state WHERE attachment_id IN (SELECT id FROM note_attachments WHERE note_id=?1)",
                [id],
            ))?;
            storage(tx.execute("DELETE FROM note_attachments WHERE note_id=?1", [id]))?;
        }
        note_bodies::delete_for_note(&tx, id)?;
        let saved = save_document_row_with_prev(
            &tx,
            &open.root,
            &open.header.vault_id,
            Some(&open.document),
            &next,
            None,
        )?;
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
        open.document = saved;
        open.clear_hydrated_cache();
        Ok(json!({"ok":true}))
    }
    pub(in crate::native) fn prepare_rich(&mut self) -> Result<()> {
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
    pub(in crate::native) fn validate_note_save(&mut self, request: &Value) -> Result<()> {
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
        let created_blob = write_from_reader(
            &vault_dir,
            &tx,
            &open.root,
            &open.header.vault_id,
            &mut meta,
            reader,
            allowed_max,
        )?;
        let commit_res = (|| -> Result<Document> {
            let saved = save_document_row_with_prev(
                &tx,
                &open.root,
                &open.header.vault_id,
                Some(&open.document),
                &next,
                None,
            )?;
            storage(tx.commit())?;
            Ok(saved)
        })();
        let saved = match commit_res {
            Ok(saved) => saved,
            Err(err) => {
                if let Some(blob_id) = created_blob {
                    note_blobs::remove_file_if_unused(&vault_dir, &blob_id);
                }
                return Err(err);
            }
        };
        open.document = saved;
        open.clear_hydrated_cache();
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
        let mut note = open
            .document
            .items
            .iter()
            .find(|n| n["id"] == note_id && n["isDeleted"] != true)
            .cloned()
            .ok_or(VaultError::InvalidData)?;
        note_bodies::hydrate_item(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            &mut note,
        )?;
        authorize_item_write(&open.document, &note)?;
        let mut used = HashSet::new();
        crate::archive::item_attachment_refs(&note, &mut used)?;
        for revision in history::read(&open.connection, &open.root, &open.header.vault_id)? {
            crate::archive::item_attachment_refs(&revision.item, &mut used)?;
        }
        let hydrated = note_bodies::hydrate(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            open.document.clone(),
        )?;
        for item in hydrated.items {
            crate::archive::item_attachment_refs(&item, &mut used)?;
        }
        if used.contains(id) {
            return Err(VaultError::InvalidData);
        }
        note_blobs::delete_ref(&open.connection, id)?;
        storage(open.connection.execute(
            "DELETE FROM note_attachment_state WHERE attachment_id=?1",
            [id],
        ))?;
        storage(open.connection.execute(
            "DELETE FROM note_attachments WHERE id=?1 AND note_id=?2",
            rusqlite::params![id, note_id],
        ))?;
        let _ = note_blobs::prune_unreferenced(&vault_dir, &open.connection);
        Ok(())
    }
    pub(in crate::native) fn archive(&mut self, password: &str) -> Result<String> {
        let vault_dir = self.directory.clone();
        let open = self.open()?;
        let attachments = metas(&open.connection)?;
        let history = history::read(&open.connection, &open.root, &open.header.vault_id)?;
        let hydrated = note_bodies::hydrate(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            open.document.clone(),
        )?;
        let mut document = hydrated;
        if let Some(settings) = document.settings.as_object_mut() {
            settings.remove("activePeerLibrary");
        }
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
    pub(in crate::native) fn import_archive(
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
            let mut next = note_bodies::hydrate(
                &open.connection,
                &open.root,
                &open.header.vault_id,
                open.document.clone(),
            )?;
            if creating {
                next.format_version = manifest.document.format_version;
            }
            let snapshots = manifest.document.settings["peerLibrarySnapshots"].clone();
            let count = next.merge(manifest.document)?;
            let existing = metas(&open.connection)?;
            // IDs are immutable. A conflicting blob must never replace a local attachment;
            // an un-fetched remote stub may be upgraded if its metadata matches.
            for meta in &manifest.attachments {
                if let Some(old) = existing.iter().find(|old| old.id == meta.id) {
                    let bytes = unseal(
                        &subkey(&root, b"note-attachments-v1"),
                        &archive.files[&meta.id],
                        &aad(&archive.header.vault_id, meta)?,
                    )?;
                    if serde_json::to_vec(old).ok() != serde_json::to_vec(meta).ok() {
                        return Err(VaultError::InvalidData);
                    }
                    if !is_remote(&open.connection, &old.id)?
                        && read(
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
            let mut validation = history::with_history(&next, &combined_history);
            // Backups from builds with peer libraries may still carry their snapshots; their
            // attachments stay valid references even though the libraries are not restored.
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
            let saved = save_document_row_with_prev(
                &tx,
                &open.root,
                &open.header.vault_id,
                Some(&open.document),
                &next,
                None,
            )?;
            if let Err(err) = storage(tx.commit()) {
                for bid in created_blobs {
                    note_blobs::remove_file_if_unused(&vault_dir, &bid);
                }
                return Err(err);
            }
            open.document = saved;
            open.clear_hydrated_cache();
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
