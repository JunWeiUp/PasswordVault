//! Unified desktop event bus replacing high-frequency UI polling loops.
//!
//! Producers call [`notify`] with a lightweight topic (`"hotkey"`, `"browser"`, `"ai"`,
//! `"relay"`, `"status"`). The TSX UI holds a single long-poll (`Events.waitLocal` and,
//! on macOS with `pv-background`, `Events.waitService`) that sleeps on a `Condvar` until
//! any topic fires or the timeout elapses — eliminating 200ms–1000ms idle IPC wakeups.
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    sync::{Condvar, Mutex, OnceLock},
    time::{Duration, Instant},
};

#[cfg(feature = "ui")]
use nsh_core::prelude::*;

const MAX_HISTORY: usize = 64;

struct BusState {
    rev: u32,
    history: VecDeque<(u32, &'static str)>,
}

struct EventBus {
    state: Mutex<BusState>,
    cv: Condvar,
}

fn bus() -> &'static EventBus {
    static BUS: OnceLock<EventBus> = OnceLock::new();
    BUS.get_or_init(|| EventBus {
        state: Mutex::new(BusState {
            rev: 0,
            history: VecDeque::with_capacity(MAX_HISTORY),
        }),
        cv: Condvar::new(),
    })
}

/// Publishes an event topic and wakes all waiting long-polls immediately.
pub fn notify(topic: &'static str) {
    let b = bus();
    if let Ok(mut st) = b.state.lock() {
        st.rev = st.rev.wrapping_add(1);
        if st.rev == 0 {
            st.rev = 1;
        }
        let rev = st.rev;
        if st.history.len() >= MAX_HISTORY {
            st.history.pop_front();
        }
        st.history.push_back((rev, topic));
        b.cv.notify_all();
    }
}

/// Blocks until the bus revision advances past `since` or `timeout_ms` elapses.
/// Returns `{"rev": u32, "topics": string[]}`.
pub fn wait_since(since: u32, timeout_ms: u32) -> Value {
    let clamped_ms = timeout_ms.clamp(100, 25_000) as u64;
    let deadline = Instant::now() + Duration::from_millis(clamped_ms);
    let b = bus();
    let Ok(mut st) = b.state.lock() else {
        return json!({ "rev": since, "topics": [] });
    };
    while st.rev == since {
        let now = Instant::now();
        if now >= deadline {
            return json!({ "rev": st.rev, "topics": [] });
        }
        let Ok((guard, _)) = b.cv.wait_timeout(st, deadline - now) else {
            return json!({ "rev": since, "topics": [] });
        };
        st = guard;
    }

    let mut topics: Vec<&'static str> = Vec::new();
    let mut covered = since == 0;
    for &(rev, topic) in &st.history {
        if rev == since {
            covered = true;
            topics.clear();
            continue;
        }
        if covered && !topics.contains(&topic) {
            topics.push(topic);
        }
    }
    if !covered || topics.is_empty() {
        topics = vec!["all"];
    }
    json!({ "rev": st.rev, "topics": topics })
}

#[cfg(feature = "ui")]
#[module]
pub struct Events;

#[cfg(feature = "ui")]
#[module]
impl Events {
    /// Long-polls the UI process's local event bus (AI events on macOS; all events on Windows/local-session).
    pub async fn wait_local(since: u32, timeout_ms: u32) -> String {
        blocking(move || wait_since(since, timeout_ms))
            .await
            .map(|v| v.to_string())
            .unwrap_or_else(|_| format!(r#"{{"rev":{since},"topics":[]}}"#))
    }

    /// Long-polls the macOS `pv-background` event bus over the signed-peer Unix socket.
    /// Returns `disabled: true` on non-macOS or `PV_ALLOW_LOCAL_SESSION` test runs.
    pub async fn wait_service(since: u32, timeout_ms: u32) -> String {
        #[cfg(all(target_os = "macos", not(test)))]
        {
            if std::env::var_os("PV_ALLOW_LOCAL_SESSION").is_none() {
                return match crate::service_ipc::control_async(
                    crate::vault_directory(),
                    "events-wait",
                    json!({ "since": since, "timeoutMs": timeout_ms }),
                )
                .await
                {
                    Ok(v) => v.to_string(),
                    Err(_) => json!({ "rev": since, "topics": [], "error": true }).to_string(),
                };
            }
        }
        let _ = (since, timeout_ms);
        r#"{"rev":0,"topics":[],"disabled":true}"#.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notify_wakes_waiter_with_topic() {
        let initial = wait_since(0, 100);
        let start_rev = initial["rev"].as_u64().unwrap() as u32;

        let handle = std::thread::spawn(move || wait_since(start_rev, 5_000));
        std::thread::sleep(Duration::from_millis(20));
        notify("relay");
        let reply = handle.join().unwrap();
        assert_ne!(reply["rev"].as_u64().unwrap() as u32, start_rev);
        let topics = reply["topics"].as_array().unwrap();
        assert!(topics.iter().any(|t| t == "relay" || t == "all"));
    }
}
