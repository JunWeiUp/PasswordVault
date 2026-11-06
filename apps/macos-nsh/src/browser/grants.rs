//! Wire-compatible helper-owned Keychain records. Old raw grants stay save-only.
use super::security;
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::path::Path;
use zeroize::Zeroizing;
const SERVICE: &str = "com.securepass.vault.browser-background-save.v1";
const DESKTOP: &str = "com.securepass.vault.browser-desktop-unlock.v1";
fn account(directory: &Path, id: &str, token: &str) -> Result<String, String> {
    if token.len() != 64
        || !token
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err("sync-authorization".into());
    }
    Ok(format!(
        "{:x}",
        Sha256::digest(format!("{}\n{id}\n{token}", directory.display()))
    ))
}
fn desktop_account(directory: &Path) -> Result<String, String> {
    let hash = security::code_hash(&std::env::current_exe().map_err(|_| "unavailable")?)
        .ok_or("unavailable")?;
    Ok(format!(
        "{:x}",
        Sha256::digest(format!(
            "{}\n{}",
            directory.display(),
            STANDARD.encode(hash)
        ))
    ))
}
pub struct Authorization {
    pub grant: Zeroizing<Vec<u8>>,
    pub read: bool,
    pub startup: bool,
}
pub fn decode(bytes: &[u8]) -> Result<Authorization, String> {
    if bytes.len() == 64 {
        return Ok(Authorization {
            grant: Zeroizing::new(bytes.to_vec()),
            read: false,
            startup: false,
        });
    }
    let value: Value = serde_json::from_slice(bytes).map_err(|_| "sync-authorization")?;
    Ok(Authorization {
        grant: Zeroizing::new(
            STANDARD
                .decode(value["grant"].as_str().ok_or("sync-authorization")?)
                .map_err(|_| "sync-authorization")?,
        ),
        read: value["allowRead"] == true,
        startup: value["autoUnlock"] == true,
    })
}
pub fn authorization(directory: &Path, id: &str, token: &str) -> Result<Authorization, String> {
    let bytes = security::keychain(SERVICE, &account(directory, id, token)?, None)?;
    let auth = decode(&bytes)?;
    if !vault_core::background_grant_valid(directory.to_string_lossy().into(), auth.grant.to_vec())
        .unwrap_or(false)
    {
        return Err("sync-authorization".into());
    }
    Ok(auth)
}
pub fn configure(directory: &Path, id: &str, request: &Value) -> Result<(), String> {
    let token = request["syncToken"].as_str().unwrap_or("");
    let key = account(directory, id, token)?;
    let read = request["allowRead"] == true;
    let startup = request["autoUnlock"] == true;
    if startup && !read {
        return Err("invalid-request".into());
    }
    let password = request["password"]
        .as_str()
        .filter(|p| !p.is_empty() && p.len() <= 4096)
        .ok_or("invalid-request")?;
    let grant = Zeroizing::new(
        vault_core::create_background_grant(directory.to_string_lossy().into(), password.into())
            .map_err(|_| "authentication")?,
    );
    let bytes = Zeroizing::new(
        json!({"grant":STANDARD.encode(&*grant),"allowRead":read,"autoUnlock":startup}).to_string(),
    );
    security::keychain(SERVICE, &key, Some(Some(bytes.as_bytes())))?;
    if startup {
        let result = desktop_account(directory).and_then(|key| {
            security::keychain(
                DESKTOP,
                &key,
                Some(Some(
                    json!({"extensionID":id,"token":token})
                        .to_string()
                        .as_bytes(),
                )),
            )
        });
        if let Err(e) = result {
            let _ = security::keychain(SERVICE, &key, Some(None));
            return Err(e);
        }
    } else {
        disable_desktop(directory, id, token)?
    }
    Ok(())
}
pub fn owner(directory: &Path, id: &str, token: &str) -> bool {
    desktop_account(directory)
        .and_then(|key| security::keychain(DESKTOP, &key, None))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .is_some_and(|v| v["extensionID"] == id && v["token"] == token)
}
pub fn disable_desktop(directory: &Path, id: &str, token: &str) -> Result<(), String> {
    if owner(directory, id, token) {
        security::keychain(DESKTOP, &desktop_account(directory)?, Some(None))?;
    }
    Ok(())
}
pub fn revoke(directory: &Path, id: &str, token: &str) -> Result<(), String> {
    security::keychain(SERVICE, &account(directory, id, token)?, Some(None))?;
    disable_desktop(directory, id, token)
}
pub fn desktop(directory: &Path, id: &str) -> Result<Authorization, String> {
    let bytes = security::keychain(DESKTOP, &desktop_account(directory)?, None)?;
    let owner: Value = serde_json::from_slice(&bytes).map_err(|_| "sync-authorization")?;
    if owner["extensionID"] != id {
        return Err("sync-authorization".into());
    }
    let auth = authorization(
        directory,
        id,
        owner["token"].as_str().ok_or("sync-authorization")?,
    )?;
    if !auth.read || !auth.startup {
        return Err("sync-authorization".into());
    }
    Ok(auth)
}
