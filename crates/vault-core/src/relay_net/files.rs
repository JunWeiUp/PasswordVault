//! Relay file transfers on the official SDK: its secretstream outer layer (descriptor sealed
//! in the `file` envelope) around PasswordVault's CryptoKit-compatible AES-GCM inner layer
//! (`passwordvault.sync.v1`). The SDK stages ciphertext in files; vault-core keeps an
//! in-memory API, staging only ciphertext in a private temporary directory.
use super::{code, invalid, runtime, sdk_identity, Result};
use crate::relay_protocol::{text, unhex, Identity};
use aes_gcm::{aead::Aead, Aes256Gcm, KeyInit, Nonce};
use common_relay::{FileDescriptor, FileInfo, RelayFiles};
use serde_json::{json, Value};
use zeroize::Zeroizing;

pub const MAX: usize = 768 * 1024 * 1024;

fn random(n: usize) -> Zeroizing<Vec<u8>> {
    let mut bytes = Zeroizing::new(vec![0u8; n]);
    getrandom::getrandom(&mut bytes).expect("system randomness");
    bytes
}

fn staging() -> Result<tempfile::TempDir> {
    tempfile::Builder::new()
        .prefix("pv-relay-file-")
        .tempdir()
        .map_err(|_| "Storage".into())
}

fn io<T, E>(r: std::result::Result<T, E>) -> Result<T> {
    r.map_err(|_| "Storage".into())
}

/// Encrypts `plain` for `to`; returns the upload descriptor and the staged ciphertext.
pub fn prepare(i: &Identity, to: &str, plain: &[u8]) -> Result<(Value, Vec<u8>)> {
    if plain.len() > MAX {
        return Err("RelayFileTooLarge".into());
    }
    let key = random(32);
    let nonce = random(12);
    let aes = Aes256Gcm::new_from_slice(&key).map_err(|_| "InvalidData")?;
    let mut inner = Zeroizing::new(nonce.to_vec());
    inner.extend(
        aes.encrypt(Nonce::from_slice(&nonce), plain)
            .map_err(|_| "Authentication")?,
    );
    let dir = staging()?;
    let (source, staged) = (dir.path().join("inner"), dir.path().join("staged"));
    io(std::fs::write(&source, &*inner))?;
    let metadata = json!({"format":"passwordvault.sync.v1","key":crate::relay_protocol::hex(&key)});
    let d = common_relay::prepare_file(&sdk_identity(i)?, to, &source, &staged, metadata)
        .map_err(code)?;
    let cipher = io(std::fs::read(&staged))?;
    Ok((
        json!({"id":d.id,"to":d.to,"size":d.size,"sha256":d.sha256,"metadata":d.metadata}),
        cipher,
    ))
}

fn info(descriptor: &Value, from: &str) -> Result<FileInfo> {
    Ok(FileInfo {
        id: text(descriptor, "id")?.into(),
        to: descriptor["to"].as_str().unwrap_or("").into(),
        from: from.into(),
        size: descriptor["size"].as_u64().ok_or("InvalidData")?,
        metadata: text(descriptor, "metadata")?.into(),
        sha256: text(descriptor, "sha256")?.into(),
        ..FileInfo::default()
    })
}

/// Verifies and decrypts a downloaded file from `from`.
pub fn decrypt(
    i: &Identity,
    from: &str,
    descriptor: &Value,
    cipher: &[u8],
) -> Result<Zeroizing<Vec<u8>>> {
    if cipher.len() > MAX || descriptor["size"].as_u64() != Some(cipher.len() as u64) {
        return invalid();
    }
    let dir = staging()?;
    let (staged, inner_path) = (dir.path().join("staged"), dir.path().join("inner"));
    io(std::fs::write(&staged, cipher))?;
    let metadata = common_relay::decrypt_file(
        &sdk_identity(i)?,
        from,
        &info(descriptor, from)?,
        &staged,
        &inner_path,
    )
    .map_err(code)?;
    let inner = Zeroizing::new(io(std::fs::read(&inner_path))?);
    if inner.len() < 28 || metadata["format"] != "passwordvault.sync.v1" {
        return invalid();
    }
    let key = Zeroizing::new(unhex(text(&metadata, "key")?)?);
    let aes = Aes256Gcm::new_from_slice(&key).map_err(|_| "InvalidData")?;
    Ok(Zeroizing::new(
        aes.decrypt(Nonce::from_slice(&inner[..12]), &inner[12..])
            .map_err(|_| "Authentication")?,
    ))
}

