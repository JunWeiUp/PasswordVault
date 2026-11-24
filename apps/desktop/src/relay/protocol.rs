//! Wire-compatible common-relay protocol. Implemented once in `vault_core::relay_protocol`
//! (shared with the mobile clients and pinned by the common-relay vectors); the desktop
//! re-exports it so relay orchestration keeps a single import path.
pub use vault_core::relay_protocol::{
    access_password, canonical, configured_password, digest, hex, parse_link,
    payload, text, unhex, unpack,
};
#[cfg(test)]
pub use vault_core::relay_protocol::{
    advance, make_link, open_invitation, read_token, seal_invitation, sign_value, signing,
    verify,
};
