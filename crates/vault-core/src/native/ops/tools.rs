//! `tools` ops (see `contract/commands.json`): Stateless helpers over the open document: TOTP, generators, audit and fill.
//! Routed from `DiskVault::command` after the shared checks (registry, lock, format guards).
use super::super::*;

impl DiskVault {
    pub(in crate::native) fn tools_ops(&mut self, op: &str, request: &Value) -> Result<Value> {
        let string = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        match op {
            "totp" => {
                self.open()?;
                Ok(
                    json!({"code":totp(string("secret")?,request["period"].as_u64().unwrap_or(30),request["time"].as_u64().ok_or(VaultError::InvalidData)?)?}),
                )
            }
            "parse-totp" => {
                self.open()?;
                parse_totp_uri(string("uri")?)
            }
            "wallet" => {
                self.open()?;
                wallet(request)
            }
            "generate" => {
                self.open()?;
                generate_secret(request)
            }
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
