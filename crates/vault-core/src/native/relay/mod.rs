//! Personal-vault replication. The relay transports bytes; only the Mac commits revisions.
//! Every journal update shares the SQLCipher transaction with the document write.
use super::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

mod capabilities;
#[path = "../relay_mesh/mod.rs"]
pub(super) mod mesh;

// These operations implement their own authenticated personal-relay gate.
pub(super) fn personal_operation(op: &str) -> bool {
    matches!(
        op,
        "relay-init"
            | "relay-trust"
            | "relay-export"
            | "relay-receive"
            | "relay-resolve"
            | "relay-resolve-batch"
            | "relay-capabilities-challenge"
            | "relay-capabilities-prove"
            | "relay-capabilities-accept"
    ) || mesh::operation(op)
}

type Records = BTreeMap<String, Value>;
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Change {
    id: String,
    key: String,
    base: u64,
    value: Value,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Conflict {
    peer: String,
    change: Change,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct State {
    version: u32,
    #[serde(default)]
    capabilities: BTreeMap<String, String>,
    #[serde(default)]
    challenges: BTreeMap<String, (String, u64)>,
    role: String,
    group: String,
    device: String,
    hub: String,
    peers: BTreeSet<String>,
    revision: u64,
    cursor: u64,
    cursors: BTreeMap<String, u64>,
    baseline: Records,
    canonical: Records,
    revisions: BTreeMap<String, u64>,
    pending: BTreeMap<String, Change>,
    #[serde(default)]
    blocked: BTreeSet<String>,
    seen: BTreeMap<String, String>,
    conflicts: BTreeMap<String, Conflict>,
    receipts: BTreeMap<String, BTreeSet<String>>,
}
pub(super) fn enabled(conn: &Connection) -> Result<bool> {
    Ok(storage(conn.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='personal_relay'",
        [],
        |r| r.get::<_, i64>(0),
    ))? != 0)
}
// Archived sync state can reference attachments absent from the current document.
pub(super) fn retains_attachments(conn: &Connection) -> Result<bool> {
    Ok(enabled(conn)? || mesh::enabled(conn)? || storage(conn.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('personal_relay_archive','personal_mesh_archive')",
        [], |r| r.get::<_, i64>(0),
    ))? != 0)
}
fn load(conn: &Connection, root: &[u8; 32], vault: &str) -> Result<State> {
    let data: Vec<u8> = storage(conn.query_row(
        "SELECT payload FROM personal_relay WHERE id=1",
        [],
        |r| r.get(0),
    ))?;
    let sealed: Sealed = serde_json::from_slice(&data).map_err(|_| VaultError::InvalidData)?;
    serde_json::from_slice(&unseal(
        &subkey(root, b"personal-relay-v1"),
        &sealed,
        vault.as_bytes(),
    )?)
    .map_err(|_| VaultError::InvalidData)
}
fn store(conn: &Connection, root: &[u8; 32], vault: &str, state: &State) -> Result<()> {
    let data = Zeroizing::new(serde_json::to_vec(state).map_err(|_| VaultError::InvalidData)?);
    let sealed = seal(&subkey(root, b"personal-relay-v1"), &data, vault.as_bytes())?;
    storage(conn.execute("INSERT INTO personal_relay(id,payload) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",[serde_json::to_vec(&sealed).map_err(|_|VaultError::InvalidData)?]))?;
    Ok(())
}
fn records(doc: &Document) -> Records {
    let mut out = Records::new();
    for item in &doc.items {
        out.insert(
            format!("item:{}", item["id"].as_str().unwrap_or_default()),
            item.clone(),
        );
    }
    out.insert("categories".into(), json!(doc.note_categories()));
    out
}
pub(super) fn install(doc: &mut Document, values: &Records) -> Result<()> {
    doc.items = values
        .iter()
        .filter(|(k, v)| k.starts_with("item:") && !v.is_null())
        .map(|(_, v)| v.clone())
        .collect();
    doc.settings["noteCategories"] = values.get("categories").cloned().unwrap_or(json!([]));
    doc.format_version = doc.format_version.max(4);
    *doc = Document::parse(&serde_json::to_vec(doc).map_err(|_| VaultError::InvalidData)?)?;
    Ok(())
}
fn commit(state: &mut State, key: &str, value: Value) -> Result<()> {
    state.revision = state
        .revision
        .checked_add(1)
        .ok_or(VaultError::InvalidData)?;
    state.revisions.insert(key.into(), state.revision);
    state.canonical.insert(key.into(), value);
    Ok(())
}
pub(super) fn capture_with_stripped(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    doc: &Document,
    stripped: &Document,
) -> Result<()> {
    if mesh::capture(conn, root, vault, stripped)? {
        return Ok(());
    }
    if !enabled(conn)? {
        return Ok(());
    }
    let hydrated = note_bodies::hydrate(conn, root, vault, doc.clone())?;
    let mut state = load(conn, root, vault)?;
    let now = records(&hydrated);
    let keys: BTreeSet<_> = now.keys().chain(state.baseline.keys()).cloned().collect();
    for key in keys {
        let value = now.get(&key).cloned().unwrap_or(Value::Null);
        if state.baseline.get(&key).unwrap_or(&Value::Null) == &value {
            continue;
        }
        if state.role == "hub" {
            commit(&mut state, &key, value)?;
        } else {
            let base = *state.revisions.get(&key).unwrap_or(&0);
            state.pending.insert(
                key.clone(),
                Change {
                    id: new_id(),
                    key,
                    base,
                    value,
                },
            );
        }
    }
    state.baseline = now;
    store(conn, root, vault, &state)
}
fn valid_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_".contains(&c))
}
fn string<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str().ok_or(VaultError::InvalidData)
}
fn attachments(vault_dir: &Path, open: &OpenVault, packet: &Value) -> Result<Value> {
    let mut needed = std::collections::HashSet::new();
    if let Some(records) = packet["records"].as_object() {
        for item in records.values() {
            crate::archive::item_attachment_refs(item, &mut needed)?;
        }
    }
    if let Some(changes) = packet["changes"].as_array() {
        for change in changes {
            crate::archive::item_attachment_refs(&change["value"], &mut needed)?;
        }
    }
    let mut files = Vec::new();
    for meta in notes::metas(&open.connection)? {
        if !needed.contains(&meta.id) {
            continue;
        }
        if notes::is_remote(&open.connection, &meta.id)? {
            continue;
        }
        let bytes = notes::read(
            vault_dir,
            &open.connection,
            &open.root,
            &open.header.vault_id,
            &meta,
        )?;
        files.push(json!({"meta":meta,"data":STANDARD.encode(bytes.as_slice())}));
    }
    Ok(json!(files))
}

