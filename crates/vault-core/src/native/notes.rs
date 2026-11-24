//! Native rich-note storage. Attachment bytes are encrypted in 64 KiB chunks under
//! `<vault_dir>/blobs/<id>.pvblob` with authenticated pointers sealed inside SQLCipher.
use super::*;
use rusqlite::OptionalExtension;
use std::collections::HashSet;
use std::io::{Read, Write};

pub(super) use crate::archive::{
    attachment_aad as aad, validate_attachments as validate, AttachmentMeta, ARCHIVE_LIMIT,
    FILE_LIMIT, NOTE_LIMIT,
};

const REMOTE_SENTINEL: &[u8] = b"PVREMOTE01";
const MAX_CACHE_EXCERPT_BYTES: usize = 64 * 1024;
const MAX_CACHE_THUMB_BYTES: usize = 256 * 1024;

pub(super) fn is_remote_payload(payload: &[u8]) -> bool {
    payload == REMOTE_SENTINEL
}

fn now_unix_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub(super) fn table(conn: &Connection) -> Result<()> {
    storage(conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS note_attachments(id TEXT PRIMARY KEY, note_id TEXT NOT NULL, metadata TEXT NOT NULL, payload BLOB NOT NULL);
         CREATE INDEX IF NOT EXISTS note_attachments_owner ON note_attachments(note_id);
         CREATE TABLE IF NOT EXISTS note_attachment_state(
             attachment_id TEXT PRIMARY KEY,
             state TEXT NOT NULL DEFAULT 'ready',
             source_device TEXT,
             error_reason TEXT,
             excerpt_payload BLOB,
             thumb_payload BLOB,
             thumb_width INTEGER,
             thumb_height INTEGER,
             updated_at INTEGER NOT NULL DEFAULT 0
         );",
    ))?;
    note_blobs::table(conn)
}

fn cache_aad(vault: &str, id: &str, kind: &str) -> Result<Vec<u8>> {
    serde_json::to_vec(&(vault, id, kind)).map_err(|_| VaultError::InvalidData)
}

fn seal_cache(root: &[u8; 32], vault: &str, id: &str, kind: &str, val: &Value) -> Result<Vec<u8>> {
    let bytes = Zeroizing::new(serde_json::to_vec(val).map_err(|_| VaultError::InvalidData)?);
    let max = if kind == "thumb" {
        MAX_CACHE_THUMB_BYTES
    } else {
        MAX_CACHE_EXCERPT_BYTES
    };
    if bytes.len() > max {
        return Err(VaultError::InvalidData);
    }
    let sealed = seal(
        &subkey(root, b"note-attachment-cache-v1"),
        &bytes,
        &cache_aad(vault, id, kind)?,
    )?;
    serde_json::to_vec(&sealed).map_err(|_| VaultError::InvalidData)
}

fn unseal_cache(root: &[u8; 32], vault: &str, id: &str, kind: &str, raw: &[u8]) -> Result<Value> {
    let sealed: Sealed = serde_json::from_slice(raw).map_err(|_| VaultError::InvalidData)?;
    let plain = Zeroizing::new(unseal(
        &subkey(root, b"note-attachment-cache-v1"),
        &sealed,
        &cache_aad(vault, id, kind)?,
    )?);
    serde_json::from_slice(&plain).map_err(|_| VaultError::InvalidData)
}

pub(super) fn count_remote(conn: &Connection) -> Result<usize> {
    table(conn)?;
    let n: i64 = storage(conn.query_row(
        "SELECT count(*) FROM note_attachments WHERE payload=?1",
        [REMOTE_SENTINEL],
        |r| r.get(0),
    ))?;
    Ok(n.max(0) as usize)
}

pub(super) fn is_remote(conn: &Connection, id: &str) -> Result<bool> {
    table(conn)?;
    let payload: Option<Vec<u8>> = storage(
        conn.query_row(
            "SELECT payload FROM note_attachments WHERE id=?1",
            [id],
            |r| r.get(0),
        )
        .optional(),
    )?;
    Ok(payload.as_deref().is_some_and(is_remote_payload))
}

