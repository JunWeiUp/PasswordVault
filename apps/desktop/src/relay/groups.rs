//! The group state machine and its HTTPS transport live in vault-core
//! (`relay_protocol::groups`, `relay_net::http`), shared with Android and iOS.
pub use vault_core::relay_net::http::Http;
pub use vault_core::relay_protocol::groups::{Groups, now};
#[cfg(test)]
pub use vault_core::relay_protocol::groups::Api;
