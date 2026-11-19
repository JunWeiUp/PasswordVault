//! External 64 KiB chunked AES-256-GCM encrypted blob storage for note attachments.
//!
//! Files live under `<vault_dir>/blobs/<random-hex>.pvblob` with no original filename
//! or extension leaked on disk. Each chunk authenticates vault_id, blob_id, chunk_index
//! and is_final, while the SQLCipher `note_attachments` row seals a `BlobPointer`
//! bound to `AttachmentMeta` via AAD so metadata tampering still fails authentication.
use super::*;
use aes_gcm::{
    aead::{Aead, KeyInit, Payload},
    Aes256Gcm, Nonce,
};
use hmac::{Hmac, Mac};
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::io::{Read, Seek, SeekFrom, Write};

type HmacSha256 = Hmac<Sha256>;

pub(super) const CHUNK_SIZE: usize = 64 * 1024;
const BLOB_MAGIC: &[u8; 8] = b"PVBLOB01";
const BLOB_STORAGE_TAG: &str = "pvblob-v1";
const HEADER_LEN: usize = 8 + 4 + 8;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct BlobEnvelope {
    pub(super) storage: String,
    pub(super) sealed: Sealed,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct BlobPointer {
    pub(super) blob_id: String,
    pub(super) chunks: u32,
    pub(super) content_mac: String,
    pub(super) size: usize,
}

pub(super) fn table(conn: &Connection) -> Result<()> {
    storage(conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS note_attachment_blobs(
            attachment_id TEXT PRIMARY KEY,
            blob_id TEXT NOT NULL,
            content_mac TEXT NOT NULL,
            chunks INTEGER NOT NULL,
            size INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS note_attachment_blobs_mac ON note_attachment_blobs(content_mac);
        CREATE INDEX IF NOT EXISTS note_attachment_blobs_blob ON note_attachment_blobs(blob_id);",
    ))
}

pub(super) fn blobs_dir(vault_dir: &Path) -> PathBuf {
    vault_dir.join("blobs")
}

fn ensure_blobs_dir(vault_dir: &Path) -> Result<PathBuf> {
    if !vault_dir.is_dir() {
        return Err(VaultError::Storage);
    }
    let dir = blobs_dir(vault_dir);
    protect_dir(&dir)?;
    Ok(dir)
}

fn valid_blob_id(id: &str) -> bool {
    id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit())
}

fn blob_path(vault_dir: &Path, blob_id: &str) -> Result<PathBuf> {
    if !valid_blob_id(blob_id) {
        return Err(VaultError::InvalidData);
    }
    Ok(blobs_dir(vault_dir).join(format!("{blob_id}.pvblob")))
}

fn chunk_aad(vault_id: &str, blob_id: &str, index: u32, is_final: bool) -> Result<Vec<u8>> {
    serde_json::to_vec(&(BLOB_STORAGE_TAG, vault_id, blob_id, index, is_final))
        .map_err(|_| VaultError::InvalidData)
}

fn read_chunk(reader: &mut impl Read, buf: &mut [u8]) -> Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        match reader.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return Err(VaultError::Storage),
        }
    }
    Ok(filled)
}

