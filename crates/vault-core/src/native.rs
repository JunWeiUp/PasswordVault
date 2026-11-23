use crate::*;
mod capabilities;
mod contract;
mod devices;
mod history;
mod legacy_peer;
mod note_blobs;
mod note_bodies;
mod notes;
mod ops;
mod passkey_backups;
mod passkeys;
mod queries;
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

const HYDRATED_NOTE_CACHE_CAP: usize = 16;

struct OpenVault {
    connection: Connection,
    root: Secret,
    header: Header,
    document: Document,
    document_loaded: bool,
    hydrated_notes: Vec<(String, Value)>,
}

impl OpenVault {
    fn get_hydrated(&mut self, id: &str) -> Option<Value> {
        let pos = self.hydrated_notes.iter().position(|(k, _)| k == id)?;
        let entry = self.hydrated_notes.remove(pos);
        let cloned = entry.1.clone();
        self.hydrated_notes.push(entry);
        Some(cloned)
    }
    fn put_hydrated(&mut self, id: String, item: Value) {
        if let Some(pos) = self.hydrated_notes.iter().position(|(k, _)| k == &id) {
            let mut old = self.hydrated_notes.remove(pos);
            wipe_value(&mut old.1);
        }
        while self.hydrated_notes.len() >= HYDRATED_NOTE_CACHE_CAP {
            let mut evicted = self.hydrated_notes.remove(0);
            wipe_value(&mut evicted.1);
        }
        self.hydrated_notes.push((id, item));
    }
    fn invalidate_hydrated(&mut self, id: &str) {
        if let Some(pos) = self.hydrated_notes.iter().position(|(k, _)| k == id) {
            let mut old = self.hydrated_notes.remove(pos);
            wipe_value(&mut old.1);
        }
    }
    fn clear_hydrated_cache(&mut self) {
        for (_, value) in &mut self.hydrated_notes {
            wipe_value(value);
        }
        self.hydrated_notes.clear();
    }
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
    storage(conn.execute_batch("PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-512; PRAGMA journal_mode=DELETE;"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        storage(fs::set_permissions(path, fs::Permissions::from_mode(0o600)))?;
    }
    Ok(conn)
}
#[must_use = "assign the returned stripped Document to open.document"]
fn save_document(
    conn: &mut Connection,
    root: &[u8; 32],
    vault_id: &str,
    doc: &Document,
) -> Result<Document> {
    save_document_with_history(conn, root, vault_id, None, doc, None)
}
#[must_use = "assign the returned stripped Document to open.document"]
fn save_document_with_history(
    conn: &mut Connection,
    root: &[u8; 32],
    vault_id: &str,
    previous: Option<&Document>,
    doc: &Document,
    meta: Option<&history::HistoryMeta>,
) -> Result<Document> {
    let tx = storage(conn.transaction())?;
    let persisted = save_document_row_with_prev(&tx, root, vault_id, previous, doc, meta)?;
    storage(tx.commit())?;
    Ok(persisted)
}
#[must_use = "assign the returned stripped Document to open.document"]
fn save_document_row_with_prev(
    conn: &Connection,
    root: &[u8; 32],
    vault_id: &str,
    previous: Option<&Document>,
    doc: &Document,
    meta: Option<&history::HistoryMeta>,
) -> Result<Document> {
    let mut guarded = doc.clone();
    if relay::enabled(conn)? {
        guarded.format_version = guarded.format_version.max(4);
    }
    if history::enabled(conn)? {
        guarded.format_version = guarded.format_version.max(5);
        guarded.settings["entryHistoryEnabled"] = json!(true);
    }
    let doc = &guarded;
    history::capture_with_meta(conn, root, vault_id, doc, meta)?;
    let persisted = note_bodies::sync_and_strip(conn, root, vault_id, doc)?;
    relay::capture_with_stripped(conn, root, vault_id, doc, &persisted)?;
    let bytes =
        Zeroizing::new(serde_json::to_vec(&persisted).map_err(|_| VaultError::InvalidData)?);
    let sealed = seal(&subkey(root, b"document"), &bytes, vault_id.as_bytes())?;
    let encrypted = serde_json::to_vec(&sealed).map_err(|_| VaultError::InvalidData)?;
    storage(conn.execute("INSERT INTO vault_state(id,payload) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",[encrypted]))?;
    queries::update_incremental(conn, root, vault_id, previous, &persisted)?;
    Ok(persisted)
}

/// Loads `vault_state` without hydrating `note_bodies`, keeping split notes in L1 summary form.
fn load_document_raw(conn: &Connection, root: &[u8; 32], vault_id: &str) -> Result<Document> {
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

#[cfg(test)]
fn load_document(conn: &Connection, root: &[u8; 32], vault_id: &str) -> Result<Document> {
    let document = load_document_raw(conn, root, vault_id)?;
    note_bodies::hydrate(conn, root, vault_id, document)
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
        let _ = save_document(&mut connection, &root, &header.vault_id, &doc)?;
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
        let mut connection = open_database(&self.directory.join("vault.sqlite"), &root, false)?;
        if legacy_peer::possible(&connection)? {
            let document = load_document_raw(&connection, &root, &header.vault_id)?;
            legacy_peer::leave(&mut connection, &root, &header.vault_id, document)?;
        }
        let (document, document_loaded) = if queries::current(&connection, &root, &header.vault_id)?
        {
            (Document::default(), false)
        } else {
            let document = load_document_raw(&connection, &root, &header.vault_id)?;
            let tx = storage(connection.transaction())?;
            queries::rebuild(&tx, &root, &header.vault_id, &document)?;
            storage(tx.commit())?;
            (document, true)
        };
        self.lock();
        self.unlocked = Some(OpenVault {
            connection,
            root,
            header,
            document,
            document_loaded,
            hydrated_notes: Vec::new(),
        });
        Ok(())
    }
    fn lock(&mut self) {
        if let Some(mut open) = self.unlocked.take() {
            open.clear_hydrated_cache();
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
    fn connection_only(&mut self) -> Result<&mut OpenVault> {
        self.unlocked.as_mut().ok_or(VaultError::Locked)
    }
    fn open(&mut self) -> Result<&mut OpenVault> {
        let open = self.unlocked.as_mut().ok_or(VaultError::Locked)?;
        if !open.document_loaded {
            open.document = load_document_raw(&open.connection, &open.root, &open.header.vault_id)?;
            open.document_loaded = true;
            open.clear_hydrated_cache();
        }
        Ok(open)
    }
    fn release_document(&mut self) {
        if let Some(open) = &mut self.unlocked {
            open.clear_hydrated_cache();
            queries::wipe_document(&mut open.document);
            open.document = Document::default();
            open.document_loaded = false;
        }
    }
    fn mutate(&mut self, f: impl FnOnce(&mut Document) -> Result<Value>) -> Result<Value> {
        self.mutate_with_history(None, f)
    }
    fn mutate_hydrated(&mut self, f: impl FnOnce(&mut Document) -> Result<Value>) -> Result<Value> {
        let open = self.open()?;
        let mut next = note_bodies::hydrate(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            open.document.clone(),
        )?;
        let result = f(&mut next)?;
        let persisted = save_document_with_history(
            &mut open.connection,
            &open.root,
            &open.header.vault_id,
            Some(&open.document),
            &next,
            None,
        )?;
        open.document = persisted;
        open.clear_hydrated_cache();
        Ok(result)
    }
    fn mutate_with_history(
        &mut self,
        meta: Option<&history::HistoryMeta>,
        f: impl FnOnce(&mut Document) -> Result<Value>,
    ) -> Result<Value> {
        let open = self.open()?;
        let mut next = open.document.clone();
        let result = f(&mut next)?;
        let persisted = save_document_with_history(
            &mut open.connection,
            &open.root,
            &open.header.vault_id,
            Some(&open.document),
            &next,
            meta,
        )?;
        open.document = persisted;
        if let Some(id) = meta.and_then(|m| m.item_id.as_deref()) {
            open.invalidate_hydrated(id);
        } else {
            open.clear_hydrated_cache();
        }
        Ok(result)
    }
    fn command(&mut self, request: &Value) -> Result<Value> {
        let op = request["op"].as_str().ok_or(VaultError::InvalidData)?;
        if !contract::is_registered(op) {
            return Err(VaultError::Unsupported);
        }
        if op.starts_with(crate::relay_protocol::OP_PREFIX) {
            return relay_protocol_command(request);
        }
        if matches!(op, "read-settings" | "matches" | "fill") {
            let open = self.unlocked.as_ref().ok_or(VaultError::Locked)?;
            return queries::query(&open.connection, &open.root, &open.header.vault_id, request);
        }
        if op == "relay-credentials-read" {
            return self.relay_command(request);
        }
        if !matches!(op, "status" | "lock" | "unlock" | "create") && self.unlocked.is_some() {
            self.open()?;
        }
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
            "export-cxf",
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
        match contract::group(op) {
            Some("vault") => self.vault_ops(op, request),
            Some("items") => self.items_ops(op, request),
            Some("notes") => self.notes_ops(op, request),
            Some("backup") => self.backup_ops(op, request),
            Some("sharing") => self.sharing_ops(op, request),
            Some("categories") => self.categories_ops(op, request),
            Some("tools") => self.tools_ops(op, request),
            _ => Err(VaultError::Unsupported),
        }
    }
}

/// Stateless common-relay protocol ops (`relay-protocol-*`) for the mobile relay clients.
/// Needs no vault or session; requests are wiped after use.
#[uniffi::export]
pub fn relay_protocol(request: String) -> Result<String> {
    let input = Zeroizing::new(request);
    if input.len() > 300_000 {
        return Err(VaultError::InvalidData);
    }
    let mut parsed: Value = serde_json::from_str(&input).map_err(|_| VaultError::InvalidData)?;
    let result = match parsed["op"].as_str() {
        Some(op)
            if op.starts_with(crate::relay_protocol::OP_PREFIX) && contract::is_registered(op) =>
        {
            relay_protocol_command(&parsed)
        }
        _ => Err(VaultError::Unsupported),
    };
    wipe_value(&mut parsed);
    serde_json::to_string(&result?).map_err(|_| VaultError::InvalidData)
}

fn relay_protocol_command(request: &Value) -> Result<Value> {
    crate::relay_protocol::command(request).map_err(|e| match e.0 {
        "Authentication" => VaultError::Authentication,
        _ => VaultError::InvalidData,
    })
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
            let saved = save_document_row_with_prev(
                &tx,
                &open.root,
                &open.header.vault_id,
                Some(&open.document),
                &doc,
                None,
            )?;
            storage(tx.execute("INSERT INTO browser_sync_receipts(id) VALUES(?1)", [id]))?;
            storage(tx.commit())?;
            open.document = saved;
            open.clear_hydrated_cache();
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
        // Stateless relay protocol ops never wait for, or touch, the vault.
        let result = if parsed["op"]
            .as_str()
            .is_some_and(|op| op.starts_with(crate::relay_protocol::OP_PREFIX))
        {
            if parsed["op"].as_str().is_some_and(contract::is_registered) {
                relay_protocol_command(&parsed)
            } else {
                Err(VaultError::Unsupported)
            }
        } else {
            self.inner
                .lock()
                .map_err(|_| VaultError::Storage)?
                .command(&parsed)
        };
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

/// Searchable rich-note attributes that are absent from the plain-text body.
/// Walk only the document tree and known display attributes, never arbitrary JSON.
fn note_search_metadata(node: &Value, depth: usize, output: &mut Vec<String>) {
    if depth > 64 {
        return;
    }
    let mut add = |value: &Value| {
        if let Some(text) = value.as_str().filter(|text| !text.is_empty()) {
            output.push(text.to_owned());
        }
    };
    if node["type"] == "vaultImage" || node["type"] == "vaultAttachment" {
        add(&node["attrs"]["name"]);
        add(&node["attrs"]["caption"]);
    }
    if let Some(marks) = node["marks"].as_array() {
        for mark in marks {
            if mark["type"] == "link" {
                add(&mark["attrs"]["href"]);
            }
        }
    }
    if let Some(children) = node["content"].as_array() {
        for child in children {
            note_search_metadata(child, depth + 1, output);
        }
    }
}

/// A copy of `doc` whose items omit rich note structures (marked `noteSummary`),
/// built item by item so no full copy of the large structures is made.
/// Handles both hydrated notes and lazily split `_bodySplit: true` notes with zero DB decryption.
fn summary_document(doc: &Document) -> Document {
    let items = doc
        .items
        .iter()
        .map(|item| match item.as_object() {
            Some(object) if object.get("_bodySplit") == Some(&Value::Bool(true)) => {
                let mut lite: serde_json::Map<String, Value> = object
                    .iter()
                    .filter(|(key, _)| {
                        !matches!(
                            key.as_str(),
                            "_bodySplit"
                                | "_bodyDigest"
                                | "_hasRichBody"
                                | "_searchMeta"
                                | "noteDocument"
                                | "noteOriginal"
                        )
                    })
                    .map(|(key, value)| (key.clone(), value.clone()))
                    .collect();
                let search_meta = object
                    .get("_searchMeta")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                if !search_meta.is_empty()
                    || object.get("_hasRichBody") == Some(&Value::Bool(true))
                    || object.get("noteFormat").and_then(Value::as_str) == Some("rich-v1")
                {
                    lite.insert("__noteSearchText".into(), json!(search_meta));
                }
                lite.insert("noteSummary".into(), Value::Bool(true));
                Value::Object(lite)
            }
            Some(object)
                if object.contains_key("noteDocument") || object.contains_key("noteOriginal") =>
            {
                let mut lite: serde_json::Map<String, Value> = object
                    .iter()
                    .filter(|(key, _)| *key != "noteDocument" && *key != "noteOriginal")
                    .map(|(key, value)| (key.clone(), value.clone()))
                    .collect();
                let mut metadata = Vec::new();
                note_search_metadata(&item["noteDocument"], 0, &mut metadata);
                // Transient interface projection; desktop strips __ fields on save.
                lite.insert("__noteSearchText".into(), json!(metadata.join("\n")));
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
    fn summaries_keep_searchable_attachment_names_and_links_without_private_metadata() {
        let note = json!({"id":"rich-search","type":"secureNote","title":"Fixture",
        "note":"Visible caption", "noteFormat":"rich-v1",
        "noteOriginal":{"source":"retained-private-original"},
        "noteDocument":{"type":"doc","content":[
            {"type":"vaultImage","attrs":{"name":"receipt-2026.png","caption":"Visible caption","attachmentId":"private-image-id","src":"private-runtime-url"}},
            {"type":"paragraph","content":[{"type":"text","text":"Documentation","marks":[{"type":"link","attrs":{"href":"https://docs.example.test/reference"}}]}]},
            {"type":"vaultAttachment","attrs":{"name":"contract.pdf","attachmentId":"private-file-id"}},
            {"type":"unknown","attrs":{"secret":"private-unknown-attribute"}}
        ]}});
        let doc = Document {
            items: vec![note.clone()],
            ..Document::default()
        };
        let summary = &summary_document(&doc).items[0];
        let search = summary["__noteSearchText"].as_str().unwrap();
        for expected in [
            "receipt-2026.png",
            "Visible caption",
            "contract.pdf",
            "https://docs.example.test/reference",
        ] {
            assert!(search.contains(expected));
        }
        for excluded in [
            "private-image-id",
            "private-runtime-url",
            "private-file-id",
            "private-unknown-attribute",
            "retained-private-original",
        ] {
            assert!(!search.contains(excluded));
        }
        assert!(summary.get("noteDocument").is_none());
        assert!(summary.get("noteOriginal").is_none());
        assert_eq!(summary["note"], note["note"]);
        assert_eq!(doc.items[0], note);
        assert!(doc.items[0].get("__noteSearchText").is_none());
    }

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

impl VaultSession {
    /// Drop the full document while retaining the encrypted connection and session.
    pub fn release_idle_document(&self) -> Result<()> {
        self.inner
            .lock()
            .map_err(|_| VaultError::Storage)?
            .release_document();
        Ok(())
    }
}
