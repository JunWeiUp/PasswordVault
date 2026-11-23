//! Desktop transport for the shared group state machine (`vault_core::relay_protocol::groups`).
use super::{Result, invalid, protocol::*, transport::endpoint};
use serde_json::Value;
use std::{io::Read, time::Duration};
pub use vault_core::relay_protocol::groups::{Api, Groups, now};
pub struct Http {
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
        let mut url = endpoint(text(c, "url")?, self.local)?;
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
        let base = format!(
            "{}://{}{}",
            url.scheme(),
            &url[url::Position::BeforeHost..url::Position::AfterPort],
            prefix
        );
        if !path.starts_with('/') || path.contains('#') || path.contains("..") {
            return invalid();
        }
        let client = reqwest::blocking::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|_| "RelayConnection")?;
        let mut request = client
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
        let mut bytes = zeroize::Zeroizing::new(Vec::new());
        response
            .take(3 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "RelayConnection")?;
        if bytes.len() > 3 * 1024 * 1024 {
            return invalid();
        }
        let value: Value = serde_json::from_slice(&bytes).map_err(|_| "InvalidData")?;
        if !value.is_object() {
            return invalid();
        }
        Ok(value)
    }
}
