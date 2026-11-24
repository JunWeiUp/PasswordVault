//! Blocking HTTPS transport for the group state machine: the SDK's `GroupHttp` with
//! vault-core error codes.
use crate::relay_protocol::groups::{Api, Result};
use serde_json::Value;

pub struct Http {
    /// Allow `ws://127.0.0.1` relays (tests only).
    pub local: bool,
}

impl Api for Http {
    fn call(
        &self,
        c: &Value,
        method: &str,
        path: &str,
        body: Option<Value>,
        auth: Option<String>,
    ) -> Result<Value> {
        common_relay::GroupApi::call(
            &common_relay::GroupHttp { local: self.local },
            c,
            method,
            path,
            body,
            auth,
        )
        .map_err(super::code)
    }
}
