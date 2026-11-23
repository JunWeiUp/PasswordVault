//! Wire-compatible common-relay protocol. Implemented once in `vault_core::relay_protocol`
//! (shared with the mobile clients and pinned by the common-relay vectors); the desktop
//! re-exports it so relay orchestration keeps a single import path.
pub use vault_core::relay_protocol::{
    ACCESS_HEADER, access_password, advance, canonical, configured_password, digest, hex,
    make_link, open_invitation, parse_link, payload, read_token, seal_invitation, sign_value,
    signing, text, unhex, unpack, valid_state, verify,
};
