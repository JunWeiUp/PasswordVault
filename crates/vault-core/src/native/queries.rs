//! Rebuildable, transactionally consistent browser projections. The canonical
//! document and wire formats remain unchanged. SQLCipher protects indexes too.
use super::*;

pub(super) fn wipe_document(doc: &mut Document) {
    for value in doc
        .items
        .iter_mut()
        .chain(doc.shared_vaults.iter_mut())
        .chain(doc.shared_members.iter_mut())
    {
        wipe_value(value);
    }
    wipe_value(&mut doc.settings);
}
fn key(root: &[u8; 32]) -> Secret {
    subkey(root, b"browser-query-records-v1")
}
fn encode(root: &[u8; 32], aad: &str, value: &Value) -> Result<Vec<u8>> {
    let bytes = Zeroizing::new(serde_json::to_vec(value).map_err(|_| VaultError::InvalidData)?);
    serde_json::to_vec(&seal(&key(root), &bytes, aad.as_bytes())?)
        .map_err(|_| VaultError::InvalidData)
}
fn decode(root: &[u8; 32], aad: &str, bytes: &[u8]) -> Result<Value> {
    let sealed = serde_json::from_slice(bytes).map_err(|_| VaultError::InvalidData)?;
    let plain = Zeroizing::new(unseal(&key(root), &sealed, aad.as_bytes())?);
    serde_json::from_slice(&plain).map_err(|_| VaultError::InvalidData)
}
fn active_passwords(doc: &Document) -> impl Iterator<Item = (usize, &Value)> {
    doc.items
        .iter()
        .enumerate()
        .filter(|(_, item)| item["type"] == "password" && item["isDeleted"] != true)
}

fn same_browser_projection_inputs(a: &Document, b: &Document) -> bool {
    if a.format_version != b.format_version || a.settings != b.settings {
        return false;
    }
    let mut ia = active_passwords(a);
    let mut ib = active_passwords(b);
    loop {
        match (ia.next(), ib.next()) {
            (None, None) => return true,
            (Some((oa, va)), Some((ob, vb))) if oa == ob && va == vb => continue,
            _ => return false,
        }
    }
}

/// Skips full password projection re-encryption when only non-password entries (such as
/// notes or wallets) changed, updating only `browser_query_revision` to stay current.
pub(super) fn update_incremental(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    previous: Option<&Document>,
    next: &Document,
) -> Result<()> {
    if let Some(prev) = previous {
        if same_browser_projection_inputs(prev, next) {
            let count: i64 = storage(conn.query_row(
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('browser_query_revision','browser_query_items','browser_query_hosts','browser_query_settings')",
                [],
                |r| r.get(0),
            ))?;
            if count == 4 {
                storage(conn.execute(
                    "INSERT OR REPLACE INTO browser_query_revision VALUES(1,?1)",
                    [revision(conn)?],
                ))?;
                return Ok(());
            }
        }
    }
    rebuild(conn, root, vault, next)
}

