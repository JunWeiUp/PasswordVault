//! Core routing only accepts separately authorized, pinned transport identities.
use super::{Result, invalid, protocol::*, service};
use serde_json::{Value, json};
use vault_core::VaultSession;
fn allowed(c: &Value, from: &str, key: &str) -> Result<()> {
    if c["paused"] == true || key.is_empty() || c["peers"][from] != key {
        return Err("VaultAccessDenied".into());
    }
    Ok(())
}
pub fn outgoing(s: &VaultSession) -> Result<Vec<(String, String, Vec<u8>)>> {
    let c = service::read(s)?;
    if c["paused"] == true {
        return Ok(vec![]);
    }
    let mut packets = vec![];
    let mut blocked = false;
    for (peer, key) in c["peers"].as_object().into_iter().flatten() {
        let key = key.as_str().ok_or("InvalidData")?;
        let g = service::group(&c)?;
        if g["trusted_peers"][peer] != key {
            return Err("VaultAccessDenied".into());
        }
        if c["peerLibrary"].is_null() {
            match service::core(s, json!({"op":"relay-export","peer":peer})) {
                Ok(p) => packets.push((peer.clone(), String::new(), canonical(&p))),
                Err(e) if e == "DevicesSyncBlocked" => { blocked = true; }
                Err(e) => return Err(e),
            }
        } else {
            let list = service::core(s, json!({"op":"relay-peer-list"}))?;
            for l in list["libraries"].as_array().ok_or("InvalidData")? {
                let id = text(l, "id")?;
                let status = service::core(s, json!({"op":"relay-peer-status","library":id}))?;
                if status["frozen"] == true || status["members"][peer]["transportKey"] != key {
                    continue;
                }
                let p = service::core(
                    s,
                    json!({"op":"relay-peer-export","library":id,"peer":peer}),
                )?;
                packets.push((peer.clone(), id.into(), canonical(&p)));
            }
        }
    }
    if blocked && packets.is_empty() { return Err("DevicesSyncBlocked".into()); }
    Ok(packets)
}
pub fn receive(s: &VaultSession, from: &str, key: &str, data: &[u8]) -> Result<()> {
    let _guard = service::CONTROL.lock().map_err(|_| "Storage")?;
    let mut c = service::read(s)?;
    allowed(&c, from, key)?;
    let packet: Value = serde_json::from_slice(data).map_err(|_| "InvalidData")?;
    if c["peerLibrary"].is_null() {
        service::core(s, json!({"op":"relay-receive","peer":from,"packet":packet}))?;
    } else {
        let incoming = packet["packet"]["library"]
            .as_str()
            .or(packet["library"].as_str())
            .ok_or("InvalidData")?;
        if c["peerExpectedLibrary"] == incoming && c["peerFounderKey"].is_string() {
            let local = c["peerPendingLocalLibrary"]
                .as_str()
                .or(c["peerLibrary"].as_str())
                .ok_or("InvalidData")?;
            let result = service::core(
                s,
                json!({"op":"relay-peer-join","library":local,"expectedLibrary":incoming,"founderKey":c["peerFounderKey"],"envelope":packet,"sender":from}),
            )?;
            if result["partial"] != true {
                c["peerLibrary"] = result["library"].clone();
                for k in [
                    "peerExpectedLibrary",
                    "peerPendingLocalLibrary",
                    "peerFounderKey",
                    "peerPreviousLibrary",
                    "peerPreviousPeers",
                    "peerPreviousPaused",
                ] {
                    c.as_object_mut().unwrap().remove(k);
                }
                service::write(s, &c)?;
            }
        } else {
            let list = service::core(s, json!({"op":"relay-peer-list"}))?;
            if !list["libraries"]
                .as_array()
                .ok_or("InvalidData")?
                .iter()
                .any(|l| l["id"] == incoming)
            {
                return invalid();
            }
            let status = service::core(s, json!({"op":"relay-peer-status","library":incoming}))?;
            if status["frozen"] == true || status["members"][from]["transportKey"] != key {
                return Err("VaultAccessDenied".into());
            }
            service::core(
                s,
                json!({"op":"relay-peer-receive","library":incoming,"envelope":packet,"sender":from}),
            )?;
        }
    }
    Ok(())
}
