use super::*;
use crate::archive::{self, AttachmentMeta, HistoryRevision};
use std::collections::HashSet;

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct BrowserExtras {
    pub enabled: bool,
    pub history: Vec<HistoryRevision>,
    pub attachments: Vec<AttachmentMeta>,
    #[serde(default)]
    pub peers: super::peer::BrowserPeerState,
    #[serde(default)]
    pub draft: Option<Value>,
}

pub(super) fn decode_extras(
    root: &[u8; 32],
    sealed: Option<&Sealed>,
    vault: &str,
) -> Result<BrowserExtras> {
    match sealed {
        Some(sealed) => serde_json::from_slice(&unseal(
            &subkey(root, b"browser-extras-v1"),
            sealed,
            vault.as_bytes(),
        )?)
        .map_err(|_| VaultError::InvalidData),
        None => Ok(BrowserExtras::default()),
    }
}

fn now() -> u64 {
    web_time::SystemTime::now()
        .duration_since(web_time::UNIX_EPOCH)
        .map(|v| v.as_millis() as u64)
        .unwrap_or(0)
}

impl BrowserVault {
    fn document_with_history(&self) -> Document {
        let mut all = self.document.clone();
        all.items.extend(
            self.extras
                .history
                .iter()
                .filter(|r| !r.item.is_null())
                .map(|r| r.item.clone()),
        );
        all.items.extend(self.peer_retained_items());
        if let Some(draft) = &self.extras.draft {
            all.items.push(draft.clone());
        }
        all
    }
    pub(super) fn validate_extras(&self) -> Result<()> {
        if (self.document.format_version == 5
            || self.document.settings["entryHistoryEnabled"] == true)
            && !self.extras.enabled
        {
            return Err(VaultError::InvalidData);
        }
        if !self.extras.enabled && !self.extras.history.is_empty() {
            return Err(VaultError::InvalidData);
        }
        archive::validate_history(&self.extras.history)?;
        archive::validate_attachments(&self.document_with_history(), &self.extras.attachments)?;
        if self.extras.attachments.len() != self.files.len()
            || self
                .extras
                .attachments
                .iter()
                .any(|meta| !self.files.contains_key(&meta.id))
        {
            return Err(VaultError::InvalidData);
        }
        if self
            .extras
            .attachments
            .iter()
            .map(|m| m.size)
            .sum::<usize>()
            > 32 * 1024 * 1024
        {
            return Err(VaultError::Unsupported);
        }
        Ok(())
    }
    pub(super) fn read_file(&self, meta: &AttachmentMeta) -> Result<Zeroizing<Vec<u8>>> {
        let data = unseal(
            &subkey(&self.root, b"note-attachments-v1"),
            self.files.get(&meta.id).ok_or(VaultError::InvalidData)?,
            &archive::attachment_aad(&self.header.vault_id, meta)?,
        )?;
        if data.len() != meta.size {
            return Err(VaultError::InvalidData);
        }
        Ok(data)
    }
    pub(super) fn capture_history(&mut self, before: &Document) -> Result<()> {
        if !self.extras.enabled
            || self.document.settings["activePeerLibrary"]
                .as_str()
                .is_some_and(|s| !s.is_empty())
            || before.settings["activePeerLibrary"] != self.document.settings["activePeerLibrary"]
        {
            return Ok(());
        }
        self.document.format_version = self.document.format_version.max(5);
        self.document.settings["entryHistoryEnabled"] = json!(true);
        for current in &self.document.items {
            let id = current["id"].as_str().ok_or(VaultError::InvalidData)?;
            if !self.extras.history.iter().any(|r| r.item_id == id) {
                if let Some(old) = before.items.iter().find(|i| i["id"] == id) {
                    self.extras.history.push(HistoryRevision {
                        id: new_id(),
                        item_id: id.into(),
                        captured_at: now(),
                        item: old.clone(),
                    });
                }
            }
            if !self
                .extras
                .history
                .iter()
                .rev()
                .find(|r| r.item_id == id)
                .is_some_and(|r| r.item == *current)
            {
                self.extras.history.push(HistoryRevision {
                    id: new_id(),
                    item_id: id.into(),
                    captured_at: now(),
                    item: current.clone(),
                });
            }
        }
        Ok(())
    }
    pub(super) fn full_archive(&self, password: &str) -> Result<String> {
        archive::encode_archive(
            &self.peer_backup_document()?,
            self.extras.attachments.clone(),
            self.extras.history.clone(),
            self.extras.enabled,
            password,
            |meta| self.read_file(meta),
        )
    }
    pub(super) fn import_full_archive(&mut self, input: &str, password: &str) -> Result<usize> {
        let decoded = archive::decode_archive(input, password)?;
        if self.document.settings["activePeerLibrary"]
            .as_str()
            .is_some_and(|s| !s.is_empty())
        {
            return Err(VaultError::Unsupported);
        }
        self.peer_restore_snapshots(&decoded.manifest.document.settings["peerLibrarySnapshots"])?;
        let mut next = self.document.clone();
        let count = next.merge(decoded.manifest.document)?;
        for revision in decoded.manifest.history {
            if let Some(old) = self.extras.history.iter().find(|r| r.id == revision.id) {
                if serde_json::to_value(old).ok() != serde_json::to_value(&revision).ok() {
                    return Err(VaultError::InvalidData);
                }
            } else {
                self.extras.history.push(revision);
            }
        }
        self.extras.enabled |= decoded.archive.version == 4;
        if self.extras.enabled {
            next.settings["entryHistoryEnabled"] = json!(true);
        }
        for meta in decoded.manifest.attachments {
            let bytes = unseal(
                &subkey(&decoded.root, b"note-attachments-v1"),
                decoded
                    .archive
                    .files
                    .get(&meta.id)
                    .ok_or(VaultError::InvalidData)?,
                &archive::attachment_aad(&decoded.archive.header.vault_id, &meta)?,
            )?;
            self.peer_register_local_attachment(&meta.id)?;
            if let Some(old) = self.extras.attachments.iter().find(|m| m.id == meta.id) {
                if serde_json::to_value(old).ok() != serde_json::to_value(&meta).ok()
                    || self.read_file(old)?.as_slice() != bytes.as_slice()
                {
                    return Err(VaultError::InvalidData);
                }
            } else {
                let sealed = seal(
                    &subkey(&self.root, b"note-attachments-v1"),
                    &bytes,
                    &archive::attachment_aad(&self.header.vault_id, &meta)?,
                )?;
                Arc::make_mut(&mut self.files).insert(meta.id.clone(), sealed);
                self.extras.attachments.push(meta);
            }
        }
        self.document = next;
        self.validate_extras()?;
        Ok(count)
    }
    pub(super) fn forget_entry_extras(&mut self, id: &str) {
        if !self.extras.peers.libraries.is_empty() {
            return;
        }
        self.extras.history.retain(|r| r.item_id != id);
        let removed: Vec<_> = self
            .extras
            .attachments
            .iter()
            .filter(|m| m.note_id == id)
            .map(|m| m.id.clone())
            .collect();
        for id in removed {
            Arc::make_mut(&mut self.files).remove(&id);
        }
        self.extras.attachments.retain(|m| m.note_id != id);
    }
    fn collect_files(&mut self) -> Result<()> {
        let mut used = HashSet::new();
        for item in self.document_with_history().items {
            crate::archive::item_attachment_refs(&item, &mut used)?;
        }
        let removed: Vec<_> = self
            .extras
            .attachments
            .iter()
            .filter(|meta| !used.contains(&meta.id))
            .map(|meta| meta.id.clone())
            .collect();
        for id in removed {
            self.peer_forget_local_attachment(&id);
        }
        self.extras.attachments.retain(|m| used.contains(&m.id));
        Arc::make_mut(&mut self.files).retain(|id, _| used.contains(id));
        Ok(())
    }
    pub(super) fn extra_command(&mut self, request: &Value) -> Result<Value> {
        let text = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        match text("op")? {
            "history-status" => Ok(json!({"enabled":self.extras.enabled})),
            "history-enable" => {
                self.extras.enabled = true;
                self.document.format_version = self.document.format_version.max(5);
                self.document.settings["entryHistoryEnabled"] = json!(true);
                Ok(json!({"ok":true}))
            }
            "history-list" => {
                let id = text("id")?;
                let rows: Vec<_> = self
                    .extras
                    .history
                    .iter()
                    .filter(|r| r.item_id == id)
                    .rev()
                    .collect();
                let total = rows.len();
                Ok(
                    json!({"total":total,"revisions":rows.into_iter().skip(request["offset"].as_u64().unwrap_or(0)as usize).take(request["limit"].as_u64().unwrap_or(100).clamp(1,500)as usize).collect::<Vec<_>>()}),
                )
            }
            "history-prune" => {
                let id = text("id")?;
                let item = self
                    .document
                    .items
                    .iter()
                    .find(|i| i["id"] == id)
                    .ok_or(VaultError::InvalidData)?;
                authorize_item_write(&self.document, item)?;
                self.extras.history.retain(|r| r.item_id != id);
                self.capture_history(&self.document.clone())?;
                self.collect_files()?;
                Ok(json!({"ok":true}))
            }
            "history-restore" => {
                let id = text("id")?;
                let revision = text("revisionId")?;
                let time = text("time")?;
                chrono::DateTime::parse_from_rfc3339(time).map_err(|_| VaultError::InvalidData)?;
                let mut item = self
                    .extras
                    .history
                    .iter()
                    .find(|r| r.id == revision && r.item_id == id && !r.item.is_null())
                    .ok_or(VaultError::InvalidData)?
                    .item
                    .clone();
                authorize_item_write(&self.document, &item)?;
                if let Some(current) = self.document.items.iter().find(|i| i["id"] == id) {
                    authorize_item_write(&self.document, current)?;
                    if current["sharedVaultId"] != item["sharedVaultId"] {
                        return Err(VaultError::Authentication);
                    }
                }
                item["updatedAt"] = json!(time);
                self.document.upsert(item)?;
                self.validate_extras()?;
                Ok(json!({"ok":true}))
            }
            "recovery-generate" => Ok(json!({"key":generate_recovery_key()})),
            "recovery-status" => {
                if let Some(envelope) = &self.recovery {
                    envelope.aad()?;
                    if envelope.vault_id != self.header.vault_id {
                        return Err(VaultError::Authentication);
                    }
                }
                Ok(json!({"enabled":self.recovery.is_some()}))
            }
            "recovery-enable" => {
                self.header.unlock(text("currentPassword")?)?;
                self.recovery = Some(RecoveryEnvelope::create(
                    text("key")?,
                    &self.root,
                    self.header.vault_id.clone(),
                )?);
                Ok(json!({"ok":true}))
            }
            "recovery-disable" => {
                self.header.unlock(text("currentPassword")?)?;
                self.recovery = None;
                Ok(json!({"ok":true}))
            }
            "recovery-export" => {
                let key = normalize_recovery_key(text("key")?)?;
                let root = self
                    .recovery
                    .as_ref()
                    .ok_or(VaultError::InvalidData)?
                    .unlock(&key, &self.header.vault_id)?;
                if root.as_ref() != self.root.as_ref() {
                    return Err(VaultError::Authentication);
                }
                Ok(json!({"content":self.full_archive(&key)?}))
            }
            "attachment-add" => {
                let owner = text("noteId")?;
                let item = self
                    .document
                    .items
                    .iter()
                    .find(|i| {
                        i["id"] == owner
                            && matches!(i["type"].as_str(), Some("secureNote" | "device"))
                            && i["isDeleted"] != true
                    })
                    .ok_or(VaultError::InvalidData)?;
                authorize_item_write(&self.document, item)?;
                if item["sharedVaultId"]
                    .as_str()
                    .is_some_and(|s| !s.is_empty())
                {
                    return Err(VaultError::Unsupported);
                }
                let name = text("name")?;
                let mime = text("mime")?;
                let data = Zeroizing::new(
                    STANDARD
                        .decode(text("data")?)
                        .map_err(|_| VaultError::InvalidData)?,
                );
                if name.is_empty()
                    || name.len() > 1024
                    || mime.len() > 128
                    || data.len() > archive::FILE_LIMIT
                    || self
                        .extras
                        .attachments
                        .iter()
                        .map(|m| m.size)
                        .sum::<usize>()
                        + data.len()
                        > 32 * 1024 * 1024
                {
                    return Err(VaultError::InvalidData);
                }
                let meta = AttachmentMeta {
                    id: new_id(),
                    note_id: owner.into(),
                    name: name.into(),
                    mime: mime.into(),
                    size: data.len(),
                };
                let sealed = seal(
                    &subkey(&self.root, b"note-attachments-v1"),
                    &data,
                    &archive::attachment_aad(&self.header.vault_id, &meta)?,
                )?;
                self.peer_register_local_attachment(&meta.id)?;
                Arc::make_mut(&mut self.files).insert(meta.id.clone(), sealed);
                self.extras.attachments.push(meta.clone());
                self.document.format_version = self.document.format_version.max(3);
                Ok(json!(meta))
            }
            "attachment-read" => {
                let meta = self
                    .extras
                    .attachments
                    .iter()
                    .find(|m| {
                        m.id == text("id").unwrap_or("")
                            && m.note_id == text("noteId").unwrap_or("")
                    })
                    .ok_or(VaultError::InvalidData)?;
                Ok(
                    json!({"data":STANDARD.encode(self.read_file(meta)?.as_slice()),"mime":meta.mime,"name":meta.name}),
                )
            }
            "attachment-collect" => {
                self.collect_files()?;
                Ok(json!({"ok":true}))
            }
            _ => Err(VaultError::Unsupported),
        }
    }
}