pub(super) fn write_remote_stub(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    meta: &AttachmentMeta,
    source_device: Option<&str>,
    excerpt: Option<&Value>,
    thumb: Option<&Value>,
) -> Result<()> {
    table(conn)?;
    let existing: Option<(String, Vec<u8>)> = storage(
        conn.query_row(
            "SELECT metadata, payload FROM note_attachments WHERE id=?1",
            [&meta.id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional(),
    )?;
    let meta_json = serde_json::to_string(meta).map_err(|_| VaultError::InvalidData)?;
    if let Some((old_meta_json, old_payload)) = existing {
        let old_meta: AttachmentMeta =
            serde_json::from_str(&old_meta_json).map_err(|_| VaultError::InvalidData)?;
        if old_meta.note_id != meta.note_id
            || old_meta.name != meta.name
            || old_meta.mime != meta.mime
            || old_meta.size != meta.size
        {
            return Err(VaultError::InvalidData);
        }
        if !is_remote_payload(&old_payload) {
            // Already materialized locally; optionally fill missing cache without downgrading readiness.
            if excerpt.is_some() || thumb.is_some() {
                let _ = put_cache(conn, root, vault, &meta.note_id, &meta.id, excerpt, thumb);
            }
            return Ok(());
        }
    } else {
        storage(conn.execute(
            "INSERT INTO note_attachments(id,note_id,metadata,payload) VALUES(?1,?2,?3,?4)",
            rusqlite::params![meta.id, meta.note_id, meta_json, REMOTE_SENTINEL],
        ))?;
    }
    let excerpt_blob = excerpt
        .map(|v| seal_cache(root, vault, &meta.id, "excerpt", v))
        .transpose()?;
    let (thumb_blob, tw, th) = if let Some(t) = thumb {
        let blob = seal_cache(root, vault, &meta.id, "thumb", t)?;
        (
            Some(blob),
            t.get("width").and_then(Value::as_i64),
            t.get("height").and_then(Value::as_i64),
        )
    } else {
        (None, None, None)
    };
    storage(conn.execute(
        "INSERT INTO note_attachment_state(attachment_id,state,source_device,error_reason,excerpt_payload,thumb_payload,thumb_width,thumb_height,updated_at)
         VALUES(?1,'remote',?2,NULL,?3,?4,?5,?6,?7)
         ON CONFLICT(attachment_id) DO UPDATE SET
           source_device=COALESCE(excluded.source_device, note_attachment_state.source_device),
           excerpt_payload=COALESCE(excluded.excerpt_payload, note_attachment_state.excerpt_payload),
           thumb_payload=COALESCE(excluded.thumb_payload, note_attachment_state.thumb_payload),
           thumb_width=COALESCE(excluded.thumb_width, note_attachment_state.thumb_width),
           thumb_height=COALESCE(excluded.thumb_height, note_attachment_state.thumb_height),
           updated_at=excluded.updated_at",
        rusqlite::params![
            meta.id,
            source_device,
            excerpt_blob,
            thumb_blob,
            tw,
            th,
            now_unix_ms()
        ],
    ))?;
    Ok(())
}

pub(super) fn put_cache(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    note_id: &str,
    id: &str,
    excerpt: Option<&Value>,
    thumb: Option<&Value>,
) -> Result<()> {
    table(conn)?;
    let owns: bool = storage(conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM note_attachments WHERE id=?1 AND note_id=?2)",
        rusqlite::params![id, note_id],
        |r| r.get(0),
    ))?;
    if !owns {
        return Err(VaultError::InvalidData);
    }
    let default_state = if is_remote(conn, id)? {
        "remote"
    } else {
        "ready"
    };
    let excerpt_blob = excerpt
        .map(|v| seal_cache(root, vault, id, "excerpt", v))
        .transpose()?;
    let (thumb_blob, tw, th) = if let Some(t) = thumb {
        let blob = seal_cache(root, vault, id, "thumb", t)?;
        (
            Some(blob),
            t.get("width").and_then(Value::as_i64),
            t.get("height").and_then(Value::as_i64),
        )
    } else {
        (None, None, None)
    };
    storage(conn.execute(
        "INSERT INTO note_attachment_state(attachment_id,state,excerpt_payload,thumb_payload,thumb_width,thumb_height,updated_at)
         VALUES(?1,?2,?3,?4,?5,?6,?7)
         ON CONFLICT(attachment_id) DO UPDATE SET
           excerpt_payload=COALESCE(excluded.excerpt_payload, note_attachment_state.excerpt_payload),
           thumb_payload=COALESCE(excluded.thumb_payload, note_attachment_state.thumb_payload),
           thumb_width=COALESCE(excluded.thumb_width, note_attachment_state.thumb_width),
           thumb_height=COALESCE(excluded.thumb_height, note_attachment_state.thumb_height),
           updated_at=excluded.updated_at",
        rusqlite::params![id, default_state, excerpt_blob, thumb_blob, tw, th, now_unix_ms()],
    ))?;
    Ok(())
}

