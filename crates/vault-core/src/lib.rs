mod archive;
#[cfg(feature = "browser")]
mod browser;
mod crypto;
mod devices;
mod import;
mod legacy;
#[cfg(feature = "native")]
mod legacy_database;
mod model;
#[cfg(feature = "native")]
mod native;
mod passkey;
pub mod peer_sync;
mod recovery;
mod security;
mod share_link;
mod sharing;
mod structured;
mod utilities;

pub use crypto::*;
pub use devices::*;
pub use import::*;
pub use legacy::*;
pub use model::*;
#[cfg(feature = "native")]
pub use native::*;
pub use passkey::*;
pub use recovery::*;
pub use security::*;
pub use share_link::*;
pub use sharing::*;
pub use structured::*;
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
    #[error("Record changed on another device; review before saving")]
    StaleEdit,
    #[error("Operation is not supported")]
    Unsupported,
    #[error("Update required to open this vault format")]
    UpdateRequired,
    #[error("Explicit Devices & Services upgrade required")]
    DevicesUpgradeRequired,
    #[error("Devices & Services requires upgraded peers and capability negotiation before sync")]
    DevicesSyncBlocked,
}

pub type Result<T> = std::result::Result<T, VaultError>;

#[cfg(feature = "native")]
uniffi::setup_scaffolding!();

mod wallet;
pub use wallet::*;

#[cfg(feature = "native")]
pub mod native_file_ops;