fn open_blob_readonly(path: &Path) -> Result<File> {
    let sm = storage(fs::symlink_metadata(path))?;
    if !sm.file_type().is_file() {
        return Err(VaultError::InvalidData);
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(0x0100); // O_NOFOLLOW
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

pub(super) struct WrittenBlob {
    pub(super) pointer: BlobPointer,
    pub(super) created_new_file: bool,
}

/// Streams plaintext from `reader` into a 64 KiB chunked encrypted `.pvblob` file,
/// computing a keyed HMAC-SHA256 for deduplication without buffering the whole file.
pub(super) fn write_blob_from_reader(
    vault_dir: &Path,
    conn: &Connection,
    root: &[u8; 32],
    vault_id: &str,
    mut reader: impl Read,
    max_size: usize,
) -> Result<WrittenBlob> {
    table(conn)?;
    let dir = ensure_blobs_dir(vault_dir)?;
    let blob_id = new_id();
    let enc_key = subkey(root, b"note-blob-chunks-v1");
    let mac_key = subkey(root, b"note-blob-dedup-v1");
    let cipher = Aes256Gcm::new_from_slice(enc_key.as_ref()).map_err(|_| VaultError::Storage)?;
    let mut mac =
        <HmacSha256 as Mac>::new_from_slice(mac_key.as_ref()).map_err(|_| VaultError::Storage)?;

    let mut temp = storage(tempfile::Builder::new().prefix(".tmp-").tempfile_in(&dir))?;
    storage(temp.as_file_mut().write_all(&[0u8; HEADER_LEN]))?;

    let mut cur = Zeroizing::new(vec![0u8; CHUNK_SIZE]);
    let mut next = Zeroizing::new(vec![0u8; CHUNK_SIZE]);
    let mut cur_len = read_chunk(&mut reader, &mut cur)?;
    let mut total_size: usize = 0;
    let mut chunks: u32 = 0;

    let write_one = |file: &mut File,
                     plaintext: &[u8],
                     idx: u32,
                     is_final: bool,
                     mac: &mut HmacSha256|
     -> Result<()> {
        mac.update(plaintext);
        let nonce_bytes = random_bytes::<12>();
        let aad = chunk_aad(vault_id, &blob_id, idx, is_final)?;
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(&nonce_bytes),
                Payload {
                    msg: plaintext,
                    aad: &aad,
                },
            )
            .map_err(|_| VaultError::Storage)?;
        let ct_len = u32::try_from(ciphertext.len()).map_err(|_| VaultError::InvalidData)?;
        storage(file.write_all(&nonce_bytes))?;
        storage(file.write_all(&ct_len.to_le_bytes()))?;
        storage(file.write_all(&ciphertext))?;
        Ok(())
    };

    if cur_len == 0 {
        write_one(temp.as_file_mut(), b"", 0, true, &mut mac)?;
        chunks = 1;
    } else {
        loop {
            total_size = total_size
                .checked_add(cur_len)
                .ok_or(VaultError::InvalidData)?;
            if total_size > max_size {
                return Err(VaultError::InvalidData);
            }
            let next_len = read_chunk(&mut reader, &mut next)?;
            let is_final = next_len == 0;
            write_one(
                temp.as_file_mut(),
                &cur[..cur_len],
                chunks,
                is_final,
                &mut mac,
            )?;
            chunks = chunks.checked_add(1).ok_or(VaultError::InvalidData)?;
            if is_final {
                break;
            }
            std::mem::swap(&mut cur, &mut next);
            cur_len = next_len;
        }
    }

    let content_mac = hex::encode(mac.finalize().into_bytes());

    // Deduplicate identical encrypted content inside the same vault when the backing file exists.
    let existing: Option<(String, u32, usize)> = storage(
        conn.query_row(
            "SELECT blob_id, chunks, size FROM note_attachment_blobs WHERE content_mac=?1 LIMIT 1",
            [&content_mac],
            |r| {
                let bid: String = r.get(0)?;
                let c: u32 = r.get(1)?;
                let sz: i64 = r.get(2)?;
                Ok((bid, c, sz as usize))
            },
        )
        .optional(),
    )?;
    if let Some((existing_blob_id, existing_chunks, existing_size)) = existing {
        if existing_chunks == chunks
            && existing_size == total_size
            && blob_path(vault_dir, &existing_blob_id)
                .map(|p| p.is_file())
                .unwrap_or(false)
        {
            drop(temp);
            return Ok(WrittenBlob {
                pointer: BlobPointer {
                    blob_id: existing_blob_id,
                    chunks,
                    content_mac,
                    size: total_size,
                },
                created_new_file: false,
            });
        }
    }

    let mut header = [0u8; HEADER_LEN];
    header[..8].copy_from_slice(BLOB_MAGIC);
    header[8..12].copy_from_slice(&chunks.to_le_bytes());
    header[12..20].copy_from_slice(&(total_size as u64).to_le_bytes());
    storage(temp.as_file_mut().seek(SeekFrom::Start(0)))?;
    storage(temp.as_file_mut().write_all(&header))?;
    storage(temp.as_file_mut().sync_all())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        storage(fs::set_permissions(
            temp.path(),
            fs::Permissions::from_mode(0o600),
        ))?;
    }
    let final_path = blob_path(vault_dir, &blob_id)?;
    storage(crate::native_file_ops::replace_synced(
        temp.path(),
        &final_path,
    ))?;

    Ok(WrittenBlob {
        pointer: BlobPointer {
            blob_id,
            chunks,
            content_mac,
            size: total_size,
        },
        created_new_file: true,
    })
}

