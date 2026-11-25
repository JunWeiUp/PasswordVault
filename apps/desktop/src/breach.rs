//! Thin desktop bridge to `vault_core::breach_range` so UI tests can substitute
//! the network boundary without holding the vault session lock.

use nsh_core::prelude::*;

/// Opt-in Have I Been Pwned k-anonymity range lookup (5-hex SHA-1 prefix only).
#[module]
pub struct Breach;

#[module]
impl Breach {
    /// The padded range response for one prefix (five uppercase hex digits).
    pub async fn range(prefix: String) -> Result<String, String> {
        blocking(move || {
            vault_core::breach_range(prefix).map_err(|e| match e {
                vault_core::VaultError::InvalidData => "InvalidData".to_string(),
                _ => "Network".to_string(),
            })
        })
        .await
        .map_err(|_| "Network".to_string())?
    }
}
