//! Symmetric sync: every member of the signed device group is a peer. Joining the
//! group is the only admission step; the core resolves concurrent edits by stamp.
use super::{Result, protocol::*, service};
use serde_json::{Value, json};
use crate::session::VaultSession;

pub const VERSION: u64 = 3;

/// Peers from the verified group roster with pinned transport keys, excluding this
/// device. `None` means the vault is not in a personal group (or uses a peer library).
pub fn roster(c: &Value) -> Result<Option<Vec<String>>> {
    if !c["peerLibrary"].is_null() {
        return Ok(None);
    }
    let g = service::group(c)?;
    if !g["group_entry"].is_object() {
        return Ok(None);
    }
    let state = unpack(&g["group_entry"])?;
    if state["closed"] == true || g["access_invalid"] == true {
        return Ok(None);
    }
    let device = text(c, "device")?;
    let trusted = g["trusted_peers"].as_object().ok_or("InvalidData")?;
    let peers = state["members"]
        .as_array()
        .ok_or("InvalidData")?
        .iter()
        .filter_map(|m| m["device"].as_str())
        .filter(|id| *id != device && trusted.get(*id).is_some_and(|k| k.as_str().is_some_and(|k| !k.is_empty())))
        .map(str::to_owned)
        .collect();
    Ok(Some(peers))
}

/// Initializes (or migrates the legacy hub/mobile journal) and applies the roster.
/// Idempotent; called on every sync cycle so roster changes take effect at once.
pub fn ensure(s: &VaultSession, c: &Value) -> Result<Option<Vec<String>>> {
    let Some(peers) = roster(c)? else { return Ok(None) };
    let group = text(c, "group")?;
    let device = text(c, "device")?;
    service::core(s, json!({"op":"relay-mesh-init","group":group,"device":device}))?;
    service::core(s, json!({"op":"relay-mesh-peers","peers":peers}))?;
    Ok(Some(peers))
}

pub fn outgoing(s: &VaultSession, peers: &[String]) -> Result<Vec<(String, String, Vec<u8>)>> {
    let mut packets = vec![];
    for peer in peers {
        let result = service::core(s, json!({"op":"relay-mesh-export","peer":peer}))?;
        if result["packet"].is_object() {
            packets.push((peer.clone(), String::new(), canonical(&result["packet"])));
        }
    }
    Ok(packets)
}

/// Applies a peer packet. Returns whether visible vault content changed. Packets
/// from older protocol versions are ignored so a not-yet-updated device cannot
/// stall the connection; it resumes once that device is updated.
pub fn receive(s: &VaultSession, from: &str, data: &[u8]) -> Result<bool> {
    let _guard = service::CONTROL.lock().map_err(|_| "Storage")?;
    let packet: Value = serde_json::from_slice(data).map_err(|_| "InvalidData")?;
    if packet["version"] != VERSION || packet["kind"] != "mesh" {
        return Ok(false);
    }
    let result = service::core(s, json!({"op":"relay-mesh-receive","peer":from,"packet":packet}))?;
    Ok(result["changed"] == true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{Engine, engine::general_purpose::STANDARD};
    #[test]
    fn roster_uses_pinned_members_and_excludes_self() {
        let member = |id: &str, manager: bool| json!({"device":id,"name":id,"public_key":"","signing_key":"","manager":manager});
        let entry = json!({"version":1,"app":"passwordvault","group":"g","revision":2,"previous":"","invitation":"","request_hash":"",
            "members":[member("mac", true), member("phone", false), member("unpinned", false)]});
        let packed = json!({"payload":STANDARD.encode(canonical(&entry))});
        let g = json!({"group":"g","group_entry":packed,"trusted_peers":{"phone":"ab","mac":"cd"}});
        let c = json!({"device":"mac","group":"g","groupState":STANDARD.encode(canonical(&g))});
        assert_eq!(roster(&c).unwrap(), Some(vec!["phone".to_string()]));
        let mut library = c.clone();
        library["peerLibrary"] = json!("lib");
        assert!(roster(&library).unwrap().is_none());
    }
}
