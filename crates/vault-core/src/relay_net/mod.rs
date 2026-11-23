//! Relay transport for every native client (desktop, Android, iOS): HTTPS group/file APIs,
//! the WSS message connection and its delivery journal. Protocol rules live in
//! `crate::relay_protocol`; this module only moves bytes. Errors are relay codes
//! (`RelayConnection`, `RelayHttp401`, `InvalidData`, ...), interpreted by
//! `relay_protocol::policy`.
pub mod connection;
pub mod ffi;
pub mod files;
pub mod http;
pub mod journal;

pub type Result<T> = std::result::Result<T, String>;

pub(crate) fn invalid<T>() -> Result<T> {
    Err("InvalidData".into())
}

pub(crate) fn random_hex(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    getrandom::getrandom(&mut buf).expect("system randomness");
    crate::relay_protocol::hex(&buf)
}

pub(crate) fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