pub(super) fn rebuild(
    conn: &Connection,
    root: &[u8; 32],
    vault: &str,
    doc: &Document,
) -> Result<()> {
    storage(conn.execute_batch("CREATE TABLE IF NOT EXISTS browser_query_items(id TEXT PRIMARY KEY,payload BLOB NOT NULL,ordinal INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS browser_query_hosts(host TEXT NOT NULL,id TEXT NOT NULL,PRIMARY KEY(host,id)); CREATE TABLE IF NOT EXISTS browser_query_revision(id INTEGER PRIMARY KEY,digest BLOB NOT NULL); CREATE TABLE IF NOT EXISTS browser_query_settings(id INTEGER PRIMARY KEY,payload BLOB NOT NULL); DELETE FROM browser_query_hosts; DELETE FROM browser_query_items; DELETE FROM browser_query_settings;"))?;
    storage(conn.execute(
        "INSERT INTO browser_query_settings VALUES(1,?1)",
        [encode(
            root,
            &format!("{vault}:settings"),
            &json!({"settings":doc.settings,"formatVersion":doc.format_version}),
        )?],
    ))?;
    for (ordinal, item) in doc.items.iter().enumerate() {
        if item["type"] != "password" || item["isDeleted"] == true {
            continue;
        }
        let id = item["id"].as_str().ok_or(VaultError::InvalidData)?;
        storage(conn.execute(
            "INSERT INTO browser_query_items VALUES(?1,?2,?3)",
            rusqlite::params![
                id,
                encode(root, &format!("{vault}:item:{id}"), item)?,
                ordinal as i64
            ],
        ))?;
        if let Some(urls) = item["url"].as_str() {
            for entry in urls.split(|c: char| c.is_whitespace() || c == ',') {
                if let Ok(url) =
                    url::Url::parse(entry).or_else(|_| url::Url::parse(&format!("https://{entry}")))
                {
                    if let Some(host) = url
                        .host_str()
                        .filter(|_| matches!(url.scheme(), "http" | "https"))
                    {
                        storage(conn.execute(
                            "INSERT OR IGNORE INTO browser_query_hosts VALUES(?1,?2)",
                            rusqlite::params![host, id],
                        ))?;
                    }
                }
            }
        }
    }
    storage(conn.execute(
        "INSERT OR REPLACE INTO browser_query_revision VALUES(1,?1)",
        [revision(conn)?],
    ))?;
    Ok(())
}
fn revision(conn: &Connection) -> Result<Vec<u8>> {
    let bytes: Vec<u8> = storage(conn.query_row(
        "SELECT payload FROM vault_state WHERE id=1",
        [],
        |r| r.get(0),
    ))?;
    Ok(Sha256::digest(&bytes).to_vec())
}
pub(super) fn current(conn: &Connection, root: &[u8; 32], vault: &str) -> Result<bool> {
    let count: i64 = storage(conn.query_row("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('browser_query_revision','browser_query_items','browser_query_hosts','browser_query_settings')", [], |r|r.get(0)))?;
    if count != 4 {
        return Ok(false);
    }
    let bytes = conn.query_row(
        "SELECT payload FROM browser_query_settings WHERE id=1",
        [],
        |r| r.get::<_, Vec<u8>>(0),
    );
    let meta = match bytes
        .ok()
        .and_then(|bytes| decode(root, &format!("{vault}:settings"), &bytes).ok())
    {
        Some(meta) => meta,
        None => return Ok(false),
    };
    let Some(format) = meta["formatVersion"].as_u64() else {
        return Ok(false);
    };
    if (format == 5 || meta["settings"]["entryHistoryEnabled"] == true) && !history::enabled(conn)?
    {
        return Err(VaultError::InvalidData);
    }
    let saved = conn.query_row(
        "SELECT digest FROM browser_query_revision WHERE id=1",
        [],
        |r| r.get::<_, Vec<u8>>(0),
    );
    Ok(saved.is_ok_and(|digest| revision(conn).is_ok_and(|actual| actual == digest)))
}
pub(super) fn query(conn: &Connection, root: &[u8; 32], vault: &str, req: &Value) -> Result<Value> {
    if req["op"] == "read-settings" {
        let bytes: Vec<u8> = storage(conn.query_row(
            "SELECT payload FROM browser_query_settings WHERE id=1",
            [],
            |r| r.get(0),
        ))?;
        let mut meta = decode(root, &format!("{vault}:settings"), &bytes)?;
        return Ok(meta["settings"].take());
    }
    let origin = req["origin"].as_str().ok_or(VaultError::InvalidData)?;
    let url = url::Url::parse(origin).map_err(|_| VaultError::InvalidData)?;
    let host = url
        .host_str()
        .filter(|_| matches!(url.scheme(), "http" | "https"))
        .ok_or(VaultError::InvalidData)?;
    let mut statement = storage(conn.prepare("SELECT i.id,i.payload FROM browser_query_items i JOIN browser_query_hosts h ON h.id=i.id WHERE h.host=?1 AND (?2 IS NULL OR i.id=?2) ORDER BY i.ordinal"))?;
    let rows = storage(statement.query_map(
        rusqlite::params![
            host,
            if req["op"] == "fill" {
                Some(req["id"].as_str().ok_or(VaultError::InvalidData)?)
            } else {
                None
            }
        ],
        |r| Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?)),
    ))?;
    let mut items = Vec::new();
    let result = (|| {
        for row in rows {
            let (id, bytes) = storage(row)?;
            items.push(decode(root, &format!("{vault}:item:{id}"), &bytes)?);
        }
        if req["op"] == "fill" {
            fill_account(
                &items,
                origin,
                req["id"].as_str().ok_or(VaultError::InvalidData)?,
                req["accountId"].as_str(),
            )
        } else {
            matching_accounts(&items, origin)
        }
    })();
    for item in &mut items {
        wipe_value(item);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn run(v: &mut DiskVault, request: Value) -> Result<Value> {
        v.command(&request)
    }
    #[test]
    fn cold_queries_preserve_matching_and_never_load_document() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = DiskVault::new(dir.path()).unwrap();
        v.create("fixture").unwrap();
        let cases = [
            json!({"id":"z","type":"password","title":"Fixture","url":"https://example.com, http://other.test","username":"main","password":"secret","accounts":[{"id":"extra","username":"second","password":"other"}]}),
            json!({"id":"a","type":"password","title":"Fixture","url":"example.com","username":"first","password":"secret"}),
            json!({"id":"gone","type":"password","title":"Fixture","url":"example.com","isDeleted":true}),
            json!({"id":"note","type":"secureNote","title":"Note","note":"long body".repeat(10000)}),
        ];
        for item in cases {
            run(&mut v, json!({"op":"save","item":item})).unwrap();
        }
        let expected =
            matching_accounts(&v.open().unwrap().document.items, "https://example.com").unwrap();
        v.release_document();
        assert!(!v.unlocked.as_ref().unwrap().document_loaded);
        assert_eq!(
            run(
                &mut v,
                json!({"op":"matches","origin":"https://example.com"})
            )
            .unwrap(),
            expected
        );
        assert_eq!(
            run(
                &mut v,
                json!({"op":"fill","origin":"https://example.com","id":"z","accountId":"extra"})
            )
            .unwrap()["password"],
            "other"
        );
        assert!(run(
            &mut v,
            json!({"op":"fill","origin":"http://example.com","id":"z"})
        )
        .is_err());
        assert!(!v.unlocked.as_ref().unwrap().document_loaded);
        run(
            &mut v,
            json!({"op":"settings","settings":{"language":"en"}}),
        )
        .unwrap();
        v.release_document();
        assert_eq!(
            run(&mut v, json!({"op":"read-settings"})).unwrap()["language"],
            "en"
        );
        v.lock();
        v.unlock("fixture").unwrap();
        assert!(!v.unlocked.as_ref().unwrap().document_loaded);
        assert_eq!(
            run(
                &mut v,
                json!({"op":"matches","origin":"https://example.com"})
            )
            .unwrap(),
            expected
        );
    }
    #[test]
    fn recovery_projection_failure_preserves_password_and_header() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = DiskVault::new(dir.path()).unwrap();
        v.create("fixture").unwrap();
        let key = generate_recovery_key();
        run(
            &mut v,
            json!({"op":"recovery-enable","key":key,"currentPassword":"fixture"}),
        )
        .unwrap();
        v.open().unwrap().connection.execute_batch("CREATE TRIGGER fail_projection BEFORE INSERT ON browser_query_settings BEGIN SELECT RAISE(ABORT,'fixture'); END;").unwrap();
        let before = fs::read(v.directory.join("header.json")).unwrap();
        v.lock();
        assert!(run(
            &mut v,
            json!({"op":"recovery-reset-password","key":key,"newPassword":"replacement"})
        )
        .is_err());
        assert_eq!(before, fs::read(v.directory.join("header.json")).unwrap());
        v.unlock("fixture").unwrap();
        v.lock();
        assert!(v.unlock("replacement").is_err());
    }
    #[test]
    fn older_writer_invalidates_projection_and_failed_write_rolls_back() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = DiskVault::new(dir.path()).unwrap();
        v.create("fixture").unwrap();
        run(&mut v,json!({"op":"save","item":{"id":"one","type":"password","title":"Fixture","url":"example.test","password":"old"}})).unwrap();
        let open = v.open().unwrap();
        storage(open.connection.execute_batch("CREATE TRIGGER fail_projection BEFORE INSERT ON browser_query_items BEGIN SELECT RAISE(ABORT,'synthetic'); END;")).unwrap();
        assert!(run(&mut v,json!({"op":"save","item":{"id":"one","type":"password","title":"Fixture","url":"example.test","password":"new"}})).is_err());
        assert_eq!(
            run(
                &mut v,
                json!({"op":"fill","origin":"https://example.test","id":"one"})
            )
            .unwrap()["password"],
            "old"
        );
        let open = v.open().unwrap();
        open.connection
            .execute_batch("DROP TRIGGER fail_projection; DROP TABLE browser_query_revision;")
            .unwrap();
        v.lock();
        v.unlock("fixture").unwrap();
        assert_eq!(
            run(
                &mut v,
                json!({"op":"fill","origin":"https://example.test","id":"one"})
            )
            .unwrap()["password"],
            "old"
        );
    }
}
