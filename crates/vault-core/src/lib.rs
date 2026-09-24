#[cfg(feature = "browser")]
mod browser;
mod crypto;
mod legacy;
#[cfg(feature = "native")]
mod legacy_database;
mod model;
#[cfg(feature = "native")]
mod native;
mod sharing;
mod utilities;

pub use crypto::*;
pub use legacy::*;
pub use model::*;
#[cfg(feature = "native")]
pub use native::*;
pub use sharing::*;
pub use utilities::*;

#[derive(Debug, thiserror::Error)]
#[cfg_attr(feature = "native", derive(uniffi::Error))]
pub enum VaultError {
    #[error("Vault is locked")]
    Locked,
    #[error("Incorrect password or damaged encrypted data")]
    Authentication,
    #[error("Invalid or unsupported data")]
    InvalidData,
    #[error("Vault already exists")]
    AlreadyExists,
    #[error("Vault is in use by another process")]
    InUse,
    #[error("Storage operation failed; existing data was retained")]
    Storage,
    #[error("Operation is not supported")]
    Unsupported,
}

pub type Result<T> = std::result::Result<T, VaultError>;

#[cfg(feature = "native")]
uniffi::setup_scaffolding!();

mod wallet;
pub use wallet::*;
