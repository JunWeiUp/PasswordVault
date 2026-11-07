use crate::*;
mod capabilities;
mod devices;
mod history;
mod notes;
mod passkey_backups;
mod passkeys;
mod recovery;
mod relay;
use fs2::FileExt;
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::Mutex,
};
use zeroize::{Zeroize, Zeroizing};

struct OpenVault {
    connection: Connection,
    root: Secret,
    header: Header,
    document: Document,
}
pub struct DiskVault {
    directory: PathBuf,
    _lock: File,
    unlocked: Option<OpenVault>,
}

#[derive(uniffi::Object)]
pub struct VaultSession {
    inner: Mutex<DiskVault>,
}

fn storage<T>(r: std::result::Result<T, impl std::fmt::Debug>) -> Result<T> {
    r.map_err(|_| VaultError::Storage)
}

fn protect_dir(path: &Path) -> Result<()> {
    storage(fs::create_dir_all(path))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        storage(fs::set_permissions(path, fs::Permissions::from_mode(0o700)))?;
    }
    Ok(())
}
fn atomic_write(path: &Path, data: &[u8]) -> Result<()> {
    let parent = path.parent().ok_or(VaultError::Storage)?;
    let mut file = storage(tempfile::NamedTempFile::new_in(parent))?;
    storage(file.write_all(data))?;
    storage(file.as_file().sync_all())?;
    storage(crate::native_file_ops::replace_synced(file.path(), path))?;
    Ok(())
}
fn open_database(path: &Path, root: &[u8; 32], create: bool) -> Result<Connection> {
    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE
        | if create {
            OpenFlags::SQLITE_OPEN_CREATE
        } else {
            OpenFlags::empty()
        };
    let conn = storage(Connection::open_with_flags(path, flags))?;
    let version: String = storage(conn.query_row("PRAGMA cipher_version", [], |r| r.get(0)))?;
    if version.is_empty() {
        return Err(VaultError::Unsupported);
    }
    let key = subkey(root, b"native-database");
    let hexkey = Zeroizing::new(format!("x'{}'", hex::encode(key.as_ref())));
    storage(conn.pragma_update(None, "key", hexkey.as_str()))?;
    conn.query_row("SELECT count(*) FROM sqlite_master", [], |row| {
        row.get::<_, i64>(0)
    })
    .map_err(|_| VaultError::Authentication)?;
    storage(conn.execute_batch("PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON; PRAGMA temp_store=MEMORY; PRAGMA journal_mode=DELETE;"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        storage(fs::set_permissions(path, fs::Permissions::from_mode(0o600)))?;
    }
    Ok(conn)
}
fn save_document(
    conn: &mut Connection,
    root: &[u8; 32],
    vault_id: &str,
    doc: &Document,
) -> Result<()> {
    let tx = storage(conn.transaction())?;
    save_document_row(&tx, root, vault_id, doc)?;
    storage(tx.commit())?;
    Ok(())
}
fn save_document_row(
    conn: &Connection,
    root: &[u8; 32],
    vault_id: &str,
    doc: &Document,
) -> Result<()> {
    let mut guarded = doc.clone();
    if relay::enabled(conn)? {
        guarded.format_version = guarded.format_version.max(4);
    }
    if history::enabled(conn)? {
        guarded.format_version = guarded.format_version.max(5);
        guarded.settings["entryHistoryEnabled"] = json!(true);
    }
    let doc = &guarded;
    history::capture(conn, root, vault_id, doc)?;
    relay::capture(conn, root, vault_id, doc)?;
    let bytes = Zeroizing::new(serde_json::to_vec(doc).map_err(|_| VaultError::InvalidData)?);
    let sealed = seal(&subkey(root, b"document"), &bytes, vault_id.as_bytes())?;
    let encrypted = serde_json::to_vec(&sealed).map_err(|_| VaultError::InvalidData)?;
    storage(conn.execute("INSERT INTO vault_state(id,payload) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",[encrypted]))?;
    Ok(())
}

fn load_document(conn: &Connection, root: &[u8; 32], vault_id: &str) -> Result<Document> {
    let bytes: Vec<u8> = storage(conn.query_row(
        "SELECT payload FROM vault_state WHERE id=1",
        [],
        |row| row.get(0),
    ))?;
    let sealed: Sealed = serde_json::from_slice(&bytes).map_err(|_| VaultError::InvalidData)?;
    let document = Document::parse(&unseal(
        &subkey(root, b"document"),
        &sealed,
        vault_id.as_bytes(),
    )?)?;
    if (document.format_version == 5 || document.settings["entryHistoryEnabled"] == true)
        && !history::enabled(conn)?
    {
        return Err(VaultError::InvalidData);
    }
    Ok(document)
}

impl DiskVault {
    fn new(base: &Path) -> Result<Self> {
        protect_dir(base)?;
        let lock = storage(
            OpenOptions::new()
                .create(true)
                .truncate(false)
                .read(true)
                .write(true)
                .open(base.join("session.lock")),
        )?;
        lock.try_lock_exclusive().map_err(|_| VaultError::InUse)?;
        Ok(Self {
            directory: base.join("vault"),
            _lock: lock,
            unlocked: None,
        })
    }
    fn header(&self) -> Result<Header> {
        let bytes = storage(fs::read(self.directory.join("header.json")))?;
        if bytes.len() > 16384 {
            return Err(VaultError::InvalidData);
        }
        serde_json::from_slice(&bytes).map_err(|_| VaultError::InvalidData)
    }
    fn create(&mut self, password: &str) -> Result<()> {
        self.create_document(password, Document::default())
    }
    fn create_document(&mut self, password: &str, doc: Document) -> Result<()> {
        if self.directory.exists() {
            return Err(VaultError::AlreadyExists);
        }
        let temp = storage(
            tempfile::Builder::new()
                .prefix(".new-vault-")
                .tempdir_in(self.directory.parent().unwrap()),
        )?;
        protect_dir(temp.path())?;
        let root = Zeroizing::new(random_bytes::<32>());
        let header = Header::create(password, &root, new_id())?;
        let mut connection = open_database(&temp.path().join("vault.sqlite"), &root, true)?;
        storage(connection.execute_batch(
            "CREATE TABLE vault_state(id INTEGER PRIMARY KEY CHECK(id=1),payload BLOB NOT NULL);",
        ))?;
        save_document(&mut connection, &root, &header.vault_id, &doc)?;
        drop(connection);
        atomic_write(
            &temp.path().join("header.json"),
            &serde_json::to_vec(&header).map_err(|_| VaultError::InvalidData)?,
        )?;
        storage(crate::native_file_ops::replace_synced(
            temp.path(),
            &self.directory,
        ))?;
        self.unlock_key(root, header)
    }
    fn unlock(&mut self, password: &str) -> Result<()> {
        let header = self.header()?;
        let root = header.unlock(password)?;
        self.unlock_key(root, header)
    }
    fn unlock_key(&mut self, root: Secret, header: Header) -> Result<()> {
        let connection = open_database(&self.directory.join("vault.sqlite"), &root, false)?;
        let document = load_document(&connection, &root, &header.vault_id)?;
        self.lock();
        self.unlocked = Some(OpenVault {
            connection,
            root,
            header,
            document,
        });
        Ok(())
    }
    fn lock(&mut self) {
        if let Some(mut open) = self.unlocked.take() {
            for value in &mut open.document.items {
                wipe_value(value);
            }
            for value in &mut open.document.shared_vaults {
                wipe_value(value);
            }
            for value in &mut open.document.shared_members {
                wipe_value(value);
            }
            wipe_value(&mut open.document.settings);
        }
    }
    fn open(&mut self) -> Result<&mut OpenVault> {
        self.unlocked.as_mut().ok_or(VaultError::Locked)
    }
    fn mutate(&mut self, f: impl FnOnce(&mut Document) -> Result<Value>) -> Result<Value> {
        let open = self.open()?;
        let mut next = open.document.clone();
        let result = f(&mut next)?;
        save_document(
            &mut open.connection,
            &open.root,
            &open.header.vault_id,
            &next,
        )?;
        open.document = next;
        Ok(result)
    }
    fn command(&mut self, request: &Value) -> Result<Value> {
        let op = request["op"].as_str().ok_or(VaultError::InvalidData)?;
        let string = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        if self
            .unlocked
            .as_ref()
            .is_some_and(|o| o.document.format_version >= 3)
            && request["richNotes"] != true
            && ["import", "restore-drafts", "remove"].contains(&op)
        {
            return Err(VaultError::Unsupported);
        }
        if [
            "import-preview",
            "import-commit",
            "security-audit",
            "security-ignore",
            "security-catalog",
            "breach-request",
            "breach-response",
        ]
        .contains(&op)
        {
            return self.capability_command(request);
        }
        if op.starts_with("devices-") {
            return self.devices_command(request);
        }
        if let Some(open) = &self.unlocked {
            if !relay::personal_operation(op) {
                guard_device_sync(open.document.format_version, op)?;
            }
        }
        if op == "save" && requires_structured_format(&request["item"]) {
            validate_structured_item(&request["item"])?;
            self.prepare_capability_upgrade()?;
        }
        if op.starts_with("relay-") {
            return self.relay_command(request);
        }
        if op.starts_with("passkey-")
            || op.starts_with("otp-")
            || op == "update-login"
            || op.starts_with("structured-")
        {
            return self.passkey_command(request);
        }
        if op.starts_with("recovery-") {
            return self.recovery_command(request);
        }
        if op.starts_with("history-") {
            return self.history_command(request);
        }
        match op {
            "status" => Ok(
                json!({"exists":self.directory.exists(),"unlocked":self.unlocked.is_some(),"version":2}),
            ),
            "create" => {
                self.create(string("password")?)?;
                Ok(json!({"ok":true}))
            }
            "create-from-backup" => {
                if string("content")?.contains("\"PasswordVaultArchive\"") {
                    if request["richNotes"] != true {
                        return Err(VaultError::Unsupported);
                    }
                    return self.import_archive(
                        string("content")?,
                        request["backupPassword"].as_str().unwrap_or(""),
                        Some(string("password")?),
                    );
                }
                let document = import_document(
                    string("content")?,
                    request["backupPassword"].as_str().unwrap_or(""),
                    request["kind"].as_str().unwrap_or("json"),
                )?;
                if document.format_version >= 3 {
                    return Err(VaultError::Unsupported);
                }
                let count = document.items.len();
                self.create_document(string("password")?, document)?;
                Ok(json!({"imported": count}))
            }
            "create-migrated" => {
                let document = crate::legacy_database::read_legacy_database(
                    Path::new(string("source")?),
                    string("legacyPassword")?,
                    string("salt")?,
                )?;
                let count = document.items.len();
                self.create_document(string("password")?, document)?;
                Ok(json!({"imported": count}))
            }
            "unlock" => {
                self.unlock(string("password")?)?;
                Ok(json!({"ok":true}))
            }
            "lock" => {
                self.lock();
                Ok(json!({"ok":true}))
            }
            "list" => {
                let open = self.open()?;
                // Summaries keep the plain-text projection for lists and search but omit
                // rich note structures, which interfaces load per note with "get". They
                // are stripped before any copy so large notes are never duplicated here.
                let summary;
                let source = if request["summaries"] == true {
                    summary = summary_document(&open.document);
                    &summary
                } else {
                    &open.document
                };
                Ok(json!(relay::peer::editable_document(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    source
                )?))
            }
            "get" => {
                let open = self.open()?;
                let id = string("id")?;
                let document = json!(relay::peer::editable_document(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &open.document
                )?);
                document["items"]
                    .as_array()
                    .and_then(|items| items.iter().find(|item| item["id"] == id))
                    .cloned()
                    .ok_or(VaultError::InvalidData)
            }
            "share-options" => {
                let open = self.open()?;
                let item = open
                    .document
                    .items
                    .iter()
                    .find(|i| i["id"] == string("id").unwrap_or("") && i["isDeleted"] != true)
                    .ok_or(VaultError::InvalidData)?;
                let mut used = std::collections::HashSet::new();
                crate::archive::item_attachment_refs(item, &mut used)?;
                let files: Vec<_> = notes::metas(&open.connection)?
                    .into_iter()
                    .filter(|m| m.note_id == item["id"] && used.contains(&m.id))
                    .collect();
                let fields: Vec<_> = SHARE_FIELDS
                    .iter()
                    .filter(|key| item.get(**key).is_some())
                    .collect();
                Ok(json!({"fields":fields,"attachments":files}))
            }
            "share-seal" => {
                let id = string("id")?;
                let fields: Vec<String> = serde_json::from_value(request["fields"].clone())
                    .map_err(|_| VaultError::InvalidData)?;
                let ids: Vec<String> = serde_json::from_value(
                    request.get("attachmentIds").cloned().unwrap_or(json!([])),
                )
                .map_err(|_| VaultError::InvalidData)?;
                if ids.len() > 50 {
                    return Err(VaultError::InvalidData);
                }
                let open = self.open()?;
                let item = open
                    .document
                    .items
                    .iter()
                    .find(|i| i["id"] == id && i["isDeleted"] != true)
                    .ok_or(VaultError::InvalidData)?;
                let mut used = std::collections::HashSet::new();
                crate::archive::item_attachment_refs(item, &mut used)?;
                let metas = notes::metas(&open.connection)?;
                let mut attachments = Vec::new();
                let mut bytes_total = 0;
                for file_id in ids {
                    let meta = metas
                        .iter()
                        .find(|m| m.id == file_id && m.note_id == id && used.contains(&m.id))
                        .ok_or(VaultError::InvalidData)?;
                    bytes_total += meta.size;
                    if bytes_total > 24 * 1024 * 1024 {
                        return Err(VaultError::InvalidData);
                    }
                    let bytes =
                        notes::read(&open.connection, &open.root, &open.header.vault_id, meta)?;
                    attachments.push(share_attachment(
                        meta.name.clone(),
                        meta.mime.clone(),
                        &bytes,
                    ));
                }
                seal_share(item, &fields, &attachments)
            }
            "collect-note-attachments" if request["richNotes"] == true => {
                self.collect_note_attachments()
            }
            "category-add" => {
                self.mutate(|doc| Ok(json!({"name":doc.add_note_category(string("name")?)?})))
            }
            "category-remove" => self.mutate(|doc| {
                Ok(json!({"updated":doc.remove_note_category(string("name")?,string("time")?)?}))
            }),
            "save" => {
                // A summary lacks note structures; writing it back would drop them.
                if request["item"]["noteSummary"] == true {
                    return Err(VaultError::InvalidData);
                }
                let open = self.open()?;
                let mut item = relay::peer::prepare_save(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &open.document,
                    &request["item"],
                )?;
                preserve_passkeys_for_edit(&open.document, &mut item)?;
                let mut cleaned = request.clone();
                cleaned["item"] = item.clone();
                self.validate_note_save(&cleaned)?;
                self.mutate(|doc| {
                    authorize_item_write(doc, &item)?;
                    if let Some(old) = doc.items.iter().find(|v| v["id"] == item["id"]) {
                        authorize_item_write(doc, old)?;
                    }
                    doc.upsert(item.clone())?;
                    Ok(json!({"ok":true}))
                })?;
                let open = self.open()?;
                relay::peer::save_result(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &open.document,
                    item["id"].as_str().ok_or(VaultError::InvalidData)?,
                )
            }
            "remove" => self.remove_note_record(string("id")?),
            "seal-drafts" => {
                let open = self.open()?;
                let bytes = Zeroizing::new(
                    serde_json::to_vec(&request["items"]).map_err(|_| VaultError::InvalidData)?,
                );
                Ok(
                    json!({"payload":seal(&subkey(&open.root,b"draft-recovery"),&bytes,open.header.vault_id.as_bytes())?}),
                )
            }
            "open-drafts" => {
                let open = self.open()?;
                let sealed: Sealed = serde_json::from_value(request["payload"].clone())
                    .map_err(|_| VaultError::InvalidData)?;
                let bytes = unseal(
                    &subkey(&open.root, b"draft-recovery"),
                    &sealed,
                    open.header.vault_id.as_bytes(),
                )?;
                let items: Vec<Value> =
                    serde_json::from_slice(&bytes).map_err(|_| VaultError::InvalidData)?;
                Ok(json!({"items": items}))
            }
            "restore-drafts" => {
                let open = self.open()?;
                let sealed: Sealed = serde_json::from_value(request["payload"].clone())
                    .map_err(|_| VaultError::InvalidData)?;
                let bytes = unseal(
                    &subkey(&open.root, b"draft-recovery"),
                    &sealed,
                    open.header.vault_id.as_bytes(),
                )?;
                let items: Vec<Value> =
                    serde_json::from_slice(&bytes).map_err(|_| VaultError::InvalidData)?;
                let items = items
                    .iter()
                    .map(|item| {
                        relay::peer::prepare_save(
                            &open.connection,
                            &open.root,
                            &open.header.vault_id,
                            &open.document,
                            item,
                        )
                    })
                    .collect::<Result<Vec<_>>>()?;
                for item in &items {
                    self.validate_note_save(
                        &json!({"item":item,"richNotes":request["richNotes"]}),
                    )?;
                }
                self.mutate(|doc| {
                    for mut item in items {
                        preserve_passkeys_for_edit(doc, &mut item)?;
                        authorize_item_write(doc, &item)?;
                        doc.upsert(item)?;
                    }
                    Ok(json!({"ok":true}))
                })
            }
            "settings" => self.mutate(|doc| {
                update_settings(doc, &request["settings"])?;
                Ok(json!({"ok":true}))
            }),
            "identity" => self.mutate(|doc| {
                let key = sharing_identity(doc)?;
                Ok(json!({"publicKey":key}))
            }),
            "create-shared" => {
                self.mutate(|doc| create_shared(doc, string("name")?, string("time")?))
            }
            "add-member" => self.mutate(|doc| {
                add_member(
                    doc,
                    string("vaultId")?,
                    string("publicKey")?,
                    request["role"].as_str().unwrap_or("viewer"),
                    request["name"].as_str().unwrap_or(""),
                )
            }),
            "remove-member" => {
                self.mutate(|doc| remove_member(doc, string("vaultId")?, string("publicKey")?))
            }
            "sync-request" => {
                self.mutate(|doc| create_sync_request(doc, string("peerKey")?, string("vaultId")?))
            }
            "sync-respond" => self.mutate(|doc| respond_sync(doc, &request["packet"])),
            "sync-apply" => self.mutate(|doc| {
                apply_sync(
                    doc,
                    &request["packet"],
                    string("peerKey")?,
                    string("vaultId")?,
                )
            }),
            "export" => {
                if self.open()?.document.format_version >= 3 {
                    if request["richNotes"] != true {
                        return Err(VaultError::Unsupported);
                    }
                    return Ok(json!({"content":self.archive(string("password")?)?}));
                }
                let data = Zeroizing::new(
                    serde_json::to_vec(&self.open()?.document)
                        .map_err(|_| VaultError::InvalidData)?,
                );
                Ok(json!({"content":encrypt_backup(&data,string("password")?)?}))
            }
            "export-csv-backup" => {
                if self.open()?.document.format_version >= 3 {
                    return Err(VaultError::Unsupported);
                }
                let csv = Zeroizing::new(export_csv(&self.open()?.document)?);
                let envelope: Value =
                    serde_json::from_str(&encrypt_backup(csv.as_bytes(), string("password")?)?)
                        .map_err(|_| VaultError::InvalidData)?;
                Ok(
                    json!({"content":json!({"format":"PasswordVaultCSVBackup","version":1,"envelope":envelope}).to_string()}),
                )
            }
            "export-plain" => {
                if self.open()?.document.format_version >= 3 {
                    return Err(VaultError::Unsupported);
                }
                let doc = &self.open()?.document;
                let content = if request["kind"] == "csv" {
                    export_csv(doc)?
                } else {
                    serde_json::to_string(doc).map_err(|_| VaultError::InvalidData)?
                };
                Ok(json!({"content":content}))
            }
            "import" => {
                self.open()?;
                if string("content")?.contains("\"PasswordVaultArchive\"") {
                    if request["richNotes"] != true {
                        return Err(VaultError::Unsupported);
                    }
                    return self.import_archive(
                        string("content")?,
                        request["password"].as_str().unwrap_or(""),
                        None,
                    );
                }
                let incoming = import_document(
                    string("content")?,
                    request["password"].as_str().unwrap_or(""),
                    request["kind"].as_str().unwrap_or("json"),
                )?;
                if incoming.format_version >= 3 {
                    return Err(VaultError::Unsupported);
                }
                self.mutate(|doc| Ok(json!({"imported":doc.merge(incoming)?})))
            }
            "revoke-background" => {
                self.open()?;
                let base = self.directory.parent().ok_or(VaultError::Storage)?;
                revoke_background_grants(base.to_string_lossy().into_owned())?;
                Ok(json!({"ok":true}))
            }
            "change-password" => {
                let open = self.open()?;
                let validated = open.header.unlock(string("currentPassword")?)?;
                if validated.as_ref() != open.root.as_ref() {
                    return Err(VaultError::Authentication);
                }
                let new_header = Header::create(
                    string("newPassword")?,
                    &open.root,
                    open.header.vault_id.clone(),
                )?;
                let bytes = serde_json::to_vec(&new_header).map_err(|_| VaultError::InvalidData)?;
                atomic_write(&self.directory.join("header.json"), &bytes)?;
                self.open()?.header = new_header;
                Ok(json!({"ok":true}))
            }
            "totp" => {
                self.open()?;
                Ok(
                    json!({"code":totp(string("secret")?,request["period"].as_u64().unwrap_or(30),request["time"].as_u64().ok_or(VaultError::InvalidData)?)?}),
                )
            }
            "parse-totp" => {
                self.open()?;
                parse_totp_uri(string("uri")?)
            }
            "wallet" => {
                self.open()?;
                wallet(request)
            }
            "generate" => {
                self.open()?;
                Ok(
                    json!({"password":generate_password(request["length"].as_u64().unwrap_or(20)as usize,request["upper"]!=false,request["lower"]!=false,request["digits"]!=false,request["symbols"]!=false)?}),
                )
            }
            "audit" => Ok(audit(&self.open()?.document.items)),
            "matches" => matching_accounts(&self.open()?.document.items, string("origin")?),
            "fill" => fill_account(
                &self.open()?.document.items,
                string("origin")?,
                string("id")?,
                request["accountId"].as_str(),
            ),
            _ => Err(VaultError::Unsupported),
        }
    }
}

// A native-only Keychain capability. Never return this material through a browser message.
// Bind it to both the password envelope and a revocation epoch; rotating either invalidates it.
fn sync_fingerprint(base: &Path) -> Result<Vec<u8>> {
    let header = storage(fs::read(base.join("vault/header.json")))?;
    let epoch = match fs::read(base.join("background-sync-epoch")) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(_) => return Err(VaultError::Storage),
    };
    let mut hash = Sha256::new();
    hash.update(b"PasswordVault background save v1");
    hash.update(&header);
    hash.update(&epoch);
    Ok(hash.finalize().to_vec())
}

