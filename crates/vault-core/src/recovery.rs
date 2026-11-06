//! Human-transcribable, random recovery keys. Never derive these from a password.
use crate::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

pub fn generate_recovery_key() -> String {
    let entropy = Zeroizing::new(random_bytes::<32>());
    let checksum = Sha256::digest(entropy.as_ref());
    let encoded = Zeroizing::new(format!(
        "{}{}",
        hex::encode(entropy.as_ref()),
        hex::encode(&checksum[..4])
    ));
    encoded
        .as_bytes()
        .chunks(8)
        .map(|part| std::str::from_utf8(part).unwrap())
        .collect::<Vec<_>>()
        .join("-")
}

pub fn normalize_recovery_key(input: &str) -> Result<Zeroizing<String>> {
    if input.len() > 256 {
        return Err(VaultError::InvalidData);
    }
    let normalized = Zeroizing::new(
        input
            .chars()
            .filter(|c| *c != '-' && !c.is_ascii_whitespace())
            .collect::<String>()
            .to_ascii_lowercase(),
    );
    if normalized.len() != 72 {
        return Err(VaultError::InvalidData);
    }
    let bytes =
        Zeroizing::new(hex::decode(normalized.as_str()).map_err(|_| VaultError::InvalidData)?);
    let checksum = Sha256::digest(&bytes[..32]);
    if bytes[32..] != checksum[..4] {
        return Err(VaultError::InvalidData);
    }
    Ok(normalized)
}

pub fn recovery_wrapping_key(input: &str) -> Result<Secret> {
    let normalized = normalize_recovery_key(input)?;
    let bytes =
        Zeroizing::new(hex::decode(&normalized[..64]).map_err(|_| VaultError::InvalidData)?);
    let entropy = Zeroizing::new(
        <[u8; 32]>::try_from(bytes.as_slice()).map_err(|_| VaultError::InvalidData)?,
    );
    Ok(subkey(&entropy, b"offline-recovery-v1"))
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RecoveryEnvelope {
    pub(crate) format: String,
    pub(crate) version: u32,
    pub(crate) vault_id: String,
    pub(crate) wrapped_root: Sealed,
}

impl RecoveryEnvelope {
    pub(crate) fn create(key: &str, root: &[u8; 32], vault_id: String) -> Result<Self> {
        let mut envelope = Self {
            format: "PasswordVaultRecovery".into(),
            version: 1,
            vault_id,
            wrapped_root: Sealed {
                nonce: String::new(),
                ciphertext: String::new(),
            },
        };
        envelope.wrapped_root = seal(&*recovery_wrapping_key(key)?, root, &envelope.aad()?)?;
        Ok(envelope)
    }
    pub(crate) fn aad(&self) -> Result<Vec<u8>> {
        if self.format != "PasswordVaultRecovery" || self.version != 1 || self.vault_id.len() != 32
        {
            return Err(VaultError::Unsupported);
        }
        serde_json::to_vec(&(&self.format, self.version, &self.vault_id))
            .map_err(|_| VaultError::InvalidData)
    }
    pub(crate) fn unlock(&self, key: &str, vault_id: &str) -> Result<Secret> {
        if self.vault_id != vault_id {
            return Err(VaultError::Authentication);
        }
        let clear = unseal(
            &*recovery_wrapping_key(key)?,
            &self.wrapped_root,
            &self.aad()?,
        )?;
        Ok(Zeroizing::new(
            clear
                .as_slice()
                .try_into()
                .map_err(|_| VaultError::Authentication)?,
        ))
    }
}
