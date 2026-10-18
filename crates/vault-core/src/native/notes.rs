//! Native rich-note storage. No editor or attachment plaintext is written outside SQLCipher.
use super::*;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

const FILE_LIMIT: usize = 25 * 1024 * 1024;
const NOTE_LIMIT: usize = 250 * 1024 * 1024;
pub(super) const ARCHIVE_LIMIT: usize = 1024 * 1024 * 1024;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct AttachmentMeta {
    pub(super) id: String,
    pub(super) note_id: String,
    pub(super) name: String,
    pub(super) mime: String,
    pub(super) size: usize,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Archive {
    format: String,
    version: u32,
    header: Header,
    manifest: Sealed,
    files: HashMap<String, Sealed>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    document: Document,
    attachments: Vec<AttachmentMeta>,
}
fn aad(vault: &str, meta: &AttachmentMeta) -> Result<Vec<u8>> {
    serde_json::to_vec(&(vault, meta)).map_err(|_| VaultError::InvalidData)
}
pub(super) fn table(conn: &Connection) -> Result<()> {
    storage(conn.execute_batch("CREATE TABLE IF NOT EXISTS note_attachments(id TEXT PRIMARY KEY, note_id TEXT NOT NULL, metadata TEXT NOT NULL, payload BLOB NOT NULL)"))
}
pub(super) fn metas(conn: &Connection) -> Result<Vec<AttachmentMeta>> {
    table(conn)?;
    let mut query = storage(conn.prepare("SELECT metadata FROM note_attachments ORDER BY id"))?;
    let rows = storage(query.query_map([], |row| row.get::<_, String>(0)))?;
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
pub(super) fn refs(node: &Value, out: &mut HashSet<String>, depth: usize) -> Result<()> {
    if depth > 100 {
        return Err(VaultError::InvalidData);
    }
    if ["vaultImage", "vaultAttachment"].contains(&node["type"].as_str().unwrap_or("")) {
        out.insert(
            node["attrs"]["attachmentId"]
                .as_str()
                .filter(|s| !s.is_empty())
                .ok_or(VaultError::InvalidData)?
                .into(),
        );
    }
    if let Some(children) = node["content"].as_array() {
        for child in children {
            refs(child, out, depth + 1)?;
        }
    }
    Ok(())
}
pub(super) fn validate(doc: &Document, files: &[AttachmentMeta]) -> Result<()> {
    let mut ids = HashSet::new();
    let mut totals = HashMap::<&str, usize>::new();
    for meta in files {
        if meta.size > FILE_LIMIT
            || !ids.insert(&meta.id)
            || meta.name.len() > 1024
            || meta.mime.len() > 128
            || !doc
                .items
                .iter()
                .any(|n| n["id"] == meta.note_id && n["type"] == "secureNote")
        {
            return Err(VaultError::InvalidData);
        }
        let total = totals.entry(&meta.note_id).or_default();
        *total += meta.size;
        if *total > NOTE_LIMIT {
            return Err(VaultError::InvalidData);
        }
    }
    for item in &doc.items {
        if item["noteFormat"] != "rich-v1" {
            continue;
        }
        if item["noteDocument"]["type"] != "doc" {
            return Err(VaultError::InvalidData);
        }
        let mut used = HashSet::new();
        refs(&item["noteDocument"], &mut used, 0)?;
        for id in used {
            if !files.iter().any(|m| m.id == id && item["id"] == m.note_id) {
                return Err(VaultError::InvalidData);
            }
        }
    }
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
        if relay::enabled(&open.connection)? {
            return Ok(json!({"ok":true}));
        }
        let mut used = HashSet::new();
        for item in &open.document.items {
            refs(&item["noteDocument"], &mut used, 0)?;
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
        if !relay::enabled(&tx)? {
            storage(tx.execute("DELETE FROM note_attachments WHERE note_id=?1", [id]))?;
        }
        save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
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
            storage(File::open(&self.directory).and_then(|f| f.sync_all()))?;
        }

        Ok(())
    }
    pub(super) fn validate_note_save(&mut self, request: &Value) -> Result<()> {
        let open = self.open()?;
        guard_legacy_write(&open.document, request)?;
        if request["item"]["noteFormat"] == "rich-v1" {
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
            let mut next = open.document.clone();
            next.upsert(request["item"].clone())?;
            validate(&next, &metas(&open.connection)?)?;
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
            .find(|n| n["id"] == note_id && n["type"] == "secureNote" && n["isDeleted"] != true)
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
        write(&tx, &open.root, &open.header.vault_id, &meta, bytes)?;
        save_document_row(&tx, &open.root, &open.header.vault_id, &next)?;
        storage(tx.commit())?;
        open.document = next;
        serde_json::to_string(&meta).map_err(|_| VaultError::InvalidData)
    }
    fn read_attachment(&mut self, note_id: &str, id: &str) -> Result<Vec<u8>> {
        let open = self.open()?;
        if !open
            .document
            .items
            .iter()
            .any(|n| n["id"] == note_id && n["type"] == "secureNote")
        {
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
        refs(&note["noteDocument"], &mut used, 0)?;
        if used.contains(id) {
            return Err(VaultError::InvalidData);
        }
        storage(open.connection.execute(
            "DELETE FROM note_attachments WHERE id=?1 AND note_id=?2",
            rusqlite::params![id, note_id],
        ))?;
        Ok(())
    }
    pub(super) fn archive(&mut self, password: &str) -> Result<String> {
        if password.chars().count() < 10 {
            return Err(VaultError::InvalidData);
        }
        let open = self.open()?;
        let attachments = metas(&open.connection)?;
        validate(&open.document, &attachments)?;
        let root = Zeroizing::new(random_bytes::<32>());
        let header = Header::create(password, &root, new_id())?;
        let mut files = HashMap::new();
        let mut size = 0;
        for meta in &attachments {
            let bytes = read(&open.connection, &open.root, &open.header.vault_id, meta)?;
            let sealed = seal(
                &subkey(&root, b"note-attachments-v1"),
                &bytes,
                &aad(&header.vault_id, meta)?,
            )?;
            size += sealed.ciphertext.len();
            if size > ARCHIVE_LIMIT / 2 {
                return Err(VaultError::InvalidData);
            }
            files.insert(meta.id.clone(), sealed);
        }
        let bytes = Zeroizing::new(
            serde_json::to_vec(&Manifest {
                document: open.document.clone(),
                attachments,
            })
            .map_err(|_| VaultError::InvalidData)?,
        );
        let manifest = seal(
            &subkey(&root, b"archive-manifest-v3"),
            &bytes,
            header.vault_id.as_bytes(),
        )?;
        serde_json::to_string(&Archive {
            format: "PasswordVaultArchive".into(),
            version: 3,
            header,
            manifest,
            files,
        })
        .map_err(|_| VaultError::InvalidData)
    }
    pub(super) fn import_archive(
        &mut self,
        input: &str,
        password: &str,
        create_password: Option<&str>,
    ) -> Result<Value> {
        if input.len() > ARCHIVE_LIMIT {
            return Err(VaultError::InvalidData);
        }
        let archive: Archive = serde_json::from_str(input).map_err(|_| VaultError::InvalidData)?;
        if archive.format != "PasswordVaultArchive" || archive.version != 3 {
            return Err(VaultError::Unsupported);
        }
        let root = archive.header.unlock(password)?;
        let clear = unseal(
            &subkey(&root, b"archive-manifest-v3"),
            &archive.manifest,
            archive.header.vault_id.as_bytes(),
        )?;
        let mut manifest: Manifest =
            serde_json::from_slice(&clear).map_err(|_| VaultError::InvalidData)?;
        manifest.document = Document::parse(
            &serde_json::to_vec(&manifest.document).map_err(|_| VaultError::InvalidData)?,
        )?;
        validate(&manifest.document, &manifest.attachments)?;
        if manifest.attachments.len() != archive.files.len() {
            return Err(VaultError::InvalidData);
        }
        // Authenticate every file before any vault mutation. Plaintext exists only in memory.
        for meta in &manifest.attachments {
            let data = unseal(
                &subkey(&root, b"note-attachments-v1"),
                archive.files.get(&meta.id).ok_or(VaultError::InvalidData)?,
                &aad(&archive.header.vault_id, meta)?,
            )?;
            if data.len() != meta.size {
                return Err(VaultError::InvalidData);
            }
        }
        let creating = create_password.is_some();
        if let Some(password) = create_password {
            self.create_document(password, Document::default())?;
        }
        let result = (|| {
            self.prepare_rich()?;
            let open = self.open()?;
            let mut next = open.document.clone();
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
            validate(&next, &combined)?;
            let tx = storage(open.connection.transaction())?;
            for meta in &manifest.attachments {
                let data = unseal(
                    &subkey(&root, b"note-attachments-v1"),
                    &archive.files[&meta.id],
                    &aad(&archive.header.vault_id, meta)?,
                )?;
                write(&tx, &open.root, &open.header.vault_id, meta, &data)?;
            }
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
