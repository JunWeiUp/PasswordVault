//! Shared archive metadata and attachment validation for native and Web clients.
use crate::*;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use zeroize::Zeroizing;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct HistoryRevision {
    pub id: String,
    pub item_id: String,
    pub captured_at: u64,
    pub item: Value,
}

pub(crate) const FILE_LIMIT: usize = 25 * 1024 * 1024;
pub(crate) const NOTE_LIMIT: usize = 250 * 1024 * 1024;
pub(crate) const ARCHIVE_LIMIT: usize = 1024 * 1024 * 1024;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct AttachmentMeta {
    pub(crate) id: String,
    pub(crate) note_id: String,
    pub(crate) name: String,
    pub(crate) mime: String,
    pub(crate) size: usize,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Archive {
    pub(crate) format: String,
    pub(crate) version: u32,
    pub(crate) header: Header,
    pub(crate) manifest: Sealed,
    pub(crate) files: HashMap<String, Sealed>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Manifest {
    pub(crate) document: Document,
    pub(crate) attachments: Vec<AttachmentMeta>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) history: Vec<HistoryRevision>,
}

fn with_history(document: &Document, history: &[HistoryRevision]) -> Document {
    let mut result = document.clone();
    result.items.extend(
        history
            .iter()
            .filter(|r| !r.item.is_null())
            .map(|r| r.item.clone()),
    );
    result
}

pub(crate) fn validate_history(history: &[HistoryRevision]) -> Result<()> {
    let mut ids = HashSet::new();
    for revision in history {
        if revision.id.len() != 32
            || !ids.insert(&revision.id)
            || revision.item_id.is_empty()
            || revision.item_id.len() > 256
        {
            return Err(VaultError::InvalidData);
        }
        if !revision.item.is_null() {
            let mut item = revision.item.clone();
            normalize_item(&mut item)?;
            if item["id"] != revision.item_id {
                return Err(VaultError::InvalidData);
            }
        }
    }
    Ok(())
}

pub(crate) fn encode_archive(
    document: &Document,
    attachments: Vec<AttachmentMeta>,
    history: Vec<HistoryRevision>,
    history_enabled: bool,
    password: &str,
    mut read: impl FnMut(&AttachmentMeta) -> Result<Zeroizing<Vec<u8>>>,
) -> Result<String> {
    if password.chars().count() < 10 {
        return Err(VaultError::InvalidData);
    }
    validate_history(&history)?;
    validate_attachments(&with_history(document, &history), &attachments)?;
    let root = Zeroizing::new(random_bytes::<32>());
    let header = Header::create(password, &root, new_id())?;
    if !history_enabled && !history.is_empty() {
        return Err(VaultError::InvalidData);
    }
    let version = if history_enabled { 4 } else { 3 };
    let mut files = HashMap::new();
    let mut size = 0;
    for meta in &attachments {
        let bytes = read(meta)?;
        if bytes.len() != meta.size {
            return Err(VaultError::InvalidData);
        }
        let sealed = seal(
            &subkey(&root, b"note-attachments-v1"),
            &bytes,
            &attachment_aad(&header.vault_id, meta)?,
        )?;
        size += sealed.ciphertext.len();
        if size > ARCHIVE_LIMIT / 2 {
            return Err(VaultError::InvalidData);
        }
        files.insert(meta.id.clone(), sealed);
    }
    let bytes = Zeroizing::new(
        serde_json::to_vec(&Manifest {
            document: document.clone(),
            attachments,
            history,
        })
        .map_err(|_| VaultError::InvalidData)?,
    );
    let manifest = seal(
        &subkey(
            &root,
            if version == 4 {
                b"archive-manifest-v4"
            } else {
                b"archive-manifest-v3"
            },
        ),
        &bytes,
        header.vault_id.as_bytes(),
    )?;
    serde_json::to_string(&Archive {
        format: "PasswordVaultArchive".into(),
        version,
        header,
        manifest,
        files,
    })
    .map_err(|_| VaultError::InvalidData)
}

pub(crate) struct DecodedArchive {
    pub archive: Archive,
    pub manifest: Manifest,
    pub root: Secret,
}

pub(crate) fn decode_archive(input: &str, password: &str) -> Result<DecodedArchive> {
    if input.len() > ARCHIVE_LIMIT {
        return Err(VaultError::InvalidData);
    }
    let archive: Archive = serde_json::from_str(input).map_err(|_| VaultError::InvalidData)?;
    if archive.format != "PasswordVaultArchive" || ![3, 4].contains(&archive.version) {
        return Err(VaultError::Unsupported);
    }
    let root = archive.header.unlock(password)?;
    let bytes = unseal(
        &subkey(
            &root,
            if archive.version == 4 {
                b"archive-manifest-v4"
            } else {
                b"archive-manifest-v3"
            },
        ),
        &archive.manifest,
        archive.header.vault_id.as_bytes(),
    )?;
    let mut manifest: Manifest =
        serde_json::from_slice(&bytes).map_err(|_| VaultError::InvalidData)?;
    manifest.document = Document::parse(
        &serde_json::to_vec(&manifest.document).map_err(|_| VaultError::InvalidData)?,
    )?;
    if archive.version == 3
        && (manifest.document.format_version == 5
            || manifest.document.settings["entryHistoryEnabled"] == true
            || !manifest.history.is_empty())
    {
        return Err(VaultError::Unsupported);
    }
    if archive.version == 4 {
        manifest.document.format_version = manifest.document.format_version.max(5);
        manifest.document.settings["entryHistoryEnabled"] = json!(true);
    }
    validate_history(&manifest.history)?;
    validate_attachments(
        &with_history(&manifest.document, &manifest.history),
        &manifest.attachments,
    )?;
    if manifest.attachments.len() != archive.files.len() {
        return Err(VaultError::InvalidData);
    }
    for meta in &manifest.attachments {
        let data = unseal(
            &subkey(&root, b"note-attachments-v1"),
            archive.files.get(&meta.id).ok_or(VaultError::InvalidData)?,
            &attachment_aad(&archive.header.vault_id, meta)?,
        )?;
        if data.len() != meta.size {
            return Err(VaultError::InvalidData);
        }
    }
    Ok(DecodedArchive {
        archive,
        manifest,
        root,
    })
}
pub(crate) fn attachment_aad(vault: &str, meta: &AttachmentMeta) -> Result<Vec<u8>> {
    serde_json::to_vec(&(vault, meta)).map_err(|_| VaultError::InvalidData)
}
pub(crate) fn item_attachment_refs(item: &Value, out: &mut HashSet<String>) -> Result<()> {
    attachment_refs(&item["noteDocument"], out, 0)?;
    if item["type"] == "device" {
        crate::validate_device(item)?;
        for file in item["device"]["files"]
            .as_array()
            .ok_or(VaultError::InvalidData)?
        {
            out.insert(
                file["attachmentId"]
                    .as_str()
                    .ok_or(VaultError::InvalidData)?
                    .into(),
            );
        }
    }
    Ok(())
}
pub(crate) fn attachment_refs(node: &Value, out: &mut HashSet<String>, depth: usize) -> Result<()> {
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
            attachment_refs(child, out, depth + 1)?;
        }
    }
    Ok(())
}
pub(crate) fn validate_attachments(doc: &Document, files: &[AttachmentMeta]) -> Result<()> {
    let mut items: Vec<&Value> = doc.items.iter().collect();
    if let Some(snapshots) = doc.settings.get("peerLibrarySnapshots") {
        let snapshots = snapshots.as_array().ok_or(VaultError::InvalidData)?;
        if snapshots.len() > 256 {
            return Err(VaultError::InvalidData);
        }
        for snapshot in snapshots {
            let records = snapshot["records"]
                .as_object()
                .ok_or(VaultError::InvalidData)?;
            let operations = snapshot["packet"]["operations"]
                .as_array()
                .ok_or(VaultError::InvalidData)?;
            if records.len() > 100_000 || operations.len() > 100_000 {
                return Err(VaultError::InvalidData);
            }
            for (key, value) in records {
                if key.starts_with("item:") && !value.is_null() {
                    items.push(value);
                }
            }
            for operation in operations {
                if operation["key"]
                    .as_str()
                    .is_some_and(|key| key.starts_with("item:"))
                    && !operation["value"].is_null()
                {
                    items.push(&operation["value"]);
                }
            }
        }
    }
    let mut ids = HashSet::new();
    let mut totals = HashMap::<&str, usize>::new();
    for meta in files {
        if meta.size > FILE_LIMIT
            || !ids.insert(&meta.id)
            || meta.name.len() > 1024
            || meta.mime.len() > 128
            || !items.iter().any(|n| {
                n["id"] == meta.note_id
                    && matches!(n["type"].as_str(), Some("secureNote" | "device"))
            })
        {
            return Err(VaultError::InvalidData);
        }
        let total = totals.entry(&meta.note_id).or_default();
        *total += meta.size;
        if *total > NOTE_LIMIT {
            return Err(VaultError::InvalidData);
        }
    }
    for item in items {
        if item["type"] == "device" {
            let mut used = HashSet::new();
            item_attachment_refs(item, &mut used)?;
            for id in used {
                if !files.iter().any(|m| m.id == id && item["id"] == m.note_id) {
                    return Err(VaultError::InvalidData);
                }
            }
            continue;
        }
        if item["noteFormat"] != "rich-v1" {
            continue;
        }
        if item["noteDocument"]["type"] != "doc" {
            return Err(VaultError::InvalidData);
        }
        let mut used = HashSet::new();
        crate::archive::item_attachment_refs(item, &mut used)?;
        for id in used {
            if !files.iter().any(|m| m.id == id && item["id"] == m.note_id) {
                return Err(VaultError::InvalidData);
            }
        }
    }
    Ok(())
}