/// Splits referenced attachments into inline small files (`<= inline_limit`) and
/// L1 metadata-only `remoteFiles` (`> inline_limit` or still remote locally) so
/// large `<= 100 MB` blobs never cause head-of-line blocking in Mesh sync.
fn attachments_split(
    vault_dir: &Path,
    open: &OpenVault,
    packet: &Value,
    inline_limit: usize,
    device: &str,
) -> Result<(Value, Value)> {
    let mut needed = std::collections::HashSet::new();
    if let Some(records) = packet["records"].as_object() {
        for item in records.values() {
            crate::archive::item_attachment_refs(item, &mut needed)?;
        }
    }
    let mut inline_files = Vec::new();
    let mut remote_files = Vec::new();
    for meta in notes::metas(&open.connection)? {
        if !needed.contains(&meta.id) {
            continue;
        }
        let is_remote = notes::is_remote(&open.connection, &meta.id)?;
        if !is_remote && meta.size <= inline_limit {
            let bytes = notes::read(
                vault_dir,
                &open.connection,
                &open.root,
                &open.header.vault_id,
                &meta,
            )?;
            inline_files.push(json!({"meta":meta,"data":STANDARD.encode(bytes.as_slice())}));
        } else {
            let cache = notes::get_cache(
                &open.connection,
                &open.root,
                &open.header.vault_id,
                &meta.note_id,
                &meta.id,
            )
            .ok();
            remote_files.push(json!({
                "meta": meta,
                "sourceDevice": device,
                "excerpt": cache.as_ref().and_then(|c| c.get("excerpt").cloned()).unwrap_or(Value::Null),
                "thumb": cache.as_ref().and_then(|c| c.get("thumb").cloned()).unwrap_or(Value::Null),
            }));
        }
    }
    Ok((json!(inline_files), json!(remote_files)))
}