#[wasm_bindgen(js_name=bootstrapRecover)]
pub fn bootstrap_recover(
    storage: String,
    key: String,
    new_password: String,
) -> std::result::Result<String, JsValue> {
    let key = Zeroizing::new(key);
    let new_password = Zeroizing::new(new_password);
    let bundle = parse_bundle(&storage).map_err(js_error)?;
    let root = bundle
        .recovery
        .as_ref()
        .ok_or_else(|| js_error(VaultError::Authentication))?
        .unlock(&key, &bundle.header.vault_id)
        .map_err(js_error)?;
    let mut engine = BrowserVault::new(storage, root.to_vec())?;
    engine.header =
        Header::create(&new_password, &root, engine.header.vault_id.clone()).map_err(js_error)?;
    Ok(json!({"storage":engine.snapshot()?,"key":STANDARD.encode(root.as_ref())}).to_string())
}

#[wasm_bindgen(js_name=bootstrapRestoreRecovery)]
pub fn bootstrap_restore_recovery(
    content: String,
    key: String,
    new_password: String,
) -> std::result::Result<String, JsValue> {
    let key = normalize_recovery_key(&key).map_err(js_error)?;
    let new_password = Zeroizing::new(new_password);
    let root = Zeroizing::new(random_bytes::<32>());
    let header = Header::create(&new_password, &root, new_id()).map_err(js_error)?;
    let mut engine = BrowserVault {
        header,
        root,
        document: Document::default(),
        extras: BrowserExtras::default(),
        recovery: None,
        files: Arc::new(HashMap::new()),
    };
    engine
        .import_full_archive(&content, &key)
        .map_err(js_error)?;
    Ok(
        json!({"storage":engine.snapshot()?,"key":STANDARD.encode(engine.root.as_ref())})
            .to_string(),
    )
}
