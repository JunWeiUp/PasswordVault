//! Delivery journal: one owner per directory. Outgoing offline messages keep their sealed
//! body until the peer's receipt; incoming ones are remembered to drop replays. Rows are
//! JSON files named by SHA-256 of `[scope, kind, sender, id]` (the former SDK layout).
use super::{now, Result};
use crate::relay_protocol::digest;
use serde_json::{json, Value};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::Mutex,
};

const RETENTION: u64 = 7 * 86400;

pub struct Journal {
    directory: PathBuf,
    lock: Mutex<()>,
}

fn storage<T, E>(r: std::result::Result<T, E>) -> Result<T> {
    r.map_err(|_| "Storage".into())
}

impl Journal {
    pub fn open(directory: &Path) -> Result<Self> {
        storage(fs::create_dir_all(directory))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(directory, fs::Permissions::from_mode(0o700));
        }
        let journal = Journal {
            directory: directory.to_owned(),
            lock: Mutex::new(()),
        };
        journal.cleanup()?;
        Ok(journal)
    }

    fn path(&self, scope: &str, kind: &str, sender: &str, id: &str) -> PathBuf {
        let key = serde_json::to_string(&json!([scope, kind, sender, id])).unwrap_or_default();
        self.directory
            .join(format!("{}.json", digest(key.as_bytes())))
    }

    fn read(path: &Path) -> Result<Option<Value>> {
        match fs::read(path) {
            Ok(raw) => Ok(Some(
                serde_json::from_slice(&raw).map_err(|_| "InvalidData")?,
            )),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(_) => Err("Storage".into()),
        }
    }

    fn write(&self, path: &Path, row: &Value) -> Result<()> {
        let mut temp = storage(tempfile::NamedTempFile::new_in(&self.directory))?;
        storage(temp.write_all(row.to_string().as_bytes()))?;
        storage(temp.as_file().sync_all())?;
        storage(temp.persist(path))?;
        Ok(())
    }

    /// Returns the stored row for an outgoing message, creating it with `seal(expires)`.
    pub fn prepare(
        &self,
        scope: &str,
        id: &str,
        to: &str,
        data: &[u8],
        ttl: u64,
        seal: impl FnOnce(u64) -> Result<String>,
    ) -> Result<Value> {
        if !(1..=86400).contains(&ttl) {
            return Err("InvalidData".into());
        }
        let _guard = self.lock.lock().map_err(|_| "Storage")?;
        let path = self.path(scope, "out", "", id);
        let hash = digest(data);
        if let Some(row) = Self::read(&path)? {
            if row["recipient"] != to || row["digest"] != hash {
                return Err("RelayMessageConflict".into());
            }
            if row["status"] == "received" {
                return Ok(row);
            }
            if row["status"] != "pending" || row["expires"].as_u64().unwrap_or(0) <= now() {
                return Err("RelayMessageExpired".into());
            }
            return Ok(row);
        }
        let expires = now() + ttl;
        let row = json!({"recipient":to,"digest":hash,"body":seal(expires)?,"expires":expires,"purge":expires + RETENTION,"status":"pending"});
        self.write(&path, &row)?;
        Ok(row)
    }

    pub fn complete(&self, scope: &str, id: &str) -> Result<()> {
        let _guard = self.lock.lock().map_err(|_| "Storage")?;
        let path = self.path(scope, "out", "", id);
        if let Some(mut row) = Self::read(&path)? {
            row.as_object_mut().map(|o| o.remove("body"));
            row["status"] = json!("received");
            row["purge"] = json!(now() + RETENTION);
            self.write(&path, &row)?;
        }
        Ok(())
    }

    pub fn contains(&self, scope: &str, sender: &str, id: &str) -> Result<bool> {
        let _guard = self.lock.lock().map_err(|_| "Storage")?;
        Ok(Self::read(&self.path(scope, "in", sender, id))?
            .is_some_and(|row| row["purge"].as_u64().unwrap_or(0) > now()))
    }

    pub fn acknowledge(&self, scope: &str, sender: &str, id: &str) -> Result<()> {
        let _guard = self.lock.lock().map_err(|_| "Storage")?;
        let path = self.path(scope, "in", sender, id);
        let current = Self::read(&path)?;
        if current.is_none_or(|row| row["purge"].as_u64().unwrap_or(0) <= now()) {
            self.write(&path, &json!({"purge": now() + RETENTION}))?;
        }
        Ok(())
    }

    pub fn cleanup(&self) -> Result<()> {
        let _guard = self.lock.lock().map_err(|_| "Storage")?;
        let mut changed = 0;
        for entry in storage(fs::read_dir(&self.directory))?.flatten() {
            if changed >= 256 {
                break;
            }
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.len() != 69
                || !name.ends_with(".json")
                || !name[..64].bytes().all(|b| b.is_ascii_hexdigit())
            {
                continue;
            }
            let Ok(Some(mut row)) = Self::read(&path) else {
                continue;
            };
            if row["purge"].as_u64().unwrap_or(0) <= now() {
                let _ = fs::remove_file(&path);
                changed += 1;
            } else if row["status"] == "pending" && row["expires"].as_u64().unwrap_or(0) <= now() {
                row.as_object_mut().map(|o| o.remove("body"));
                row["status"] = json!("expired");
                self.write(&path, &row)?;
                changed += 1;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outgoing_rows_keep_body_until_receipt_and_incoming_replays_are_remembered() {
        let dir = tempfile::tempdir().unwrap();
        let journal = Journal::open(dir.path()).unwrap();
        let row = journal
            .prepare("s", "m1", "b", b"hi", 60, |_| Ok("sealed".into()))
            .unwrap();
        assert_eq!(row["status"], "pending");
        // Same id and content reuses the stored body (no re-seal); other content conflicts.
        assert_eq!(
            journal
                .prepare("s", "m1", "b", b"hi", 60, |_| panic!("resealed"))
                .unwrap()["body"],
            "sealed"
        );
        assert!(journal
            .prepare("s", "m1", "b", b"other", 60, |_| Ok("x".into()))
            .is_err());
        journal.complete("s", "m1").unwrap();
        let done = journal
            .prepare("s", "m1", "b", b"hi", 60, |_| panic!())
            .unwrap();
        assert_eq!(done["status"], "received");
        assert!(done.get("body").is_none());
        assert!(!journal.contains("s", "a", "m2").unwrap());
        journal.acknowledge("s", "a", "m2").unwrap();
        assert!(journal.contains("s", "a", "m2").unwrap());
        assert!(!journal.contains("other", "a", "m2").unwrap());
        assert!(journal
            .prepare("s", "m3", "b", b"x", 0, |_| Ok("x".into()))
            .is_err());
    }
}