/// HTTPS file API on the SDK's `RelayFiles`. `check` runs around each request so a caller can
/// abort a transfer (e.g. when the vault locks).
pub struct Files<'a> {
    files: RelayFiles,
    check: &'a dyn Fn() -> Result<()>,
}

fn descriptor(d: &Value) -> Result<FileDescriptor> {
    Ok(FileDescriptor {
        id: text(d, "id")?.into(),
        to: text(d, "to")?.into(),
        size: d["size"].as_u64().ok_or("InvalidData")?,
        metadata: text(d, "metadata")?.into(),
        sha256: text(d, "sha256")?.into(),
    })
}

impl<'a> Files<'a> {
    pub fn new(
        url: &str,
        token: &str,
        password: Option<&str>,
        local: bool,
        check: &'a dyn Fn() -> Result<()>,
    ) -> Result<Self> {
        let options = common_relay::Options {
            allow_local_test: local,
            password: password.map(str::to_owned),
        };
        let files = RelayFiles::for_relay_endpoint(url, token, options).map_err(code)?;
        Ok(Self { files, check })
    }

    pub fn upload(&self, d: &Value, cipher: &[u8]) -> Result<()> {
        (self.check)()?;
        let dir = staging()?;
        let staged = dir.path().join("staged");
        io(std::fs::write(&staged, cipher))?;
        runtime()
            .block_on(self.files.upload(&descriptor(d)?, &staged))
            .map_err(code)?;
        (self.check)()
    }

    pub fn inbox(&self) -> Result<Vec<Value>> {
        (self.check)()?;
        let list = runtime().block_on(self.files.inbox()).map_err(code)?;
        list.into_iter()
            .map(|f| serde_json::to_value(f).map_err(|_| "InvalidData".into()))
            .collect()
    }

    pub fn download(&self, d: &Value) -> Result<Vec<u8>> {
        (self.check)()?;
        let info: FileInfo = serde_json::from_value(d.clone()).map_err(|_| "InvalidData")?;
        if info.size as usize > MAX {
            return Err("RelayFileTooLarge".into());
        }
        let dir = staging()?;
        let staged = dir.path().join("staged");
        runtime()
            .block_on(self.files.download(&info, &staged))
            .map_err(code)?;
        let cipher = io(std::fs::read(&staged))?;
        (self.check)()?;
        Ok(cipher)
    }

    pub fn acknowledge(&self, id: &str) -> Result<()> {
        (self.check)()?;
        runtime().block_on(self.files.delete(id)).map_err(code)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::relay_protocol::box_keypair;

    #[test]
    fn prepared_files_decrypt_only_for_the_recipient() {
        let (ap, a) = box_keypair();
        let (bp, b) = box_keypair();
        let alice = Identity {
            app: "passwordvault".into(),
            group: "g".into(),
            device: "a".into(),
            secret: a,
            trusted: [("b".into(), bp)].into(),
        };
        let bob = Identity {
            app: "passwordvault".into(),
            group: "g".into(),
            device: "b".into(),
            secret: b,
            trusted: [("a".into(), ap)].into(),
        };
        let plain = vec![9u8; 200_000];
        let (descriptor, cipher) = prepare(&alice, "b", &plain).unwrap();
        assert_eq!(&*decrypt(&bob, "a", &descriptor, &cipher).unwrap(), &plain);
        let mut tampered = cipher.clone();
        tampered[100] ^= 1;
        assert!(decrypt(&bob, "a", &descriptor, &tampered).is_err());
        assert!(decrypt(&alice, "b", &descriptor, &cipher).is_err());
    }
}