#[uniffi::export]
pub fn create_background_grant(directory: String, password: String) -> Result<Vec<u8>> {
    let password = Zeroizing::new(password);
    let base = Path::new(&directory);
    let before = sync_fingerprint(base)?;
    let bytes = storage(fs::read(base.join("vault/header.json")))?;
    let header: Header = serde_json::from_slice(&bytes).map_err(|_| VaultError::InvalidData)?;
    let root = header.unlock(&password)?;
    if before != sync_fingerprint(base)? {
        return Err(VaultError::Authentication);
    }
    let mut grant = before;
    grant.extend_from_slice(root.as_ref());
    Ok(grant)
}

#[uniffi::export]
pub fn background_grant_valid(directory: String, grant: Vec<u8>) -> Result<bool> {
    let grant = Zeroizing::new(grant);
    Ok(grant.len() == 64 && grant[..32] == sync_fingerprint(Path::new(&directory))?)
}

#[uniffi::export]
pub fn revoke_background_grants(directory: String) -> Result<()> {
    atomic_write(
        &Path::new(&directory).join("background-sync-epoch"),
        &random_bytes::<32>(),
    )
}

impl DiskVault {
    fn validate_native_grant(&self, grant: &[u8]) -> Result<()> {
        let base = self.directory.parent().ok_or(VaultError::Storage)?;
        if grant.len() != 64
            || grant[..32] != sync_fingerprint(base)?
            || self
                .unlocked
                .as_ref()
                .is_some_and(|open| open.root.as_ref() != &grant[32..])
        {
            return Err(VaultError::Authentication);
        }
        Ok(())
    }
    fn background_save(&mut self, grant: &[u8], request: &Value) -> Result<Value> {
        let base = self.directory.parent().ok_or(VaultError::Storage)?;
        if grant.len() != 64 || grant[..32] != sync_fingerprint(base)? {
            return Err(VaultError::Authentication);
        }
        // Only an append operation; no general command dispatch and no reads returned.
        let origin = request["origin"].as_str().ok_or(VaultError::InvalidData)?;
        let url = url::Url::parse(origin).map_err(|_| VaultError::InvalidData)?;
        if !["http", "https"].contains(&url.scheme())
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || (url.path() != "/" && !url.path().is_empty())
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err(VaultError::InvalidData);
        }
        let username = request["username"]
            .as_str()
            .ok_or(VaultError::InvalidData)?;
        let password = request["password"]
            .as_str()
            .ok_or(VaultError::InvalidData)?;
        let id = request["id"].as_str().ok_or(VaultError::InvalidData)?;
        if username.is_empty()
            || password.is_empty()
            || username.len() > 4096
            || password.len() > 4096
            || (id.len() != 36
                || !id.bytes().enumerate().all(|(i, b)| {
                    if [8, 13, 18, 23].contains(&i) {
                        b == b'-'
                    } else {
                        b.is_ascii_hexdigit()
                    }
                }))
        {
            return Err(VaultError::InvalidData);
        }
        if self
            .unlocked
            .as_ref()
            .is_some_and(|open| open.root.as_ref() != &grant[32..])
        {
            return Err(VaultError::Authentication);
        }
        let was_locked = self.unlocked.is_none();
        if was_locked {
            let root = Zeroizing::new(
                grant[32..]
                    .try_into()
                    .map_err(|_| VaultError::Authentication)?,
            );
            self.unlock_key(root, self.header()?)?;
        }
        let result = (|| {
            let open = self.open()?;
            storage(open.connection.execute_batch(
                "CREATE TABLE IF NOT EXISTS browser_sync_receipts(id TEXT PRIMARY KEY)",
            ))?;
            let already: bool = storage(open.connection.query_row(
                "SELECT EXISTS(SELECT 1 FROM browser_sync_receipts WHERE id=?1)",
                [id],
                |r| r.get(0),
            ))?;
            if already {
                return Ok(json!({"saved":true}));
            }
            let mut doc = open.document.clone();
            let item_id = format!("browser-sync-{id}");
            let mut duplicate = doc.items.iter().any(|item| item["id"] == item_id);
            let matches = matching_accounts(&doc.items, origin)?;
            for account in matches.as_array().ok_or(VaultError::InvalidData)? {
                if account["username"] == username {
                    let mut existing = fill_account(
                        &doc.items,
                        origin,
                        account["id"].as_str().ok_or(VaultError::InvalidData)?,
                        account["accountId"].as_str(),
                    )?;
                    duplicate |=
                        existing["username"] == username && existing["password"] == password;
                    wipe_value(&mut existing);
                }
            }
            if !duplicate {
                let seconds = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_err(|_| VaultError::Storage)?
                    .as_secs();
                let now = chrono::DateTime::from_timestamp(seconds as i64, 0)
                    .ok_or(VaultError::Storage)?
                    .to_rfc3339();
                doc.upsert(
                    json!({"id":item_id, "type":"password", "title":url.host_str(),
                    "username":username, "password":password, "url":origin,
                    "createdAt":now, "updatedAt":now, "isDeleted":false}),
                )?;
            }
            let tx = storage(open.connection.transaction())?;
            save_document_row(&tx, &open.root, &open.header.vault_id, &doc)?;
            storage(tx.execute("INSERT INTO browser_sync_receipts(id) VALUES(?1)", [id]))?;
            storage(tx.commit())?;
            open.document = doc;
            Ok(json!({"saved":true}))
        })();
        if was_locked {
            self.lock();
        }
        result
    }
}