/// Streams and authenticates every chunk of a `.pvblob` file into `writer`.
pub(super) fn read_blob_to_writer(
    vault_dir: &Path,
    root: &[u8; 32],
    vault_id: &str,
    pointer: &BlobPointer,
    mut writer: impl Write,
) -> Result<usize> {
    if pointer.chunks == 0 || pointer.size > crate::archive::FILE_LIMIT {
        return Err(VaultError::InvalidData);
    }
    let path = blob_path(vault_dir, &pointer.blob_id)?;
    let mut file = open_blob_readonly(&path)?;
    let mut header = [0u8; HEADER_LEN];
    file.read_exact(&mut header)
        .map_err(|_| VaultError::InvalidData)?;
    if &header[..8] != BLOB_MAGIC {
        return Err(VaultError::InvalidData);
    }
    let chunks = u32::from_le_bytes(header[8..12].try_into().unwrap());
    let total_size = u64::from_le_bytes(header[12..20].try_into().unwrap()) as usize;
    if chunks != pointer.chunks || total_size != pointer.size {
        return Err(VaultError::Authentication);
    }

    let enc_key = subkey(root, b"note-blob-chunks-v1");
    let mac_key = subkey(root, b"note-blob-dedup-v1");
    let cipher = Aes256Gcm::new_from_slice(enc_key.as_ref()).map_err(|_| VaultError::Storage)?;
    let mut mac =
        <HmacSha256 as Mac>::new_from_slice(mac_key.as_ref()).map_err(|_| VaultError::Storage)?;

    let mut written: usize = 0;
    let max_chunk_ct = CHUNK_SIZE + 16;
    for idx in 0..chunks {
        let mut nonce = [0u8; 12];
        file.read_exact(&mut nonce)
            .map_err(|_| VaultError::Authentication)?;
        let mut len_buf = [0u8; 4];
        file.read_exact(&mut len_buf)
            .map_err(|_| VaultError::Authentication)?;
        let ct_len = u32::from_le_bytes(len_buf) as usize;
        if ct_len < 16 || ct_len > max_chunk_ct {
            return Err(VaultError::Authentication);
        }
        let mut ct = vec![0u8; ct_len];
        file.read_exact(&mut ct)
            .map_err(|_| VaultError::Authentication)?;
        let is_final = idx + 1 == chunks;
        let aad = chunk_aad(vault_id, &pointer.blob_id, idx, is_final)?;
        let plain = Zeroizing::new(
            cipher
                .decrypt(
                    Nonce::from_slice(&nonce),
                    Payload {
                        msg: &ct,
                        aad: &aad,
                    },
                )
                .map_err(|_| VaultError::Authentication)?,
        );
        written = written
            .checked_add(plain.len())
            .ok_or(VaultError::InvalidData)?;
        if written > pointer.size {
            return Err(VaultError::Authentication);
        }
        mac.update(&plain);
        storage(writer.write_all(&plain))?;
    }

    // Ensure no trailing unauthenticated bytes exist after the final chunk.
    let mut trailing = [0u8; 1];
    if file.read(&mut trailing).map_err(|_| VaultError::Storage)? != 0 {
        return Err(VaultError::Authentication);
    }
    if written != pointer.size {
        return Err(VaultError::Authentication);
    }
    let expected_mac = hex::decode(&pointer.content_mac).map_err(|_| VaultError::Authentication)?;
    mac.verify_slice(&expected_mac)
        .map_err(|_| VaultError::Authentication)?;
    Ok(written)
}

