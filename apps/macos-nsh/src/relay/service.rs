//! Native-only credential adapter. All group drafts live inside relay-private encryption.
use super::{
    Result,
    groups::{Groups, Http, now},
    invalid,
    protocol::*,
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::sync::Mutex;
use vault_core::VaultSession;
pub static CONTROL: Mutex<()> = Mutex::new(());
// Serialize remote group operations without holding the local commit lock over HTTP.
static NETWORK: Mutex<()> = Mutex::new(());
pub fn core(s: &VaultSession, v: Value) -> Result<Value> {
    let raw = zeroize::Zeroizing::new(s.command(v.to_string()).map_err(crate::error_code)?);
    serde_json::from_str(&raw).map_err(|_| "InvalidData".into())
}
pub fn read(s: &VaultSession) -> Result<Value> {
    let v = core(s, json!({"op":"relay-credentials-read"}))?;
    match v["data"].as_str() {
        Some(raw) => serde_json::from_str(raw).map_err(|_| "InvalidData".into()),
        None => Ok(json!({})),
    }
}
pub fn write(s: &VaultSession, c: &Value) -> Result<()> {
    core(
        s,
        json!({"op":"relay-credentials-write","data":c.to_string()}),
    )?;
    Ok(())
}
pub fn group(c: &Value) -> Result<Value> {
    match c["groupState"].as_str() {
        Some(raw) => {
            let bytes = zeroize::Zeroizing::new(STANDARD.decode(raw).map_err(|_| "InvalidData")?);
            serde_json::from_slice(&bytes).map_err(|_| "InvalidData".into())
        }
        None => Ok(json!({})),
    }
}
fn stash(s: &VaultSession, c: &mut Value, g: &Value) -> Result<()> {
    let mut g = g.clone();
    if c["role"] == "mobile" && g["vault_authority"].is_null() && g["group_entry"].is_object() {
        let state = unpack(&g["group_entry"])?;
        let managers: Vec<_> = state["members"]
            .as_array()
            .ok_or("InvalidData")?
            .iter()
            .filter(|m| m["manager"] == true)
            .collect();
        if managers.len() == 1 && managers[0]["device"] != c["device"] {
            g["vault_authority"] = managers[0].clone();
        }
    }
    c["groupState"] = json!(STANDARD.encode(canonical(&g)));
    write(s, c)
}
pub fn display(c: &Value) -> Result<Value> {
    let g = group(c)?;
    let state = if g["group_entry"].is_object() {
        unpack(&g["group_entry"])?
    } else {
        Value::Null
    };
    let req = if g["pending_join"].is_object() {
        &g["pending_join"]["request"]
    } else {
        &g["join_request"]
    };
    let code = payload(req)
        .ok()
        .map(|p| {
            let h = digest(&p)[..12].to_uppercase();
            format!("{}-{}-{}", &h[..4], &h[4..8], &h[8..12])
        })
        .unwrap_or_default();
    let inv = &g["issued_invitation"];
    let link = if inv["expires"].as_u64().unwrap_or(0) > now() {
        inv["short_link"].as_str().unwrap_or("")
    } else {
        ""
    };
    // No secret, token, pending signed grant or delegate key leaves Rust.
    Ok(
        json!({"legacy":!c["token"].as_str().unwrap_or("").is_empty()&&g.as_object().is_some_and(|g|g.is_empty()),"device":c["device"],"role":c["role"],"peerLibrary":c["peerLibrary"],"paused":c["paused"],"state":state,"transport":"not-connected","joining":g["pending_join"].is_object(),"creating":g["pending_create"].is_object(),"code":code,"applicant":unpack(&g["join_request"]).ok().map(|r|r["member"]["name"].clone()),"invitationLink":link,"hasPassword":super::protocol::configured_password(&c).ok().flatten().is_some(),"invitationMode":inv["mode"],"invitationExpires":inv["expires"],"authorizedPeers":c["peers"].as_object().map(|p|p.keys().cloned().collect::<Vec<_>>()),"grants":c["vaultGrants"].as_object().map(|m|m.iter().map(|(k,v)|(k.clone(),json!({"enabled":v["enabled"],"acknowledged":v["acknowledged"]}))).collect::<serde_json::Map<_,_>>())}),
    )
}
pub fn execute(s: &VaultSession, request: Value, local: bool) -> Result<String> {
    let _network = NETWORK.lock().map_err(|_| "Storage")?;
    let guard = CONTROL.lock().map_err(|_| "Storage")?;
    sodiumoxide::init().map_err(|_| "Storage")?;
    let mut c = read(s)?;
    let op = text(&request, "op")?;
    if c.as_object().ok_or("InvalidData")?.is_empty() {
        c = json!({"endpoint":"","role":"hub","group":"","device":uuid::Uuid::new_v4().to_string(),"hub":"","secret":STANDARD.encode(sodiumoxide::randombytes::randombytes(32)),"token":"","peers":{},"paused":true});
        write(s, &c)?;
    }
    if op == "clear-local" {
        clear_local(s, &mut c)?;
        return Ok(display(&c)?.to_string());
    }
    let mut g = group(&c)?;
    if op == "update-password" {
        let password = super::protocol::access_password(text(&request, "relayPassword")?)?;
        if g.as_object().ok_or("InvalidData")?.is_empty() {
            return Err("NotEnrolled".into());
        }
        g["password"] = json!(password);
        if g["pending_join"]["invitation"].is_object() {
            g["pending_join"]["invitation"]["password"] = json!(password);
        }
        c["password"] = json!(password);
        stash(s, &mut c, &g)?;
        return Ok(display(&c)?.to_string());
    }
    if g.as_object().ok_or("InvalidData")?.is_empty() {
        if c["token"].as_str().is_some_and(|s| !s.is_empty()) {
            return Err("LegacyRelayResetRequired".into());
        }
        let secret = STANDARD
            .decode(text(&c, "secret")?)
            .map_err(|_| "InvalidData")?;
        g = json!({"app":"passwordvault","device":c["device"],"secret_key":hex(&secret)});
    }
    let expected_device = c["device"].clone();
    drop(guard);
    let mut save = |g: &Value| {
        let _commit = CONTROL.lock().map_err(|_| "Storage")?;
        if read(s)?["device"] != expected_device { return Err("RelayIdentityChanged".into()); }
        stash(s, &mut c, g)
    };
    let mut groups = Groups {
        config: g,
        api: Http { local },
        save: &mut save,
        local,
    };
    match op {
        "create" => {
            if groups.config["pending_create"].is_null() {
                super::transport::endpoint(text(&request, "endpoint")?, local)?;
                // Creating a group always requires the relay's access password.
                let password = super::protocol::access_password(text(&request, "relayPassword")?)?;
                groups.config["url"] = request["endpoint"].clone();
                groups.config["password"] = json!(password);
            }
            // A failed admission check leaves a durable signed draft. Let the user
            // correct only its password without changing the group ID or signed entry.
            if let Some(password) = request["relayPassword"].as_str().filter(|v| !v.is_empty()) {
                let password = super::protocol::access_password(password)?;
                groups.config["password"] = json!(password);
            }
            groups.create(text(&request, "name")?, text(&request, "deviceName")?)?;
        }
        "refresh" => {
            groups.refresh()?;
        }
        "invite" => {
            groups.invite(text(&request, "mode")?)?;
        }
        "join" => {
            // The link may carry the password; otherwise use what the user typed.
            let typed = request["relayPassword"].as_str().filter(|p| !p.is_empty());
            let inv = groups.resolve(text(&request, "link")?, typed)?;
            groups.join(inv, text(&request, "deviceName")?)?;
        }
        "retry-join" => {
            let inv = groups.config["pending_join"]["invitation"].clone();
            let req = unpack(&groups.config["pending_join"]["request"])?;
            groups.join(inv, text(&req["member"], "name")?)?;
        }
        "finish-join" => {
            groups.finish_join()?;
        }
        "check-request" => {
            groups.pending()?;
        }
        "approve" => {
            groups.approve(text(&request, "code")?, request["manager"] == true)?;
        }
        "cancel-invitation" => groups.cancel()?,
        "rename" => groups.rename(text(&request, "device")?, text(&request, "name")?)?,
        "remove" => groups.remove(text(&request, "device")?)?,
        "leave" | "disband" => groups.exit(op == "disband")?,
        _ => return invalid(),
    }
    g = groups.config.clone();
    drop(groups);
    drop(save);
    let _commit = CONTROL.lock().map_err(|_| "Storage")?;
    if read(s)?["device"] != expected_device { return Err("RelayIdentityChanged".into()); }
    if matches!(op, "leave" | "disband") {
        clear_local(s, &mut c)?;
    } else if g["group_entry"].is_object() {
        let state = unpack(&g["group_entry"])?;
        let own = state["members"]
            .as_array()
            .ok_or("InvalidData")?
            .iter()
            .any(|m| m["device"] == c["device"]);
        let valid = state["closed"] != true && own;
        let revoked: Vec<String> = c["peers"]
            .as_object()
            .into_iter()
            .flatten()
            .filter(|(id, key)| !valid || g["trusted_peers"][*id] != **key)
            .map(|(id, _)| id.clone())
            .collect();
        for id in revoked {
            if core(s, json!({"op":"relay-status"}))?["enabled"] == true {
                core(s, json!({"op":"relay-revoke","peer":id}))?;
            }
            c["peers"].as_object_mut().unwrap().remove(&id);
        }
        if let Some(grants) = c["vaultGrants"].as_object_mut() {
            for (id, grant) in grants {
                if !valid || g["trusted_peers"][id.as_str()] != grant["key"] {
                    grant["enabled"] = json!(false);
                    grant["acknowledged"] = json!(true);
                }
            }
        }
        c["endpoint"] = g["url"].clone();
        c["group"] = g["group"].clone();
        c["token"] = g["token"].clone();
        c["password"] = g["password"].clone();
        if c["role"] == "hub" {
            c["hub"] = c["device"].clone();
        }
        if !valid {
            c["paused"] = json!(true);
        }
        write(s, &c)?;
        if !valid {
            return Err("GroupAccessRevoked".into());
        }
    }
    Ok(display(&c)?.to_string())
}

/// Commit local departure without waiting for any remote request. The returned
/// snapshot is only for a best-effort remote notification and must never be saved.
pub fn exit_local(s: &VaultSession) -> Result<(String, Value)> {
    let _commit = CONTROL.lock().map_err(|_| "Storage")?;
    sodiumoxide::init().map_err(|_| "Storage")?;
    let mut c = read(s)?;
    let remote = group(&c)?;
    clear_local(s, &mut c)?;
    Ok((display(&c)?.to_string(), remote))
}
pub fn notify_exit(config: Value, disband: bool, local: bool) -> Result<()> {
    let mut discard = |_: &Value| Ok(());
    Groups { config, api: Http { local }, save: &mut discard, local }.exit(disband)
}

fn clear_local(s: &VaultSession, c: &mut Value) -> Result<()> {
    let state = core(s, json!({"op":"relay-status"}))?;
    if state["enabled"] == true {
        core(
            s,
            json!({"op":"relay-detach","group":state["group"],"device":state["device"]}),
        )?;
    }
    for k in [
        "groupState",
        "vaultGrants",
        "accessRevision",
        "accessEnabled",
        "peerExpectedLibrary", "peerPendingLocalLibrary", "peerFounderKey",
        "peerPreviousLibrary", "peerPreviousPeers", "peerPreviousPaused",
    ] {
        c.as_object_mut().ok_or("InvalidData")?.remove(k);
    }
    for k in ["group", "token", "hub", "endpoint", "password"] {
        c[k] = json!("");
    }
    c["peers"] = json!({});
    c["paused"] = json!(true);
    c["device"] = json!(uuid::Uuid::new_v4().to_string());
    write(s, c)
}