fn wipe_value(value: &mut Value) {
    match value {
        Value::String(s) => s.zeroize(),
        Value::Array(a) => a.iter_mut().for_each(wipe_value),
        Value::Object(o) => o.values_mut().for_each(wipe_value),
        _ => {}
    }
}
impl Drop for DiskVault {
    fn drop(&mut self) {
        self.lock();
    }
}

#[uniffi::export]
impl VaultSession {
    #[uniffi::constructor]
    pub fn new(directory: String) -> Result<Self> {
        Ok(Self {
            inner: Mutex::new(DiskVault::new(Path::new(&directory))?),
        })
    }
    pub fn command(&self, request: String) -> Result<String> {
        let input = Zeroizing::new(request);
        if input.len() > notes::ARCHIVE_LIMIT {
            return Err(VaultError::InvalidData);
        }
        let mut parsed: Value =
            serde_json::from_str(&input).map_err(|_| VaultError::InvalidData)?;
        let result = self
            .inner
            .lock()
            .map_err(|_| VaultError::Storage)?
            .command(&parsed);
        wipe_value(&mut parsed);
        serde_json::to_string(&result?).map_err(|_| VaultError::InvalidData)
    }
    /// Native-only: the helper must verify explicit read authorization before calling this API.
    pub fn authorized_browser_command(&self, grant: Vec<u8>, request: String) -> Result<String> {
        let grant = Zeroizing::new(grant);
        let input = Zeroizing::new(request);
        if input.len() > 32768 {
            return Err(VaultError::InvalidData);
        }
        let mut parsed: Value =
            serde_json::from_str(&input).map_err(|_| VaultError::InvalidData)?;
        if !matches!(parsed["op"].as_str(), Some("matches" | "fill")) {
            wipe_value(&mut parsed);
            return Err(VaultError::Unsupported);
        }
        let mut inner = self.inner.lock().map_err(|_| VaultError::Storage)?;
        inner.validate_native_grant(&grant)?;
        let was_locked = inner.unlocked.is_none();
        if was_locked {
            let root = Zeroizing::new(
                grant[32..]
                    .try_into()
                    .map_err(|_| VaultError::Authentication)?,
            );
            let header = inner.header()?;
            inner.unlock_key(root, header)?;
        }
        let result = inner.command(&parsed);
        wipe_value(&mut parsed);
        if was_locked {
            inner.lock();
        }
        let mut result = result?;
        let output = serde_json::to_string(&result).map_err(|_| VaultError::InvalidData);
        wipe_value(&mut result);
        output
    }