pub(super) fn encode_envelope(
    root: &[u8; 32],
    vault_id: &str,
    meta: &notes::AttachmentMeta,
    pointer: &BlobPointer,
) -> Result<Vec<u8>> {
    let clear = Zeroizing::new(serde_json::to_vec(pointer).map_err(|_| VaultError::InvalidData)?);
    let sealed = seal(
        &subkey(root, b"note-attachments-v1"),
        &clear,
        &notes::aad(vault_id, meta)?,
    )?;
    serde_json::to_vec(&BlobEnvelope {
        storage: BLOB_STORAGE_TAG.into(),
        sealed,
    })
    .map_err(|_| VaultError::InvalidData)
}

pub(super) fn try_decode_pointer(
    payload: &[u8],
    root: &[u8; 32],
    vault_id: &str,
    meta: &notes::AttachmentMeta,
) -> Result<Option<BlobPointer>> {
    let Ok(envelope) = serde_json::from_slice::<BlobEnvelope>(payload) else {
        return Ok(None);
    };
    if envelope.storage != BLOB_STORAGE_TAG {
        return Err(VaultError::InvalidData);
    }
    let clear = unseal(
        &subkey(root, b"note-attachments-v1"),
        &envelope.sealed,
        &notes::aad(vault_id, meta)?,
    )?;
    let pointer: BlobPointer =
        serde_json::from_slice(&clear).map_err(|_| VaultError::InvalidData)?;
    if pointer.size != meta.size {
        return Err(VaultError::Authentication);
    }
    Ok(Some(pointer))
}

pub(super) fn record_ref(
    conn: &Connection,
    attachment_id: &str,
    pointer: &BlobPointer,
) -> Result<()> {
    table(conn)?;
    storage(conn.execute(
        "INSERT INTO note_attachment_blobs(attachment_id,blob_id,content_mac,chunks,size)
         VALUES(?1,?2,?3,?4,?5)
         ON CONFLICT(attachment_id) DO UPDATE SET
           blob_id=excluded.blob_id,
           content_mac=excluded.content_mac,
           chunks=excluded.chunks,
           size=excluded.size",
        rusqlite::params![
            attachment_id,
            pointer.blob_id,
            pointer.content_mac,
            pointer.chunks,
            pointer.size as i64,
        ],
    ))?;
    Ok(())
}

pub(super) fn delete_ref(conn: &Connection, attachment_id: &str) -> Result<()> {
    table(conn)?;
    storage(conn.execute(
        "DELETE FROM note_attachment_blobs WHERE attachment_id=?1",
        [attachment_id],
    ))?;
    Ok(())
}

pub(super) fn delete_refs_for_note(conn: &Connection, note_id: &str) -> Result<()> {
    table(conn)?;
    storage(conn.execute(
        "DELETE FROM note_attachment_blobs WHERE attachment_id IN (SELECT id FROM note_attachments WHERE note_id=?1)",
        [note_id],
    ))?;
    Ok(())
}

pub(super) fn remove_file_if_unused(vault_dir: &Path, blob_id: &str) {
    if let Ok(path) = blob_path(vault_dir, blob_id) {
        let _ = fs::remove_file(path);
    }
}

