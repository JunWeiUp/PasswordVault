//! Business authorization is separate from verified group membership.
use super::{Result, invalid, protocol::*, service};
use serde_json::{Value, json};
use vault_core::VaultSession;
pub const FORMAT: &str = "passwordvault.access.v1";
pub fn initialize(s: &VaultSession, c: &Value) -> Result<()> {
    let state = service::core(s, json!({"op":"relay-status"}))?;
    if state["enabled"] == true {
        if state["group"] != c["group"]
            || state["device"] != c["device"]
            || state["role"] != c["role"]
        {
            return Err("RelayIdentityMismatch".into());
        }
        return Ok(());
    }
    service::core(
        s,
        json!({"op":"relay-init","role":c["role"],"group":c["group"],"device":c["device"],"hub":c["hub"]}),
    )?;
    Ok(())
}
fn manager(c: &Value, g: &Value) -> Result<bool> {
    Ok(unpack(&g["group_entry"])?["members"]
        .as_array()
        .ok_or("InvalidData")?
        .iter()
        .any(|m| m["device"] == c["device"] && m["manager"] == true))
}
pub fn set(s: &VaultSession, peer: &str, enabled: bool) -> Result<()> {
    let _control = service::CONTROL.lock().map_err(|_| "Storage")?;
    set_locked(s, peer, enabled)
}
fn set_locked(s: &VaultSession, peer: &str, enabled: bool) -> Result<()> {
    set_decision_locked(s, peer, enabled, None)
}
pub(super) fn set_decision_locked(s: &VaultSession, peer: &str, enabled: bool, admission_id: Option<&str>) -> Result<()> {
    let mut c = service::read(s)?;
    let g = service::group(&c)?;
    if let Some(id) = admission_id {
        if c["pendingAdmission"]["id"] != id || c["pendingAdmission"]["cancelled"] == true {
            return Err("AdmissionCancelled".into());
        }
    }
    if c["device"] == peer || c["role"] != "hub" {
        return invalid();
    }
    let peer_library = !c["peerLibrary"].is_null();
    if peer_library && enabled {
        return Err("PeerLibraryIdentityRequired".into());
    }
    if enabled {
        if !manager(&c, &g)? {
            return Err("ManagerRequired".into());
        }
        initialize(s, &c)?; // Data remains gated by authenticated per-peer core capabilities.
    }
    let key = if enabled {
        g["trusted_peers"][peer].as_str()
    } else {
        c["peers"][peer]
            .as_str()
            .or(c["vaultGrants"][peer]["key"].as_str())
            .or(g["trusted_peers"][peer].as_str())
            .or_else(|| (c["pendingAdmission"]["peer"] == peer).then(|| c["pendingAdmission"]["key"].as_str()).flatten())
    }
    .ok_or("UnknownMember")?
    .to_string();
    let revision = c["vaultGrants"][peer]["revision"]
        .as_u64()
        .unwrap_or(0)
        .checked_add(1)
        .filter(|r| *r <= 9_007_199_254_740_991)
        .ok_or("InvalidData")?;
    if !c["vaultGrants"].is_object() {
        c["vaultGrants"] = json!({});
    }
    c["vaultGrants"][peer] =
        json!({"revision":revision,"enabled":enabled,"key":key,"acknowledged":peer_library});
    if let Some(peers) = c["peers"].as_object_mut() {
        peers.remove(peer);
    }
    if let Some(ready) = c["capabilityReady"].as_object_mut() { ready.remove(peer); }
    if enabled {
        // The administrator's local decision grants access. A remote receipt only
        // reports delivery; it must never be able to grant access or resume sync.
        service::core(s, json!({"op":"relay-trust","peer":peer}))?;
        c["peers"][peer] = json!(key);
        if admission_id.is_none() || c["pauseRevision"] == c["pendingAdmission"]["pauseRevision"] {
            c["paused"] = json!(false);
        }
    }
    if let Some(id) = admission_id {
        if c["pendingAdmission"]["id"] != id || c["pendingAdmission"]["cancelled"] == true {
            return Err("AdmissionCancelled".into());
        }
        c["vaultGrants"][peer]["admissionId"] = json!(id);
        c.as_object_mut().ok_or("InvalidData")?.remove("pendingAdmission");
    } else if !enabled && c["pendingAdmission"]["peer"] == peer {
        c["pendingAdmission"]["cancelled"] = json!(true);
    }
    service::write(s, &c)?; // Grant completion/cancellation and decision commit together.
    if peer_library {
        let libraries = service::core(s, json!({"op":"relay-peer-list"}))?;
        for library in libraries["libraries"].as_array().ok_or("InvalidData")? {
            let state =
                service::core(s, json!({"op":"relay-peer-status","library":library["id"]}))?;
            if state["members"].get(peer).is_some() {
                service::core(
                    s,
                    json!({"op":"relay-peer-authorize","library":library["id"],"peer":peer,"member":null}),
                )?;
            }
        }
    }
    if !enabled && service::core(s, json!({"op":"relay-status"}))?["enabled"] == true {
        service::core(s, json!({"op":"relay-revoke","peer":peer}))?;
    }
    Ok(())
}
pub fn message(c: &Value, peer: &str, grant: &Value, kind: &str) -> Value {
    json!({"format":FORMAT,"kind":kind,"group":c["group"],"to":peer,"revision":grant["revision"],"enabled":grant["enabled"],"permission":"read-write","capabilitiesFrom":c["device"],"capabilitiesVersion":2})
}
pub fn pending(c: &Value) -> Result<Vec<(String, Value)>> {
    let g = service::group(c)?;
    if !c["peerLibrary"].is_null() || c["role"] != "hub" || !manager(c, &g)? {
        return Ok(vec![]);
    }
    Ok(c["vaultGrants"]
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(id, v)| v["acknowledged"] == false && g["trusted_peers"][*id] == v["key"])
        .map(|(id, v)| (id.clone(), message(c, id, v, "set")))
        .collect())
}
/// Authenticated transport identity must be checked before calling this function.
/// None means consumed without a reply; non-control data is handled by the sync router.
pub fn receive(
    s: &VaultSession,
    from: &str,
    transport_key: &str,
    p: &Value,
) -> Result<Option<Value>> {
    let _control = service::CONTROL.lock().map_err(|_| "Storage")?;
    let mut c = service::read(s)?;
    let g = service::group(&c)?;
    if p["format"] != FORMAT
        || p["group"] != c["group"]
        || p["to"] != c["device"]
        || p["permission"] != "read-write"
        || p["revision"]
            .as_u64()
            .is_none_or(|r| r == 0 || r > 9_007_199_254_740_991)
        || !p["enabled"].is_boolean()
        || g["trusted_peers"][from] != transport_key
        || transport_key.is_empty()
        || !c["peerLibrary"].is_null()
    {
        return Ok(None);
    }
    if c["role"] == "hub" {
        let grant = &c["vaultGrants"][from];
        if p["kind"] != "ack"
            || grant["revision"] != p["revision"]
            || grant["enabled"] != p["enabled"]
            || grant["key"] != transport_key
            || grant["acknowledged"] == true
        {
            return Ok(None);
        }
        remember_capabilities(&mut c, from, transport_key, p);
        // A delayed receipt cannot change permissions or override a later pause.
        c["vaultGrants"][from]["acknowledged"] = json!(true);
        service::write(s, &c)?;
        Ok(None)
    } else {
        let authority = &g["vault_authority"];
        if p["kind"] != "set"
            || authority["device"] != from
            || authority["public_key"] != transport_key
            || (!c["hub"].as_str().unwrap_or("").is_empty() && c["hub"] != from)
        {
            return Ok(None);
        }
        let revision = p["revision"].as_u64().unwrap();
        let old = c["accessRevision"].as_u64().unwrap_or(0);
        if revision < old || (revision == old && p["enabled"] != c["accessEnabled"]) {
            return Ok(None);
        }
        if revision > old {
            c["hub"] = json!(from);
            if p["enabled"] == true {
                initialize(s, &c)?;
                service::core(s, json!({"op":"relay-trust","peer":from}))?;
                c["peers"][from] = json!(transport_key);
                c["paused"] = json!(false);
            } else {
                if let Some(peers) = c["peers"].as_object_mut() {
                    peers.remove(from);
                }
                c["accessRevision"] = p["revision"].clone();
                c["accessEnabled"] = p["enabled"].clone();
                service::write(s, &c)?;
                if service::core(s, json!({"op":"relay-status"}))?["enabled"] == true {
                    service::core(s, json!({"op":"relay-revoke","peer":from}))?;
                }
            }
            c["accessRevision"] = p["revision"].clone();
            c["accessEnabled"] = p["enabled"].clone();
            service::write(s, &c)?;
        }
        remember_capabilities(&mut c, from, transport_key, p);
        service::write(s, &c)?;
        Ok(Some(message(&c, from, p, "ack")))
    }
}
pub const CAPABILITIES_FORMAT: &str = "passwordvault.capabilities.v1";
fn remember_capabilities(c: &mut Value, from: &str, key: &str, p: &Value) {
    // Older Android echoes unknown set fields in its ack. Requiring the
    // advertiser's own ID prevents that echo from claiming format support.
    if p["capabilitiesFrom"] == from && p["capabilitiesVersion"] == 2 {
        if !c["capabilityPeers"].is_object() { c["capabilityPeers"] = json!({}); }
        c["capabilityPeers"][from] = json!(key);
    }
}
pub fn capability_challenges(s: &VaultSession, c: &Value) -> Result<Vec<(String, Value)>> {
    if !c["peerLibrary"].is_null() { return Ok(vec![]); }
    let state = service::core(s, json!({"op":"relay-status"}))?;
    if state["enabled"] != true { return Ok(vec![]); }
    let g = service::group(c)?;
    let mut out = vec![];
    for (peer, key) in c["peers"].as_object().into_iter().flatten() {
        // Existing grants can predate capability advertisements. Probe trusted
        // authorized peers directly; only the authenticated core proof unlocks data.
        if g["trusted_peers"][peer] != *key { continue; }
        if state["capabilities"].as_array().is_some_and(|p| p.contains(&json!(peer))) {
            out.push((peer.clone(), json!({"format":CAPABILITIES_FORMAT,"kind":"ready","group":c["group"],"to":peer})));
            continue;
        }
        let challenge = service::core(s, json!({"op":"relay-capabilities-challenge","peer":peer}))?;
        out.push((peer.clone(), json!({"format":CAPABILITIES_FORMAT,"kind":"challenge","group":c["group"],"to":peer,"challenge":challenge["challenge"]})));
    }
    Ok(out)
}
pub fn receive_capabilities(s: &VaultSession, from: &str, key: &str, p: &Value) -> Result<Option<Value>> {
    let _guard = service::CONTROL.lock().map_err(|_| "Storage")?;
    let mut c = service::read(s)?;
    let g = service::group(&c)?;
    if p["format"] != CAPABILITIES_FORMAT || p["group"] != c["group"] || p["to"] != c["device"]
        || key.is_empty() || g["trusted_peers"][from] != key || c["peers"][from] != key
        || !c["peerLibrary"].is_null() { return Ok(None); }
    match p["kind"].as_str() {
        Some("challenge") => {
            let result = service::core(s, json!({"op":"relay-capabilities-prove","peer":from,"challenge":p["challenge"]}))?;
            Ok(Some(json!({"format":CAPABILITIES_FORMAT,"kind":"proof","group":c["group"],"to":from,"proof":result["proof"]})))
        }
        Some("proof") => {
            match service::core(s, json!({"op":"relay-capabilities-accept","peer":from,"proof":p["proof"]})) {
                Ok(_) => Ok(Some(json!({"format":CAPABILITIES_FORMAT,"kind":"ready","group":c["group"],"to":from}))),
                Err(e) if e == "Authentication" => Ok(None), // stale/replayed proof; never change permission
                Err(e) => Err(e),
            }
        }
        Some("ready") => {
            if c["capabilityReady"][from] != key {
                if !c["capabilityReady"].is_object() { c["capabilityReady"] = json!({}); }
                c["capabilityReady"][from] = json!(key);
                service::write(s, &c)?;
            }
            Ok(None)
        }
        _ => Ok(None),
    }
}
/// An explicit Mac sync action also resumes grants saved by the old ack-gated client.
pub fn resume(s: &VaultSession) -> Result<()> {
    let _guard = service::CONTROL.lock().map_err(|_| "Storage")?;
    let c = service::read(s)?;
    if c["role"] == "hub" && c["peerLibrary"].is_null() {
        let g = service::group(&c)?;
        for (peer, grant) in c["vaultGrants"].as_object().into_iter().flatten() {
            if grant["enabled"] == true && g["trusted_peers"][peer] == grant["key"]
                && c["peers"][peer] != grant["key"] { set_locked(s, peer, true)?; }
        }
    }
    let mut c = service::read(s)?;
    c["paused"] = json!(false);
    service::write(s, &c)
}
/// Pausing data replication deliberately leaves device-group presence available.
pub fn pause(s: &VaultSession, paused: bool) -> Result<()> {
    let _guard = service::CONTROL.lock().map_err(|_| "Storage")?;
    let mut c = service::read(s)?;
    if !c["device"].is_string() {
        return invalid();
    }
    c["paused"] = json!(paused);
    c["pauseRevision"] = json!(c["pauseRevision"].as_u64().unwrap_or(0).checked_add(1).ok_or("InvalidData")?);
    service::write(s, &c)
}
