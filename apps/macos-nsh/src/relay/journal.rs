//! Encrypted delivery journal, scoped to group/device/sender/id and never plaintext.
use super::{Result, groups::now, invalid, protocol::*, service, transport::Identity};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use sodiumoxide::crypto::{hash::sha256, secretbox};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};
use vault_core::VaultSession;
struct Journal {
    directory: PathBuf,
    key: secretbox::Key,
    group: Value,
    device: Value,
}
impl Journal {
    fn open(s: &VaultSession, base: &Path) -> Result<Self> {
        let c = service::read(s)?;
        if c["group"].as_str().unwrap_or("").is_empty() { return Err("NotEnrolled".into()); }
        let secret = zeroize::Zeroizing::new(
            STANDARD
                .decode(text(&c, "secret")?)
                .map_err(|_| "InvalidData")?,
        );
        if secret.len() != 32 {
            return invalid();
        }
        let mut context = zeroize::Zeroizing::new(b"passwordvault/nsh-relay-journal/v1\0".to_vec());
        context.extend_from_slice(&secret);
        let key = secretbox::Key::from_slice(&sha256::hash(&context).0).ok_or("InvalidData")?;
        let directory = base.join("vault/relay-private/nsh-journal");
        for path in [
            base.to_path_buf(),
            base.join("vault"),
            base.join("vault/relay-private"),
            directory.clone(),
        ] {
            if let Ok(meta) = fs::symlink_metadata(&path) {
                if meta.file_type().is_symlink() || !meta.is_dir() {
                    return invalid();
                }
            }
        }
        fs::create_dir_all(&directory).map_err(|_| "Storage")?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
            .map_err(|_| "Storage")?;
        Ok(Self {
            directory,
            key,
            group: c["group"].clone(),
            device: c["device"].clone(),
        })
    }
    fn id(&self, kind: &str, sender: &str, id: &str) -> String {
        digest(&canonical(&json!([
            self.group,
            self.device,
            kind,
            sender,
            id
        ])))
    }
    fn path(&self, id: &str) -> PathBuf {
        self.directory.join(format!("{id}.enc"))
    }
    fn read(&self, id: &str) -> Result<Option<Value>> {
        let path = self.path(id);
        match fs::symlink_metadata(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Ok(m) if m.file_type().is_symlink() || !m.is_file() || m.len() > 512 * 1024 => {
                return invalid();
            }
            Err(_) => return Err("Storage".into()),
            _ => {}
        }
        let raw = fs::read(path).map_err(|_| "Storage")?;
        if raw.len() < 40 {
            return invalid();
        }
        let nonce = secretbox::Nonce::from_slice(&raw[..24]).ok_or("InvalidData")?;
        let plain = zeroize::Zeroizing::new(
            secretbox::open(&raw[24..], &nonce, &self.key).map_err(|_| "Authentication")?,
        );
        let v: Value = serde_json::from_slice(&plain).map_err(|_| "InvalidData")?;
        if v["id"] != id || v["version"] != 1 || !v["record"].is_object() {
            return invalid();
        }
        Ok(Some(v["record"].clone()))
    }
    fn write(&self, id: &str, v: Value) -> Result<()> {
        let path = self.path(id);
        if fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink()) {
            return invalid();
        }
        let plain = zeroize::Zeroizing::new(canonical(&json!({"version":1,"id":id,"record":v})));
        let nonce = secretbox::gen_nonce();
        let mut bytes = nonce.0.to_vec();
        bytes.extend(secretbox::seal(&plain, &nonce, &self.key));
        let temp = self
            .directory
            .join(format!(".{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| {
            let mut f = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temp)
                .map_err(|_| "Storage")?;
            f.write_all(&bytes).map_err(|_| "Storage")?;
            f.sync_all().map_err(|_| "Storage")?;
            fs::rename(&temp, &path).map_err(|_| "Storage")?;
            fs::File::open(&self.directory)
                .and_then(|f| f.sync_all())
                .map_err(|_| "Storage")?;
            Ok(())
        })();
        let _ = fs::remove_file(temp);
        result
    }
}
pub fn prepare(
    s: &VaultSession,
    base: &Path,
    identity: &Identity,
    to: &str,
    id: &str,
    data: &[u8],
) -> Result<Option<Value>> {
    let _guard = service::CONTROL.lock().map_err(|_| "Storage")?;
    let j = Journal::open(s, base)?;
    if j.group != identity.group || j.device != identity.device { return Err("RelayIdentityChanged".into()); }
    let k = j.id("out", "", id);
    let hash = digest(data);
    if let Some(old) = j.read(&k)? {
        if old["to"] != to || old["digest"] != hash {
            return Err("MessageIdConflict".into());
        }
        if old["status"] == "received" {
            return Ok(None);
        }
        if old["expires"].as_u64().unwrap_or(0) <= now() {
            return Err("MessageExpired".into());
        }
        return Ok(Some(
            json!({"type":"message","id":id,"to":to,"body":old["body"],"expires":old["expires"],"offline":true}),
        ));
    }
    let expires = now() + 86400;
    let body = identity.seal(
        to,
        "message",
        id,
        json!({"data":STANDARD.encode(data),"expires":expires}),
    )?;
    j.write(&k,json!({"to":to,"digest":hash,"body":body,"expires":expires,"purge":expires+7*86400,"status":"pending"}))?;
    Ok(Some(
        json!({"type":"message","id":id,"to":to,"body":body,"expires":expires,"offline":true}),
    ))
}
pub fn complete(s: &VaultSession, base: &Path, id: &str) -> Result<()> {
    let _guard = service::CONTROL.lock().map_err(|_| "Storage")?;
    let j = Journal::open(s, base)?;
    let k = j.id("out", "", id);
    if let Some(mut v) = j.read(&k)? {
        v.as_object_mut().unwrap().remove("body");
        v["status"] = json!("received");
        v["purge"] = json!(now() + 7 * 86400);
        j.write(&k, v)?;
    }
    Ok(())
}
pub fn seen(s: &VaultSession, base: &Path, from: &str, id: &str) -> Result<bool> {
    let j = Journal::open(s, base)?;
    Ok(j.read(&j.id("in", from, id))?
        .is_some_and(|v| v["purge"].as_u64().unwrap_or(0) > now()))
}
pub fn acknowledge(s: &VaultSession, base: &Path, from: &str, id: &str) -> Result<()> {
    if from.is_empty() || id.is_empty() {
        return invalid();
    }
    let _guard = service::CONTROL.lock().map_err(|_| "Storage")?;
    let j = Journal::open(s, base)?;
    j.write(&j.id("in", from, id), json!({"purge":now()+7*86400}))
}
pub fn cleanup(s: &VaultSession, base: &Path) -> Result<()> {
    let _guard = service::CONTROL.lock().map_err(|_| "Storage")?;
    let j = Journal::open(s, base)?;
    let mut changed = 0;
    for entry in fs::read_dir(&j.directory).map_err(|_| "Storage")? {
        let entry = entry.map_err(|_| "Storage")?;
        let filename = entry.file_name();
        let filename = filename.to_string_lossy();
        let Some(id) = filename.strip_suffix(".enc") else {
            continue;
        };
        if id.len() != 64 || unhex(id).is_err() {
            continue;
        }
        if let Some(mut v) = j.read(id)? {
            if v["purge"].as_u64().ok_or("InvalidData")? <= now() {
                fs::remove_file(j.path(id)).map_err(|_| "Storage")?;
                changed += 1;
            } else if v["status"] == "pending" && v["expires"].as_u64().unwrap_or(0) <= now() {
                v.as_object_mut().unwrap().remove("body");
                v["status"] = json!("expired");
                j.write(id, v)?;
                changed += 1;
            }
        }
        if changed >= 256 {
            break;
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn relay_journal_restart_duplicate_conflict_and_lock_denial() {
        sodiumoxide::init().unwrap();
        let root = PathBuf::from("/tmp").join(format!("pv-relay-journal-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        let mut s = VaultSession::new(root.to_string_lossy().into()).unwrap();
        service::core(
            &s,
            json!({"op":"create","password":"synthetic-relay-test-password"}),
        )
        .unwrap();
        service::write(
            &s,
            &json!({"group":"qa","device":"a","secret":STANDARD.encode([1;32])}),
        )
        .unwrap();
        let (_, secret) = sodiumoxide::crypto::box_::gen_keypair();
        let (peer, _) = sodiumoxide::crypto::box_::gen_keypair();
        let i = Identity {
            app: "passwordvault".into(),
            group: "qa".into(),
            device: "a".into(),
            secret,
            trusted: [("b".into(), peer)].into(),
        };
        let first = prepare(&s, &root, &i, "b", "id", b"synthetic payload")
            .unwrap()
            .unwrap();
        assert!(prepare(&s, &root, &i, "b", "id", b"changed payload").is_err());
        drop(s);
        s = VaultSession::new(root.to_string_lossy().into()).unwrap();
        service::core(
            &s,
            json!({"op":"unlock","password":"synthetic-relay-test-password"}),
        )
        .unwrap();
        assert_eq!(
            prepare(&s, &root, &i, "b", "id", b"synthetic payload")
                .unwrap()
                .unwrap(),
            first
        );
        complete(&s, &root, "id").unwrap();
        assert!(
            prepare(&s, &root, &i, "b", "id", b"synthetic payload")
                .unwrap()
                .is_none()
        );
        acknowledge(&s, &root, "b", "incoming").unwrap();
        assert!(seen(&s, &root, "b", "incoming").unwrap());
        assert!(!seen(&s, &root, "other", "incoming").unwrap());
        let j = Journal::open(&s, &root).unwrap();
        let k = j.id("out", "", "id");
        let disk = fs::read(j.path(&k)).unwrap();
        assert!(!String::from_utf8_lossy(&disk).contains("synthetic payload"));
        let mut bad = disk;
        bad[30] ^= 1;
        fs::write(j.path(&k), bad).unwrap();
        assert!(prepare(&s, &root, &i, "b", "id", b"synthetic payload").is_err());
        service::core(&s, json!({"op":"lock"})).unwrap();
        assert!(acknowledge(&s, &root, "b", "uncommitted").is_err());
        drop(s);
        fs::remove_dir_all(root).unwrap();
    }
}
