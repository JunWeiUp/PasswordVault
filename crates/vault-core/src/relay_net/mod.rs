//! Relay transport for every native client (desktop, Android, iOS). The WSS message client,
//! delivery journal and encrypted files come from the official Common Relay Rust SDK
//! (`common_relay`); this module adapts them to vault-core's synchronous API and relay
//! error codes (`RelayConnection`, `RelayHttp401`, `InvalidData`, ...), interpreted by
//! `relay_protocol::policy`. The group HTTP transport (`http`) still serves vault-core's
//! own group state machine.
pub mod connection;
pub mod ffi;
pub mod files;
pub mod http;
pub mod mesh_sync;
pub use common_relay::Journal;
pub mod journal {
    pub use common_relay::Journal;
}

pub type Result<T> = std::result::Result<T, String>;

pub(crate) fn invalid<T>() -> Result<T> {
    Err("InvalidData".into())
}

/// Shared runtime driving the async SDK; calls block the caller's thread.
pub(crate) fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("relay-io")
            .enable_all()
            .build()
            .expect("relay runtime")
    })
}

/// SDK failures as vault-core relay codes.
pub(crate) fn code(error: common_relay::Error) -> String {
    use common_relay::Error as E;
    match error {
        E::Http(status) => format!("RelayHttp{status}"),
        E::Relay(code) => code,
        E::Timeout => "Timeout".into(),
        E::Connection(_) => "RelayConnection".into(),
        E::Storage(_) => "Storage".into(),
        E::Invalid(message) if message.starts_with("last manager") => "LastManager".into(),
        E::Invalid(_) | E::Crypto(_) | E::Protocol(_) => "InvalidData".into(),
    }
}

/// vault-core's identity as an SDK identity (same keys, same pinned peers).
pub(crate) fn sdk_identity(i: &crate::relay_protocol::Identity) -> Result<common_relay::Identity> {
    let trusted: Vec<(String, String)> = i
        .trusted
        .iter()
        .map(|(device, key)| (device.clone(), crate::relay_protocol::hex(&key.0)))
        .collect();
    common_relay::Identity::new(
        &i.app,
        &i.group,
        &i.device,
        &crate::relay_protocol::hex(&i.secret.0),
        trusted,
    )
    .map_err(code)
}
