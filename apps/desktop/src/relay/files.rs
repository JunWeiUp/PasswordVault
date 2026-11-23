//! Relay file transfers are implemented once in `vault_core::relay_net::files` (secretstream
//! outer layer + AES-GCM `passwordvault.sync.v1` inner layer, shared with Android and iOS);
//! the desktop re-exports them for its runtime.
pub use vault_core::relay_net::files::{Files, decrypt, prepare};