/// Removes unreferenced `.pvblob` files from `<vault_dir>/blobs/` after SQLite commits.
pub(super) fn prune_unreferenced(vault_dir: &Path, conn: &Connection) -> Result<usize> {
    table(conn)?;
    // Drop any index rows whose attachment row no longer exists.
    storage(conn.execute(
        "DELETE FROM note_attachment_blobs WHERE attachment_id NOT IN (SELECT id FROM note_attachments)",
        [],
    ))?;
    let dir = blobs_dir(vault_dir);
    if !dir.is_dir() {
        return Ok(0);
    }
    let mut stmt = storage(conn.prepare("SELECT DISTINCT blob_id FROM note_attachment_blobs"))?;
    let rows = storage(stmt.query_map([], |r| r.get::<_, String>(0)))?;
    let live: HashSet<String> = storage(rows.collect::<std::result::Result<HashSet<_>, _>>())?;
    let mut removed = 0usize;
    for entry in storage(fs::read_dir(&dir))? {
        let entry = storage(entry)?;
        let name = entry.file_name();
        let Some(name_str) = name.to_str() else {
            continue;
        };
        if let Some(stem) = name_str.strip_suffix(".pvblob") {
            if !live.contains(stem) {
                let _ = fs::remove_file(entry.path());
                removed += 1;
            }
        } else if name_str.starts_with(".tmp-") {
            let _ = fs::remove_file(entry.path());
        }
    }
    Ok(removed)
}

#[derive(Clone)]
pub(super) struct BlobIndexInfo {
    pub(super) blob_id: String,
    pub(super) chunks: u32,
}

pub(super) fn info_for_attachment(
    conn: &Connection,
    attachment_id: &str,
) -> Result<Option<BlobIndexInfo>> {
    table(conn)?;
    storage(
        conn.query_row(
            "SELECT blob_id, chunks FROM note_attachment_blobs WHERE attachment_id=?1",
            [attachment_id],
            |r| {
                Ok(BlobIndexInfo {
                    blob_id: r.get(0)?,
                    chunks: r.get(1)?,
                })
            },
        )
        .optional(),
    )
}

pub(super) fn copy_blobs_dir(src_vault_dir: &Path, dst_dir: &Path) -> Result<()> {
    let src = blobs_dir(src_vault_dir);
    if !src.is_dir() {
        return Ok(());
    }
    let dst = blobs_dir(dst_dir);
    protect_dir(&dst)?;
    for entry in storage(fs::read_dir(&src))? {
        let entry = storage(entry)?;
        let name = entry.file_name();
        let Some(name_str) = name.to_str() else {
            continue;
        };
        if !name_str.ends_with(".pvblob") {
            continue;
        }
        let target = dst.join(name_str);
        storage(fs::copy(entry.path(), &target))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            storage(fs::set_permissions(
                &target,
                fs::Permissions::from_mode(0o600),
            ))?;
        }
    }
    storage(crate::native_file_ops::sync_directory(&dst))?;
    Ok(())
}

pub(super) fn status(vault_dir: &Path, conn: &Connection) -> Result<Value> {
    notes::table(conn)?;
    table(conn)?;
    let count: u64 =
        storage(conn.query_row("SELECT count(*) FROM note_attachments", [], |r| r.get(0)))?;
    let blob_attachments: u64 = storage(conn.query_row(
        "SELECT count(*) FROM note_attachment_blobs",
        [],
        |r| r.get(0),
    ))?;
    let unique_blobs: u64 = storage(conn.query_row(
        "SELECT count(DISTINCT blob_id) FROM note_attachment_blobs",
        [],
        |r| r.get(0),
    ))?;
    let total_bytes: u64 = storage(conn.query_row(
        "SELECT COALESCE(SUM(size), 0) FROM note_attachment_blobs",
        [],
        |r| r.get::<_, i64>(0).map(|v| v.max(0) as u64),
    ))?;
    let disk_files = blobs_dir(vault_dir)
        .read_dir()
        .map(|it| {
            it.filter_map(|e| e.ok())
                .filter(|e| {
                    e.file_name()
                        .to_str()
                        .is_some_and(|n| n.ends_with(".pvblob"))
                })
                .count() as u64
        })
        .unwrap_or(0);
    Ok(json!({
        "enabled": true,
        "chunkSize": CHUNK_SIZE,
        "maxFileSize": crate::archive::FILE_LIMIT,
        "count": count,
        "blobAttachments": blob_attachments,
        "uniqueBlobs": unique_blobs,
        "diskFiles": disk_files,
        "totalBytes": total_bytes,
    }))
}
