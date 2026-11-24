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

mod vault_ops;

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
