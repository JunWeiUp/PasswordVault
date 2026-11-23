//! WSS message connection: the SDK's `Pipe` behind vault-core's blocking API.
//! Events and semantics are the SDK's (see `common_relay::Pipe`): `message`, `peer.up`,
//! `peer.down`, `group.changed` and `undecryptable` for envelopes this connection cannot open.
use super::{code, runtime, sdk_identity, Journal, Result};
use crate::relay_protocol::Identity;
use serde_json::Value;
use std::time::Duration;

pub struct Connection {
    pipe: common_relay::Pipe,
}

impl Connection {
    /// Connects and waits for the relay's identity greeting. `journal` enables offline messages.
    pub fn connect(
        url: &str,
        token: &str,
        password: Option<&str>,
        identity: Identity,
        local: bool,
        journal: Option<Journal>,
    ) -> Result<Self> {
        let identity = sdk_identity(&identity)?;
        let options = common_relay::Options {
            allow_local_test: local,
            password: password.map(str::to_owned),
        };
        let pipe = runtime()
            .block_on(common_relay::Pipe::connect(
                url, token, &options, identity, journal,
            ))
            .map_err(code)?;
        Ok(Self { pipe })
    }

    /// Next application event, `Ok(None)` on timeout, `Err` once the connection is closed.
    pub fn next_event(&self, timeout: Duration) -> Result<Option<Value>> {
        runtime()
            .block_on(self.pipe.next_event(timeout))
            .map_err(code)
    }

    pub fn peers(&self) -> Result<Value> {
        runtime().block_on(self.pipe.peers()).map_err(code)
    }

    /// Sends a message and waits for the relay's reply (`stored`, `forwarded`, `received`).
    pub fn message(&self, to: &str, data: &[u8], offline: bool, id: Option<&str>) -> Result<Value> {
        runtime()
            .block_on(self.pipe.message(to, data, offline, id))
            .map_err(code)
    }

    /// Records the message as handled and acknowledges it (also drops `undecryptable` ones).
    pub fn acknowledge(&self, from: &str, id: &str, offline: bool) -> Result<Value> {
        self.pipe.acknowledge(from, id, offline).map_err(code)?;
        Ok(serde_json::json!({"type":"ack","id":id}))
    }

    pub fn close(&self) {
        self.pipe.close();
    }

    pub fn is_closed(&self) -> bool {
        self.pipe.is_closed()
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        // The SDK's tasks live on the shared runtime; enter it so they shut down cleanly.
        let _guard = runtime().enter();
        self.close();
    }
}
