//! Owner-decided relay client policy, shared by desktop, Android and iOS so the rules live
//! in one place (see the four decisions recorded for the relay unification):
//! - authentication failures (HTTP 401/403) stop retrying and ask the user;
//! - other failures back off exponentially (1 s doubling to 30 s), and the backoff resets
//!   only after a connection stayed up for at least [`STABLE_CONNECTION_SECS`];
//! - leaving a group clears local state first (the remote notice is best-effort), rotates
//!   the X25519 transport key and device ID, clears the server password and keeps the
//!   endpoint — see [`EXIT_CLEARED`] / [`exit_identity`].
use super::*;

pub const STABLE_CONNECTION_SECS: u64 = 120;
pub const MAX_BACKOFF_SECS: u64 = 30;

/// Client config fields an exit resets (to "" / empty); `endpoint` is deliberately kept.
pub const EXIT_CLEARED: [&str; 5] = ["group", "token", "hub", "password", "peers"];

/// True for errors that mean the relay rejected our credentials. Recognises the desktop
/// (`RelayHttp401`), SDK (`... (401)`, `HTTP 403`) and OkHttp WebSocket upgrade spellings.
pub fn authentication_failure(error: &str) -> bool {
    ["401", "403"].iter().any(|code| {
        error == format!("RelayHttp{code}")
            || error.contains(&format!("({code})"))
            || error.contains(&format!("HTTP {code}"))
            || error.contains(&format!("status {code}"))
            || error.contains(&format!("'{code} ")) // OkHttp: "Expected HTTP 101 response but was '401 Unauthorized'"
    })
}

/// What to do after a connection attempt ended with `error`.
#[derive(Debug, PartialEq, Eq)]
pub enum Retry {
    /// Stop reconnecting and prompt the user (rejected credentials).
    Stop,
    /// Wait this many seconds, then reconnect.
    After(u64),
}

/// `previous` is the delay used before this attempt (0 for the first), `connected` how long
/// the attempt stayed connected.
pub fn retry(error: &str, previous: u64, connected: u64) -> Retry {
    if authentication_failure(error) {
        return Retry::Stop;
    }
    if previous == 0 || connected >= STABLE_CONNECTION_SECS {
        return Retry::After(1);
    }
    Retry::After((previous * 2).min(MAX_BACKOFF_SECS))
}

/// A fresh device ID and X25519 transport secret (hex) for a client that left its group.
pub fn exit_identity() -> Result<Value> {
    let mut device = [0u8; 16];
    getrandom::getrandom(&mut device).map_err(|_| ProtocolError("Storage"))?;
    device[6] = (device[6] & 0x0f) | 0x40; // UUID v4
    device[8] = (device[8] & 0x3f) | 0x80;
    let h = hex(&device);
    let device = format!(
        "{}-{}-{}-{}-{}",
        &h[..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..]
    );
    let secret = box_keypair().1;
    let public = secret.public_key();
    Ok(
        json!({"device": device, "secret": hex(&secret.0), "publicKey": hex(&public.0), "cleared": EXIT_CLEARED}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credentials_rejections_stop_and_other_failures_back_off() {
        for error in [
            "RelayHttp401",
            "RelayHttp403",
            "HTTP 401 Unauthorized",
            "Unexpected response (403)",
        ] {
            assert_eq!(retry(error, 8, 500), Retry::Stop, "{error}");
        }
        assert_eq!(retry("RelayConnection", 0, 0), Retry::After(1));
        assert_eq!(retry("RelayConnection", 1, 3), Retry::After(2));
        assert_eq!(retry("RelayConnection", 16, 3), Retry::After(30));
        assert_eq!(retry("RelayConnection", 30, 3), Retry::After(30));
        // Reset only after a stable connection, not merely after connecting.
        assert_eq!(
            retry("RelayConnection", 30, STABLE_CONNECTION_SECS - 1),
            Retry::After(30)
        );
        assert_eq!(
            retry("RelayConnection", 30, STABLE_CONNECTION_SECS),
            Retry::After(1)
        );
        assert!(!authentication_failure("RelayHttp404"));
    }

    #[test]
    fn exit_identity_is_fresh_and_keeps_the_endpoint() {
        let a = exit_identity().unwrap();
        let b = exit_identity().unwrap();
        assert_ne!(a["device"], b["device"]);
        assert_ne!(a["secret"], b["secret"]);
        assert_eq!(a["device"].as_str().unwrap().len(), 36);
        let secret =
            BoxSecretKey::from_slice(&unhex(a["secret"].as_str().unwrap()).unwrap()).unwrap();
        assert_eq!(hex(&secret.public_key().0), a["publicKey"]);
        assert!(!EXIT_CLEARED.contains(&"endpoint"));
    }
}
