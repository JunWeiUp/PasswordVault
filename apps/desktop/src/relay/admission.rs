//! One durable user decision spanning membership approval and vault access.
use super::{Result, access, invalid, protocol::*, service};
use serde_json::{Value, json};
use vault_core::VaultSession;

pub fn prepare(s: &VaultSession, c: &mut Value, g: &Value, code: &str) -> Result<()> {
    let state = unpack(&g["group_entry"])?;
    if service::primary_device(c, g, &state).as_deref() != c["device"].as_str() {
        return Err("PrimaryRequired".into());
    }
    if c["pendingAdmission"].is_object() {
        if c["pendingAdmission"]["cancelled"] != true {
            if c["pendingAdmission"]["code"] != code { return Err("VerificationCodeMismatch".into()); }
            return Ok(());
        }
        // A new, independently verified invitation may replace a cancelled
        // decision; the original request can never resurrect its access.
        if g["pending_approval"].is_object() || !g["join_request"].is_object()
            || digest(&payload(&g["join_request"])?) == c["pendingAdmission"]["requestHash"] {
            return Err("AdmissionCancelled".into());
        }
    }
    if g["issued_invitation"]["mode"] != "manual"
        || g["issued_invitation"]["expires"].as_u64().unwrap_or(0) <= super::groups::now() { return invalid(); }
    let request = &g["join_request"];
    let hash = digest(&payload(request)?);
    let upper = hash[..12].to_uppercase();
    let expected = format!("{}-{}-{}", &upper[..4], &upper[4..8], &upper[8..12]);
    if code != expected { return Err("VerificationCodeMismatch".into()); }
    let req = unpack(request)?;
    verify(request, text(&req["member"], "signing_key")?)?;
    if req["group"] != g["group"] || req["app"] != g["app"]
        || req["invitation"] != g["issued_invitation"]["id"]
        || req["member"]["device"] == c["device"] { return invalid(); }
    c["pendingAdmission"] = json!({
        "id":uuid::Uuid::new_v4().to_string(),"group":g["group"],
        "requestHash":hash,"code":code,"peer":req["member"]["device"],
        "key":req["member"]["public_key"],"signingKey":req["member"]["signing_key"],
        "cancelled":false,"pauseRevision":c["pauseRevision"]
    });
    service::write(s, c)
}

pub fn has_receipt(g: &Value, intent: &Value) -> Result<bool> {
    if !g["approval_receipt"].is_object() || !intent.is_object() { return Ok(false); }
    let state = unpack(&g["approval_receipt"])?;
    Ok(state["request_hash"] == intent["requestHash"] && state["group"] == intent["group"])
}

/// Caller holds CONTROL. Network work has finished; re-read the latest decision
/// so a concurrent revoke cannot be undone by an older HTTP response.
pub fn complete_locked(s: &VaultSession) -> Result<()> {
    let c = service::read(s)?;
    let intent = &c["pendingAdmission"];
    if !intent.is_object() || intent["cancelled"] == true { return Ok(()); }
    let g = service::group(&c)?;
    if !has_receipt(&g, intent)? { return Ok(()); }
    let state = unpack(&g["group_entry"])?;
    if service::primary_device(&c, &g, &state).as_deref() != c["device"].as_str()
        || c["group"] != intent["group"] { return Err("PrimaryRequired".into()); }
    let peer = text(intent, "peer")?;
    if g["trusted_peers"][peer] != intent["key"]
        || !state["members"].as_array().ok_or("InvalidData")?.iter().any(|m|
            m["device"] == peer && m["public_key"] == intent["key"]
            && m["signing_key"] == intent["signingKey"] && m["manager"] == false)
    { return Err("AdmissionIdentityChanged".into()); }
    access::set_decision_locked(s, peer, true, Some(text(intent, "id")?))
}