    /// Only the authenticated desktop-startup handshake may call this API.
    pub fn unlock_desktop_grant(&self, grant: Vec<u8>) -> Result<()> {
        let grant = Zeroizing::new(grant);
        let mut inner = self.inner.lock().map_err(|_| VaultError::Storage)?;
        inner.validate_native_grant(&grant)?;
        let root = Zeroizing::new(
            grant[32..]
                .try_into()
                .map_err(|_| VaultError::Authentication)?,
        );
        let header = inner.header()?;
        inner.unlock_key(root, header)
    }

    /// Native-only append API. Grant bytes must stay in the native Keychain/IPC boundary.
    pub fn background_save(&self, grant: Vec<u8>, request: String) -> Result<String> {
        let grant = Zeroizing::new(grant);
        let input = Zeroizing::new(request);
        if input.len() > 32768 {
            return Err(VaultError::InvalidData);
        }
        let mut parsed: Value =
            serde_json::from_str(&input).map_err(|_| VaultError::InvalidData)?;
        let result = self
            .inner
            .lock()
            .map_err(|_| VaultError::Storage)?
            .background_save(&grant, &parsed);
        wipe_value(&mut parsed);
        serde_json::to_string(&result?).map_err(|_| VaultError::InvalidData)
    }

    /// Only for a native platform Keychain entry with biometric access control.
    /// This API must never be exposed to browser messages.
    pub fn biometric_key(&self) -> Result<Vec<u8>> {
        Ok(self
            .inner
            .lock()
            .map_err(|_| VaultError::Storage)?
            .open()?
            .root
            .to_vec())
    }
    pub fn unlock_biometric(&self, key: Vec<u8>) -> Result<()> {
        let key = Zeroizing::new(key);
        let root = Zeroizing::new(
            key.as_slice()
                .try_into()
                .map_err(|_| VaultError::Authentication)?,
        );
        let mut inner = self.inner.lock().map_err(|_| VaultError::Storage)?;
        let header = inner.header()?;
        inner.unlock_key(root, header)
    }
}

