use crate::{Result, VaultError};
use aes_gcm::{
    aead::{Aead, KeyInit, Payload},
    Aes256Gcm, Nonce,
};
use argon2::{Algorithm, Argon2, Params, Version};
use base64::{engine::general_purpose::STANDARD, Engine};
use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use zeroize::Zeroizing;

pub const MAX_INPUT: usize = 64 * 1024 * 1024;
pub type Secret = Zeroizing<[u8; 32]>;

pub fn random_bytes<const N: usize>() -> [u8; N] {
    let mut bytes = [0; N];
    OsRng.fill_bytes(&mut bytes);
    bytes
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Kdf {
    pub salt: String,
    pub memory_kib: u32,
    pub iterations: u32,
    pub parallelism: u32,
}

impl Kdf {
    pub fn fresh() -> Self {
        Self {
            salt: STANDARD.encode(random_bytes::<16>()),
            memory_kib: 65536,
            iterations: 3,
            parallelism: 1,
        }
    }
    pub fn derive(&self, password: &str) -> Result<Secret> {
        // Bound untrusted backup parameters before allocating Argon2 memory.
        if !(8192..=131072).contains(&self.memory_kib)
            || !(1..=10).contains(&self.iterations)
            || !(1..=4).contains(&self.parallelism)
            || password.len() > 4096
        {
            return Err(VaultError::InvalidData);
        }
        let salt = STANDARD
            .decode(&self.salt)
            .map_err(|_| VaultError::InvalidData)?;
        if !(8..=64).contains(&salt.len()) {
            return Err(VaultError::InvalidData);
        }
        let params = Params::new(self.memory_kib, self.iterations, self.parallelism, Some(32))
            .map_err(|_| VaultError::InvalidData)?;
        let mut key = Zeroizing::new([0; 32]);
        Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
            .hash_password_into(password.as_bytes(), &salt, key.as_mut())
            .map_err(|_| VaultError::Authentication)?;
        Ok(key)
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Sealed {
    pub nonce: String,
    pub ciphertext: String,
}

pub fn seal(key: &[u8; 32], plaintext: &[u8], aad: &[u8]) -> Result<Sealed> {
    if plaintext.len() > MAX_INPUT {
        return Err(VaultError::InvalidData);
    }
    let nonce = random_bytes::<12>();
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| VaultError::InvalidData)?;
    let encrypted = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|_| VaultError::Authentication)?;
    Ok(Sealed {
        nonce: STANDARD.encode(nonce),
        ciphertext: STANDARD.encode(encrypted),
    })
}

pub fn unseal(key: &[u8; 32], sealed: &Sealed, aad: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    if sealed.ciphertext.len() > MAX_INPUT * 2 {
        return Err(VaultError::InvalidData);
    }
    let nonce = STANDARD
        .decode(&sealed.nonce)
        .map_err(|_| VaultError::InvalidData)?;
    if nonce.len() != 12 {
        return Err(VaultError::InvalidData);
    }
    let ciphertext = STANDARD
        .decode(&sealed.ciphertext)
        .map_err(|_| VaultError::InvalidData)?;
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| VaultError::InvalidData)?;
    cipher
        .decrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: &ciphertext,
                aad,
            },
        )
        .map(Zeroizing::new)
        .map_err(|_| VaultError::Authentication)
}

pub fn subkey(root: &[u8; 32], purpose: &[u8]) -> Secret {
    let mut output = Zeroizing::new([0; 32]);
    hkdf::Hkdf::<Sha256>::new(Some(b"PasswordVault-v2"), root)
        .expand(purpose, output.as_mut())
        .expect("fixed key length");
    output
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Header {
    pub format: String,
    pub version: u32,
    pub vault_id: String,
    pub kdf: Kdf,
    pub wrapped_key: Sealed,
}

impl Header {
    fn aad(&self) -> Result<Vec<u8>> {
        if self.format != "PasswordVault" || self.version != 2 || self.vault_id.len() != 32 {
            return Err(VaultError::Unsupported);
        }
        serde_json::to_vec(&(&self.format, self.version, &self.vault_id, &self.kdf))
            .map_err(|_| VaultError::InvalidData)
    }
    pub fn create(password: &str, root: &[u8; 32], vault_id: String) -> Result<Self> {
        if password.is_empty() {
            return Err(VaultError::InvalidData);
        }
        let kdf = Kdf::fresh();
        let kek = kdf.derive(password)?;
        let mut header = Self {
            format: "PasswordVault".into(),
            version: 2,
            vault_id,
            kdf,
            wrapped_key: Sealed {
                nonce: String::new(),
                ciphertext: String::new(),
            },
        };
        header.wrapped_key = seal(&kek, root, &header.aad()?)?;
        Ok(header)
    }
    pub fn unlock(&self, password: &str) -> Result<Secret> {
        let aad = self.aad()?;
        let kek = self.kdf.derive(password)?;
        let plaintext = unseal(&kek, &self.wrapped_key, &aad)?;
        let root: [u8; 32] = plaintext
            .as_slice()
            .try_into()
            .map_err(|_| VaultError::Authentication)?;
        Ok(Zeroizing::new(root))
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Backup {
    pub format: String,
    pub version: u32,
    pub kdf: Kdf,
    pub payload: Sealed,
}

pub fn encrypt_backup(data: &[u8], password: &str) -> Result<String> {
    if password.chars().count() < 10 {
        return Err(VaultError::InvalidData);
    }
    let kdf = Kdf::fresh();
    let key = kdf.derive(password)?;
    let aad = serde_json::to_vec(&("PasswordVaultBackup", 2, &kdf))
        .map_err(|_| VaultError::InvalidData)?;
    let backup = Backup {
        format: "PasswordVaultBackup".into(),
        version: 2,
        kdf,
        payload: seal(&key, data, &aad)?,
    };
    serde_json::to_string(&backup).map_err(|_| VaultError::InvalidData)
}

pub fn decrypt_backup(data: &str, password: &str) -> Result<Zeroizing<Vec<u8>>> {
    if data.len() > MAX_INPUT * 2 {
        return Err(VaultError::InvalidData);
    }
    let backup: Backup = serde_json::from_str(data).map_err(|_| VaultError::InvalidData)?;
    if backup.format != "PasswordVaultBackup" || backup.version != 2 {
        return Err(VaultError::Unsupported);
    }
    let key = backup.kdf.derive(password)?;
    let aad = serde_json::to_vec(&(&backup.format, backup.version, &backup.kdf))
        .map_err(|_| VaultError::InvalidData)?;
    unseal(&key, &backup.payload, &aad)
}