fn receive_remote_files(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    peer: &str,
    remote_files: &Value,
) -> Result<()> {
    if remote_files.is_null() {
        return Ok(());
    }
    let list = remote_files.as_array().ok_or(VaultError::InvalidData)?;
    if list.len() > 10_000 {
        return Err(VaultError::InvalidData);
    }
    for entry in list {
        let meta: notes::AttachmentMeta =
            serde_json::from_value(entry["meta"].clone()).map_err(|_| VaultError::InvalidData)?;
        if meta.size > crate::archive::FILE_LIMIT {
            return Err(VaultError::InvalidData);
        }
        let source = entry["sourceDevice"].as_str().unwrap_or(peer);
        let excerpt = entry.get("excerpt").filter(|v| !v.is_null());
        let thumb = entry.get("thumb").filter(|v| !v.is_null());
        notes::write_remote_stub(conn, root, vault, &meta, Some(source), excerpt, thumb)?;
    }
    Ok(())
}

fn receive_files(
    vault_dir: &Path,
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    files: &Value,
) -> Result<()> {
    let files = files.as_array().ok_or(VaultError::InvalidData)?;
    if files.len() > 10000 {
        return Err(VaultError::InvalidData);
    }
    let existing = notes::metas(conn)?;
    let mut total = 0usize;
    let mut ids = BTreeSet::new();
    for file in files {
        let meta: notes::AttachmentMeta =
            serde_json::from_value(file["meta"].clone()).map_err(|_| VaultError::InvalidData)?;
        let bytes = Zeroizing::new(
            STANDARD
                .decode(string(file, "data")?)
                .map_err(|_| VaultError::InvalidData)?,
        );
        total = total
            .checked_add(bytes.len())
            .ok_or(VaultError::InvalidData)?;
        if bytes.len() != meta.size
            || bytes.len() > crate::archive::FILE_LIMIT
            || total > 512 * 1024 * 1024
            || !ids.insert(meta.id.clone())
        {
            return Err(VaultError::InvalidData);
        }
        if let Some(old) = existing.iter().find(|m| m.id == meta.id) {
            if serde_json::to_value(old).ok() != serde_json::to_value(&meta).ok() {
                return Err(VaultError::InvalidData);
            }
            if notes::is_remote(conn, &old.id)? {
                notes::write(vault_dir, conn, root, vault, &meta, &bytes)?;
            } else if notes::read(vault_dir, conn, root, vault, old)?.as_slice() != bytes.as_slice()
            {
                return Err(VaultError::InvalidData);
            }
        } else {
            notes::write(vault_dir, conn, root, vault, &meta, &bytes)?;
        }
    }
    Ok(())
}
fn replace_attachment(node: &mut Value, old: &str, new: &str) {
    if node["attrs"]["attachmentId"] == old {
        node["attrs"]["attachmentId"] = json!(new);
    }
    if let Some(children) = node["content"].as_array_mut() {
        for child in children {
            replace_attachment(child, old, new);
        }
    }
}
fn validate_files(conn: &Connection, doc: &Document) -> Result<()> {
    let files = notes::metas(conn)?
        .into_iter()
        .filter(|m| doc.items.iter().any(|i| i["id"] == m.note_id))
        .collect::<Vec<_>>();
    notes::validate(doc, &files)
}

mod commands;
#[cfg(test)]
mod tests;