/// A copy of `doc` whose items omit rich note structures (marked `noteSummary`),
/// built item by item so no full copy of the large structures is made.
fn summary_document(doc: &Document) -> Document {
    let items = doc
        .items
        .iter()
        .map(|item| match item.as_object() {
            Some(object)
                if object.contains_key("noteDocument") || object.contains_key("noteOriginal") =>
            {
                let mut lite: serde_json::Map<String, Value> = object
                    .iter()
                    .filter(|(key, _)| *key != "noteDocument" && *key != "noteOriginal")
                    .map(|(key, value)| (key.clone(), value.clone()))
                    .collect();
                lite.insert("noteSummary".into(), Value::Bool(true));
                Value::Object(lite)
            }
            _ => item.clone(),
        })
        .collect();
    Document {
        format_version: doc.format_version,
        items,
        shared_vaults: doc.shared_vaults.clone(),
        shared_members: doc.shared_members.clone(),
        settings: doc.settings.clone(),
    }
}

#[cfg(test)]
mod note_summary_tests {
    use super::*;

    #[test]
    fn summaries_omit_rich_structures_get_restores_them_and_summaries_cannot_be_saved() {
        let dir = tempfile::tempdir().unwrap();
        let session = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
        let run = |v: Value| session.command(v.to_string());
        run(json!({"op":"create","password":"Synthetic summary fixture"})).unwrap();
        let note = json!({"id":"n1","type":"secureNote","title":"Rich","note":"Hello world","noteFormat":"rich-v1",
            "noteDocument":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Hello world"}]}]},
            "tags":[],"username":"","isDeleted":false,"isFavorite":false,"isPinned":false,"updatedAt":"2026-11-05T00:00:00Z"});
        run(json!({"op":"save","item":note,"richNotes":true})).unwrap();

        let list: Value = serde_json::from_str(
            &run(json!({"op":"list","summaries":true,"richNotes":true})).unwrap(),
        )
        .unwrap();
        let summary = list["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["id"] == "n1")
            .unwrap()
            .clone();
        assert!(summary.get("noteDocument").is_none());
        assert_eq!(summary["noteSummary"], true);
        assert_eq!(summary["note"], "Hello world");

        let full: Value =
            serde_json::from_str(&run(json!({"op":"get","id":"n1","richNotes":true})).unwrap())
                .unwrap();
        assert_eq!(full["noteDocument"]["type"], "doc");
        assert!(full.get("noteSummary").is_none());
        assert!(run(json!({"op":"get","id":"missing","richNotes":true})).is_err());

        let mut edited = summary.clone();
        edited["isFavorite"] = json!(true);
        assert!(run(json!({"op":"save","item":edited,"richNotes":true})).is_err());
        let after: Value =
            serde_json::from_str(&run(json!({"op":"get","id":"n1","richNotes":true})).unwrap())
                .unwrap();
        assert_eq!(after["noteDocument"], full["noteDocument"]);
        assert_eq!(after["isFavorite"], false);

        let plain: Value =
            serde_json::from_str(&run(json!({"op":"list","richNotes":true})).unwrap()).unwrap();
        assert!(plain["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["noteDocument"]["type"] == "doc"));
    }
}

#[cfg(test)]
mod background_transaction_tests {
    use super::*;
    #[test]
    fn receipt_failure_rolls_back_the_document_and_retry_succeeds() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = DiskVault::new(dir.path()).unwrap();
        vault.create("Synthetic transaction fixture").unwrap();
        let grant = create_background_grant(
            dir.path().to_string_lossy().into(),
            "Synthetic transaction fixture".into(),
        )
        .unwrap();
        let conn = &vault.open().unwrap().connection;
        conn.execute_batch(
            "CREATE TABLE browser_sync_receipts(id TEXT PRIMARY KEY);
            CREATE TRIGGER reject_receipt BEFORE INSERT ON browser_sync_receipts
            BEGIN SELECT RAISE(ABORT, 'synthetic write failure'); END;",
        )
        .unwrap();
        let request = json!({"id":"44444444-4444-4444-a444-444444444444",
            "origin":"https://fixture.test","username":"fixture","password":"fictional"});
        assert!(vault.background_save(&grant, &request).is_err());
        assert!(vault.open().unwrap().document.items.is_empty());
        let open = vault.open().unwrap();
        assert!(
            load_document(&open.connection, &open.root, &open.header.vault_id)
                .unwrap()
                .items
                .is_empty()
        );
        open.connection
            .execute_batch("DROP TRIGGER reject_receipt")
            .unwrap();
        vault.background_save(&grant, &request).unwrap();
        assert_eq!(vault.open().unwrap().document.items.len(), 1);
    }
}