pub(super) fn get_cache(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    note_id: &str,
    id: &str,
) -> Result<Value> {
    table(conn)?;
    let owns: bool = storage(conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM note_attachments WHERE id=?1 AND note_id=?2)",
        rusqlite::params![id, note_id],
        |r| r.get(0),
    ))?;
    if !owns {
        return Err(VaultError::InvalidData);
    }
    struct CacheBlobs {
        excerpt: Option<Vec<u8>>,
        thumb: Option<Vec<u8>>,
    }
    let row: Option<CacheBlobs> = storage(
        conn.query_row(
            "SELECT excerpt_payload, thumb_payload FROM note_attachment_state WHERE attachment_id=?1",
            [id],
            |r| {
                Ok(CacheBlobs {
                    excerpt: r.get(0)?,
                    thumb: r.get(1)?,
                })
            },
        )
        .optional(),
    )?;
    let (excerpt, thumb) = match row {
        Some(CacheBlobs {
            excerpt: ex,
            thumb: th,
        }) => (
            ex.as_deref()
                .map(|b| unseal_cache(root, vault, id, "excerpt", b))
                .transpose()?,
            th.as_deref()
                .map(|b| unseal_cache(root, vault, id, "thumb", b))
                .transpose()?,
        ),
        None => (None, None),
    };
    Ok(json!({
        "excerpt": excerpt,
        "thumb": thumb,
    }))
}

pub(super) fn set_state(
    conn: &Connection,
    note_id: &str,
    id: &str,
    state: &str,
    source_device: Option<&str>,
    error_reason: Option<&str>,
) -> Result<()> {
    if !matches!(state, "ready" | "remote" | "downloading" | "failed") {
        return Err(VaultError::InvalidData);
    }
    table(conn)?;
    let payload: Option<Vec<u8>> = storage(
        conn.query_row(
            "SELECT payload FROM note_attachments WHERE id=?1 AND note_id=?2",
            rusqlite::params![id, note_id],
            |r| r.get(0),
        )
        .optional(),
    )?;
    let Some(payload) = payload else {
        return Err(VaultError::InvalidData);
    };
    if state == "ready" && is_remote_payload(&payload) {
        return Err(VaultError::Unsupported);
    }
    storage(conn.execute(
        "INSERT INTO note_attachment_state(attachment_id,state,source_device,error_reason,updated_at)
         VALUES(?1,?2,?3,?4,?5)
         ON CONFLICT(attachment_id) DO UPDATE SET
           state=excluded.state,
           source_device=COALESCE(excluded.source_device, note_attachment_state.source_device),
           error_reason=excluded.error_reason,
           updated_at=excluded.updated_at",
        rusqlite::params![id, state, source_device, error_reason, now_unix_ms()],
    ))?;
    Ok(())
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
    if is_remote_payload(&payload) {
        return Err(VaultError::Unsupported);
    }
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
        storage(conn.execute(
            "INSERT INTO note_attachment_state(attachment_id,state,error_reason,updated_at)
             VALUES(?1,'ready',NULL,?2)
             ON CONFLICT(attachment_id) DO UPDATE SET state='ready', error_reason=NULL, updated_at=excluded.updated_at",
            rusqlite::params![meta.id, now_unix_ms()],
        ))?;
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
        let remote_stub = is_remote(conn, &meta.id)?;
        let (storage_kind, blob_id, chunks) = if remote_stub {
            ("remote", None, None)
        } else {
            match info {
                Some(i) => ("pvblob-v1", Some(i.blob_id), Some(i.chunks)),
                None => ("inline", None, None),
            }
        };
        struct AttachmentStateRow {
            state: String,
            source_device: Option<String>,
            error_reason: Option<String>,
            has_excerpt: bool,
            has_thumb: bool,
            thumb_w: Option<i64>,
            thumb_h: Option<i64>,
        }
        let state_row: Option<AttachmentStateRow> = storage(
            conn.query_row(
                "SELECT state, source_device, error_reason, excerpt_payload IS NOT NULL, thumb_payload IS NOT NULL, thumb_width, thumb_height FROM note_attachment_state WHERE attachment_id=?1",
                [&meta.id],
                |r| {
                    Ok(AttachmentStateRow {
                        state: r.get(0)?,
                        source_device: r.get(1)?,
                        error_reason: r.get(2)?,
                        has_excerpt: r.get(3)?,
                        has_thumb: r.get(4)?,
                        thumb_w: r.get(5)?,
                        thumb_h: r.get(6)?,
                    })
                },
            )
            .optional(),
        )?;
        let (state, source_device, error_reason, has_excerpt, has_thumb, thumb_w, thumb_h) =
            match state_row {
                Some(row) => {
                    let effective = if remote_stub && row.state == "ready" {
                        "remote".to_string()
                    } else {
                        row.state
                    };
                    (
                        effective,
                        row.source_device,
                        row.error_reason,
                        row.has_excerpt,
                        row.has_thumb,
                        row.thumb_w,
                        row.thumb_h,
                    )
                }
                None => (
                    if remote_stub { "remote" } else { "ready" }.to_string(),
                    None,
                    None,
                    false,
                    false,
                    None,
                    None,
                ),
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
            "state": state,
            "sourceDevice": source_device,
            "errorReason": error_reason,
            "hasCachedExcerpt": has_excerpt,
            "hasThumb": has_thumb,
            "thumbWidth": thumb_w,
            "thumbHeight": thumb_h,
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
    pub(super) fn archive(&mut self, password: &str) -> Result<String> {
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
