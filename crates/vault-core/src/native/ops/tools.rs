//! `tools` ops (see `contract/commands.json`): Stateless helpers over the open document: TOTP, generators, audit and fill.
//! Routed from `DiskVault::command` after the shared checks (registry, lock, format guards).
use super::super::*;

/// Pure unlocked stateless ops that never touch the SQLCipher connection or document.
/// `VaultSession::command` dispatches these without acquiring the `DiskVault` mutex
/// once its atomic lock-state mirror confirms the session is unlocked.
pub(in crate::native) fn stateless_unlocked_op(op: &str, request: &Value) -> Option<Result<Value>> {
    let string = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
    match op {
        "totp" => Some((|| {
            Ok(json!({
                "code": totp(
                    string("secret")?,
                    request["period"].as_u64().unwrap_or(30),
                    request["time"].as_u64().ok_or(VaultError::InvalidData)?,
                )?
            }))
        })()),
        "parse-totp" => Some((|| parse_totp_uri(string("uri")?))()),
        "wallet" => Some(wallet(request)),
        "generate" => Some(generate_secret(request)),
        "breach-request" => Some((|| Ok(breach_request(text_key(request, "password")?)))()),
        "breach-response" => Some((|| {
            Ok(json!({
                "count": breach_response(
                    text_key(request, "suffix")?,
                    text_key(request, "response")?,
                )?
            }))
        })()),
        _ => None,
    }
}

fn text_key<'a>(request: &'a Value, key: &str) -> Result<&'a str> {
    request[key].as_str().ok_or(VaultError::InvalidData)
}

impl DiskVault {
    pub(in crate::native) fn tools_ops(&mut self, op: &str, request: &Value) -> Result<Value> {
        let string = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        if let Some(result) = stateless_unlocked_op(op, request) {
            self.open()?;
            return result;
        }
        match op {
            "audit" => Ok(audit(&self.open()?.document.items)),
            "matches" => matching_accounts(&self.open()?.document.items, string("origin")?),
            "fill" => fill_account(
                &self.open()?.document.items,
                string("origin")?,
                string("id")?,
                request["accountId"].as_str(),
            ),
            _ => Err(VaultError::Unsupported),
        }
    }
}
