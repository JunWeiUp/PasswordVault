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
// Desktop used to mark every new configuration as a hub, including ordinary
// joiners. Repair only an uninitialized receiver with one verified authority.
// Existing replication state, personal peer libraries and granted peers stay intact.
fn repair_joiner_role(s: &VaultSession, c: &mut Value, g: &mut Value) -> Result<()> {
    let empty_map = |v: &Value| v.is_null() || v.as_object().is_some_and(|m| m.is_empty());
    if c["role"] != "hub" || !c["peerLibrary"].is_null()
        || !empty_map(&c["peers"]) || !empty_map(&c["vaultGrants"])
        || !g["vault_authority"].is_null() || !g["group_entry"].is_object()
        || (!c["hub"].as_str().unwrap_or("").is_empty() && c["hub"] != c["device"])
    { return Ok(()); }
    let state = unpack(&g["group_entry"])?;
    if state["closed"] == true || state["group"] != g["group"] { return Ok(()); }
    let members = state["members"].as_array().ok_or("InvalidData")?;
    if !members.iter().any(|m| m["device"] == c["device"] && m["manager"] == false) { return Ok(()); }
    let managers: Vec<_> = members.iter().filter(|m| m["manager"] == true).collect();
    if managers.len() != 1 { return Ok(()); }
    let authority = managers[0];
    let id = text(authority, "device")?;
    let key = text(authority, "public_key")?;
    if key.is_empty() || g["trusted_peers"][id] != key
        || core(s, json!({"op":"relay-status"}))?["enabled"] == true
    { return Ok(()); }
    // "mobile" is the existing wire name for a receiver, not its operating system.
    c["role"] = json!("mobile");
    c["hub"] = authority["device"].clone();
    g["vault_authority"] = authority.clone();
    Ok(())
}
fn stash(s: &VaultSession, c: &mut Value, g: &Value) -> Result<()> {
    let mut g = g.clone();
    repair_joiner_role(s, c, &mut g)?;
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
/// Resolve this vault's known primary without guessing from OS or list order.
pub(super) fn primary_device(c: &Value, g: &Value, state: &Value) -> Option<String> {
    if !c["peerLibrary"].is_null() || state["closed"] == true { return None; }
    let members = state["members"].as_array()?;
    if members.iter().filter(|m| m["manager"] == true).count() != 1 { return None; }
    if c["role"] == "hub" && c["hub"] == c["device"] {
        return members.iter().find(|m| m["device"] == c["device"] && m["manager"] == true)
            .and_then(|m| m["device"].as_str()).map(str::to_owned);
    }
    let authority = &g["vault_authority"];
    let id = authority["device"].as_str()?;
    let key = authority["public_key"].as_str()?;
    if key.is_empty() || g["trusted_peers"][id] != key || c["hub"] != id { return None; }
    members.iter().find(|m| m["device"] == id && m["public_key"] == key && m["manager"] == true)
        .map(|_| id.to_owned())
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
    let primary = primary_device(c, &g, &state);
    let primary_name = primary.as_deref().and_then(|id| state["members"].as_array()?.iter().find(|m| m["device"] == id)?.get("name")).cloned().unwrap_or(Value::Null);
    let is_primary = primary.as_deref().is_some_and(|id| c["device"] == id);
    // No secret, token, pending signed grant or delegate key leaves Rust.
    Ok(
        json!({"primaryDevice":primary,"primaryName":primary_name,"isPrimary":is_primary,"legacy":!c["token"].as_str().unwrap_or("").is_empty()&&g.as_object().is_some_and(|g|g.is_empty()),"device":c["device"],"role":c["role"],"peerLibrary":c["peerLibrary"],"paused":c["paused"],"state":state,"transport":"not-connected","joining":g["pending_join"].is_object(),"creating":g["pending_create"].is_object(),"code":code,"applicant":unpack(&g["join_request"]).ok().map(|r|r["member"]["name"].clone()),"invitationLink":link,"hasPassword":super::protocol::configured_password(&c).ok().flatten().is_some(),"invitationMode":inv["mode"],"invitationExpires":inv["expires"],"authorizedPeers":c["peers"].as_object().map(|p|p.keys().cloned().collect::<Vec<_>>()),"grants":c["vaultGrants"].as_object().map(|m|m.iter().map(|(k,v)|(k.clone(),json!({"enabled":v["enabled"],"acknowledged":v["acknowledged"]}))).collect::<serde_json::Map<_,_>>())}),
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
    if op == "approve-and-grant" {
        super::admission::prepare(s, &mut c, &g, text(&request, "code")?)?;
    }
    if c["pendingAdmission"].is_object() && (op == "cancel-invitation"
        || (op == "remove" && request["device"] == c["pendingAdmission"]["peer"])) {
        c["pendingAdmission"]["cancelled"] = json!(true);
        write(s, &c)?;
    }
    let admission = c["pendingAdmission"].clone();
    let expected_device = c["device"].clone();
    drop(guard);
    let mut save = |g: &Value| {
        let _commit = CONTROL.lock().map_err(|_| "Storage")?;
        let latest = read(s)?;
        if latest["device"] != expected_device { return Err("RelayIdentityChanged".into()); }
        // HTTP must not roll back concurrent pause, grant, receipt or revocation.
        c = latest;
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
            if admission.is_object() && admission["cancelled"] != true
                && !super::admission::has_receipt(&groups.config, &admission)?
                && groups.config["join_request"].is_object()
                && digest(&payload(&groups.config["join_request"])?) == admission["requestHash"]
            {
                let code = groups.code()?;
                groups.approve(&code, false)?;
            }
        }
        "invite-personal" => {
            groups.refresh()?;
            let current = read(s)?;
            let state = unpack(&groups.config["group_entry"])?;
            if primary_device(&current, &groups.config, &state).as_deref() != current["device"].as_str() {
                return Err("PrimaryRequired".into());
            }
            groups.invite("manual")?;
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
        "approve-and-grant" => {
            if !super::admission::has_receipt(&groups.config, &admission)? {
                groups.approve(text(&request, "code")?, false)?;
            }
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
    c = read(s)?;
    if c["device"] != expected_device { return Err("RelayIdentityChanged".into()); }
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
    if matches!(op, "approve-and-grant" | "refresh") {
        super::admission::complete_locked(s)?;
        c = read(s)?;
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
        "pendingAdmission",
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
    c["role"] = json!("hub"); // Explicit departure restores independent desktop creation.
    c["peers"] = json!({});
    c["paused"] = json!(true);
    c["device"] = json!(uuid::Uuid::new_v4().to_string());
    write(s, c)
}

#[cfg(test)]
mod primary_tests {
    use super::*;
    #[test]
    fn primary_identity_is_not_inferred_from_platform_or_membership_order() {
        let state = json!({"members":[{"device":"windows","name":"Windows","public_key":"w","manager":false},{"device":"phone","name":"Phone","public_key":"p","manager":true}]});
        let c = json!({"role":"hub","device":"phone","hub":"phone"});
        assert_eq!(primary_device(&c, &json!({}), &state), Some("phone".into()));
        let receiver = json!({"role":"mobile","device":"windows","hub":"phone"});
        let group = json!({"vault_authority":{"device":"phone","public_key":"p"},"trusted_peers":{"phone":"p"}});
        assert_eq!(primary_device(&receiver, &group, &state), Some("phone".into()));
        assert_eq!(primary_device(&receiver, &json!({}), &state), None);
        let mut changed_key = group.clone(); changed_key["trusted_peers"]["phone"] = json!("different");
        assert_eq!(primary_device(&receiver, &changed_key, &state), None);
        let mut independent = receiver.clone(); independent["peerLibrary"] = json!("other-library");
        assert_eq!(primary_device(&independent, &group, &state), None);
        let mut ambiguous = state.clone(); ambiguous["members"][0]["manager"] = json!(true);
        assert_eq!(primary_device(&c, &group, &ambiguous), None);
        assert_eq!(primary_device(&receiver, &group, &ambiguous), None);
        let mut closed = state.clone(); closed["closed"] = json!(true);
        assert_eq!(primary_device(&c, &group, &closed), None);
        let mut wrong_hub = receiver.clone(); wrong_hub["hub"] = json!("other");
        assert_eq!(primary_device(&wrong_hub, &group, &state), None);
        let ordinary_hub = json!({"role":"hub","device":"windows","hub":"windows"});
        assert_eq!(primary_device(&ordinary_hub, &group, &state), None);
    }
}
