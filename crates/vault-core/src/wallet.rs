//! Existing ETH/EVM derivation: BIP39 -> m/44'/60'/0'/0/0 -> EIP-55 address.
//! No signing, network calls, balances, or transactions are exposed.
use crate::{random_bytes, Result, VaultError};
use bip32::{secp256k1::ecdsa::SigningKey, XPrv};
use bip39::{Language, Mnemonic};
use serde_json::{json, Value};
use sha3::{Digest, Keccak256};
use zeroize::Zeroizing;

pub fn evm_address(private: &[u8]) -> Result<String> {
    let key = SigningKey::from_slice(private).map_err(|_| VaultError::InvalidData)?;
    let public = key.verifying_key().to_encoded_point(false);
    let hash = Keccak256::digest(&public.as_bytes()[1..]);
    let address = hex::encode(&hash[12..]);
    let checksum = hex::encode(Keccak256::digest(address.as_bytes()));
    let checksummed: String = address
        .chars()
        .zip(checksum.chars())
        .map(|(c, h)| {
            if h.to_digit(16).unwrap() >= 8 {
                c.to_ascii_uppercase()
            } else {
                c
            }
        })
        .collect();
    Ok(format!("0x{checksummed}"))
}
pub fn wallet(request: &Value) -> Result<Value> {
    let generated = request["generate"] == true;
    let phrase = if generated {
        let entropy = Zeroizing::new(random_bytes::<16>());
        Some(Zeroizing::new(
            Mnemonic::from_entropy(entropy.as_ref())
                .map_err(|_| VaultError::InvalidData)?
                .to_string(),
        ))
    } else {
        request["mnemonic"]
            .as_str()
            .filter(|s| !s.trim().is_empty())
            .map(|s| Zeroizing::new(s.trim().to_owned()))
    };
    let private = if let Some(phrase) = &phrase {
        if phrase.len() > 1024 {
            return Err(VaultError::InvalidData);
        }
        let mnemonic = Mnemonic::parse_in(Language::English, phrase.as_str())
            .map_err(|_| VaultError::InvalidData)?;
        let seed = Zeroizing::new(mnemonic.to_seed(""));
        let key = XPrv::derive_from_path(
            seed.as_ref(),
            &"m/44'/60'/0'/0/0"
                .parse()
                .map_err(|_| VaultError::InvalidData)?,
        )
        .map_err(|_| VaultError::InvalidData)?;
        Zeroizing::new(key.private_key().to_bytes().to_vec())
    } else {
        let input = request["privateKey"]
            .as_str()
            .ok_or(VaultError::InvalidData)?
            .trim();
        let bytes = hex::decode(input.strip_prefix("0x").unwrap_or(input))
            .map_err(|_| VaultError::InvalidData)?;
        Zeroizing::new(bytes)
    };
    let address = evm_address(&private)?;
    Ok(
        json!({"privateKey":hex::encode(private.as_slice()),"address":address,"mnemonic":phrase.as_ref().map(|s|s.as_str()),"network":"ETH"}),
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn derives_public_fixture_and_rejects_invalid_scalars() {
        // Public Hardhat development vector: never use this phrase for funds.
        let fixture =
            json!({"mnemonic":"test test test test test test test test test test test junk"});
        assert_eq!(
            wallet(&fixture).unwrap()["address"],
            "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
        );
        assert!(evm_address(&[0; 32]).is_err());
        assert!(evm_address(&[255; 32]).is_err());
        assert!(wallet(&json!({"mnemonic":"test test"})).is_err());
    }
}
