//! Blocking HTTPS transport for the group state machine (`relay_protocol::groups::Api`).
use super::{invalid, Result};
use crate::relay_protocol::{
    canonical, configured_password, endpoint, groups::Api, text, ACCESS_HEADER,
};
use serde_json::Value;
use std::{io::Read, time::Duration};

const LIMIT: usize = 3 * 1024 * 1024;

pub struct Http {
    /// Allow `ws://127.0.0.1` relays (tests only).
    pub local: bool,
}

pub(crate) fn client() -> Result<reqwest::blocking::Client> {
    reqwest::blocking::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|_| "RelayConnection".into())
}

/// `https://host/relay/v1` (or `/v2`) for a relay WebSocket endpoint.
pub(crate) fn base(url: &str, local: bool) -> Result<String> {
    let mut url = endpoint(url, local)?;
    url.set_scheme(if url.scheme() == "wss" {
        "https"
    } else {
        "http"
    })
    .map_err(|_| "InvalidData")?;
    let prefix = if url.path() == "/v2/ws" {
        "/v2"
    } else {
        "/relay/v1"
    };
    Ok(format!(
        "{}://{}{}",
        url.scheme(),
        &url[url::Position::BeforeHost..url::Position::AfterPort],
        prefix
    ))
}

pub(crate) fn read_limited(
    response: reqwest::blocking::Response,
) -> Result<zeroize::Zeroizing<Vec<u8>>> {
    let mut bytes = zeroize::Zeroizing::new(Vec::new());
    response
        .take(LIMIT as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "RelayConnection")?;
    if bytes.len() > LIMIT {
        return invalid();
    }
    Ok(bytes)
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
        let base = base(text(c, "url")?, self.local)?;
        if !path.starts_with('/') || path.contains('#') || path.contains("..") {
            return invalid();
        }
        let mut request = client()?
            .request(
                method.parse().map_err(|_| "InvalidData")?,
                format!("{base}{path}"),
            )
            .header(
                "Authorization",
                auth.unwrap_or_else(|| format!("Bearer {}", c["token"].as_str().unwrap_or(""))),
            );
        if let Some(password) = configured_password(c)? {
            request = request.header(ACCESS_HEADER, password);
        }
        if let Some(body) = body {
            request = request
                .header("Content-Type", "application/json")
                .body(canonical(&body));
        }
        let response = request.send().map_err(|_| "RelayConnection")?;
        let status = response.status().as_u16();
        if status != 200 {
            return Err(format!("RelayHttp{status}"));
        }
        let value: Value =
            serde_json::from_slice(&read_limited(response)?).map_err(|_| "InvalidData")?;
        if !value.is_object() {
            return invalid();
        }
        Ok(value)
    }
}
