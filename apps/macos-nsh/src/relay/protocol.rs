//! Wire-compatible common-relay group verification and encrypted invitation links.
use super::{Result, invalid};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use serde_json::{Value, json};
use sodiumoxide::crypto::{hash::sha256, secretbox, sign};

/// Canonical objects are sorted even if another crate enables serde's preserve_order.
pub fn canonical(v: &Value) -> Vec<u8> {
    fn write(v: &Value, out: &mut String) {
        match v {
            Value::Object(m) => {
                out.push('{');
                let sorted: std::collections::BTreeMap<_, _> = m.iter().collect();
                for (i, (k, v)) in sorted.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    out.push_str(&serde_json::to_string(k).unwrap());
                    out.push(':');
                    write(v, out);
                }
                out.push('}');
            }
            Value::Array(a) => {
                out.push('[');
                for (i, v) in a.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write(v, out);
                }
                out.push(']');
            }
            _ => out.push_str(&v.to_string()),
        }
    }
    let mut out = String::new();
    write(v, &mut out);
    out.into_bytes()
}
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
pub fn unhex(s: &str) -> Result<Vec<u8>> {
    if s.len() % 2 != 0
        || !s
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return invalid();
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|_| "InvalidData".into()))
        .collect()
}
pub fn digest(bytes: &[u8]) -> String {
    hex(&sha256::hash(bytes).0)
}
pub fn text<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str().ok_or("InvalidData".into())
}
pub fn payload(entry: &Value) -> Result<Vec<u8>> {
    let bytes = STANDARD
        .decode(text(entry, "payload")?)
        .map_err(|_| "InvalidData")?;
    if bytes.len() > 32768 {
        return invalid();
    }
    Ok(bytes)
}
pub fn unpack(entry: &Value) -> Result<Value> {
    let bytes = payload(entry)?;
    if !super::strict::check(&bytes) {
        return invalid();
    }
    serde_json::from_slice(&bytes).map_err(|_| "InvalidData".into())
}
pub fn verify(entry: &Value, key: &str) -> Result<()> {
    let pk = sign::PublicKey::from_slice(&unhex(key)?).ok_or("InvalidData")?;
    let sig = sign::Signature::from_bytes(&unhex(text(entry, "signature")?)?)
        .map_err(|_| "InvalidData")?;
    if !sign::verify_detached(&sig, &payload(entry)?, &pk) {
        return invalid();
    }
    Ok(())
}
pub fn signing(secret: &[u8]) -> Result<(sign::PublicKey, sign::SecretKey)> {
    if secret.len() != 32 {
        return invalid();
    }
    let mut bytes = zeroize::Zeroizing::new(b"common-relay/group-signing/v1\0".to_vec());
    bytes.extend(secret);
    let seed = sign::Seed::from_slice(&sha256::hash(&bytes).0).ok_or("InvalidData")?;
    Ok(sign::keypair_from_seed(&seed))
}
pub fn sign_value(value: &Value, secret: &[u8], device: &str) -> Result<Value> {
    let (_, key) = signing(secret)?;
    let bytes = canonical(value);
    Ok(
        json!({"payload":STANDARD.encode(&bytes),"signature":hex(sign::sign_detached(&bytes,&key).as_ref()),"signer":device}),
    )
}
fn members(v: &Value) -> Result<&Vec<Value>> {
    v["members"].as_array().ok_or("InvalidData".into())
}
pub(super) fn valid_state(v: &Value) -> Result<()> {
    let ms = members(v)?;
    let closed = v["closed"] == true;
    let ids: std::collections::BTreeSet<_> = ms.iter().map(|m| m["device"].as_str()).collect();
    if v["version"] != 1
        || ms.len() > 32
        || ids.len() != ms.len()
        || (closed && !ms.is_empty())
        || (!closed && !ms.iter().any(|m| m["manager"] == true))
    {
        return invalid();
    }
    Ok(())
}
/// `old_entry` must already be pinned by an invitation or locally created identity.
pub fn advance(old_entry: &Value, entry: &Value) -> Result<Value> {
    let old = unpack(old_entry)?;
    let next = unpack(entry)?;
    valid_state(&next)?;
    let before = members(&old)?;
    let after = members(&next)?;
    let actor = before
        .iter()
        .find(|m| m["device"] == entry["signer"])
        .ok_or("InvalidData")?;
    if old["closed"] == true
        || old["app"] != next["app"]
        || old["group"] != next["group"]
        || old["name"].as_str().unwrap_or("") != next["name"].as_str().unwrap_or("")
        || next["revision"].as_u64() != old["revision"].as_u64().and_then(|n| n.checked_add(1))
        || next["previous"] != digest(&payload(old_entry)?)
    {
        return invalid();
    }
    let added: Vec<_> = after
        .iter()
        .filter(|m| !before.iter().any(|b| b["device"] == m["device"]))
        .collect();
    let removed: Vec<_> = before
        .iter()
        .filter(|m| !after.iter().any(|b| b["device"] == m["device"]))
        .collect();
    if let Some(auth) = entry.get("authorization") {
        let grant = unpack(auth)?;
        if auth.get("authorization").is_some()
            || actor["manager"] != true
            || auth["signer"] != actor["device"]
        {
            return invalid();
        }
        verify(auth, text(actor, "signing_key")?)?;
        if grant["version"] != 1
            || grant["purpose"] != "common-relay/admission/v1"
            || grant["mode"] != "auto"
            || grant["app"] != old["app"]
            || grant["group"] != old["group"]
            || grant["anchor_revision"].as_u64().unwrap_or(0) < 1
            || grant["anchor_revision"].as_u64() > old["revision"].as_u64()
            || grant["expires"].as_u64().unwrap_or(0) == 0
        {
            return invalid();
        }
        for (k, n) in [
            ("invitation", 16),
            ("secret_hash", 32),
            ("delegate_key", 32),
            ("anchor_hash", 32),
        ] {
            if unhex(text(&grant, k)?)?.len() != n {
                return invalid();
            }
        }
        verify(entry, text(&grant, "delegate_key")?)?;
        if next["closed"] == true
            || next["invitation"] != grant["invitation"]
            || unhex(text(&next, "request_hash")?)?.len() != 32
            || after.len() != before.len() + 1
            || added.len() != 1
            || added[0]["manager"] != false
            || !before.iter().all(|m| after.contains(m))
        {
            return invalid();
        }
        if old["revision"] == grant["anchor_revision"]
            && grant["anchor_hash"] != digest(&payload(old_entry)?)
        {
            return invalid();
        }
    } else {
        verify(entry, text(actor, "signing_key")?)?;
        let changed: Vec<_> = after
            .iter()
            .filter(|m| before.iter().any(|b| b["device"] == m["device"] && b != *m))
            .collect();
        if !changed.is_empty() {
            if changed.len() != 1 || !added.is_empty() || !removed.is_empty() {
                return invalid();
            }
            let m = changed[0];
            let mut prior = before
                .iter()
                .find(|b| b["device"] == m["device"])
                .unwrap()
                .clone();
            prior["name"] = m["name"].clone();
            if prior != *m
                || !(actor["manager"] == true || m["device"] == actor["device"])
                || next["invitation"] != ""
                || next["request_hash"] != ""
            {
                return invalid();
            }
        } else {
            let empty = next["invitation"] == "" && next["request_hash"] == "";
            let add = actor["manager"] == true
                && added.len() == 1
                && removed.is_empty()
                && next["invitation"] != ""
                && next["request_hash"] != "";
            let remove = removed.len() == 1
                && added.is_empty()
                && empty
                && (actor["manager"] == true || removed[0]["device"] == actor["device"]);
            let close =
                next["closed"] == true && actor["manager"] == true && after.is_empty() && empty;
            if !(add || remove || close) {
                return invalid();
            }
        }
    }
    Ok(entry.clone())
}
pub fn seal_invitation(inv: &Value, key: &[u8], nonce: &[u8]) -> Result<String> {
    let key = secretbox::Key::from_slice(key).ok_or("InvalidData")?;
    let nonce = secretbox::Nonce::from_slice(nonce).ok_or("InvalidData")?;
    let plain = zeroize::Zeroizing::new(canonical(
        &json!({"version":1,"purpose":"common-relay/invitation-link/v1","invitation":inv}),
    ));
    let mut packet = nonce.0.to_vec();
    packet.extend(secretbox::seal(&plain, &nonce, &key));
    Ok(STANDARD.encode(packet))
}
pub fn open_invitation(packet: &str, key: &[u8]) -> Result<Value> {
    let raw = STANDARD.decode(packet).map_err(|_| "InvalidData")?;
    if !(40..=16384).contains(&raw.len()) {
        return invalid();
    }
    let key = secretbox::Key::from_slice(key).ok_or("InvalidData")?;
    let nonce = secretbox::Nonce::from_slice(&raw[..24]).ok_or("InvalidData")?;
    let plain = zeroize::Zeroizing::new(
        secretbox::open(&raw[24..], &nonce, &key).map_err(|_| "InvalidData")?,
    );
    let value: Value = serde_json::from_slice(&plain).map_err(|_| "InvalidData")?;
    if value["version"] != 1
        || value["purpose"] != "common-relay/invitation-link/v1"
        || !value["invitation"].is_object()
    {
        return invalid();
    }
    Ok(value["invitation"].clone())
}
/// Server access password header required by the relay on every /relay/v1 request.
pub const ACCESS_HEADER: &str = "Relay-Access";
/// Validates a relay access password: 8-128 printable ASCII characters without spaces.
pub fn access_password(p: &str) -> Result<&str> {
    if (8..=128).contains(&p.len()) && p.bytes().all(|b| (0x21..=0x7e).contains(&b)) {
        Ok(p)
    } else {
        Err("RelayPasswordInvalid".into())
    }
}
/// Reads the optional configured access password from a relay/group config.
pub fn configured_password(c: &Value) -> Result<Option<&str>> {
    match c.get("password").and_then(Value::as_str) {
        None | Some("") => Ok(None),
        Some(p) => access_password(p).map(Some),
    }
}
/// Returns relay URL, invitation ID, link key and the optional access password from `#key.password`.
pub fn parse_link(link: &str) -> Result<(String, String, Vec<u8>, Option<String>)> {
    if link.len() > 2048 {
        return invalid();
    }
    let mut u = url::Url::parse(link).map_err(|_| "InvalidData")?;
    if u.scheme() != "common-relay"
        || u.host_str().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
    {
        return invalid();
    }
    let id = URL_SAFE_NO_PAD
        .decode(u.path().strip_prefix("/i/").ok_or("InvalidData")?)
        .map_err(|_| "InvalidData")?;
    let fragment = u.fragment().ok_or("InvalidData")?.to_owned();
    let (raw_key, raw_password) = match fragment.split_once('.') {
        Some((k, p)) => (k, Some(p)),
        None => (fragment.as_str(), None),
    };
    let key = URL_SAFE_NO_PAD.decode(raw_key).map_err(|_| "InvalidData")?;
    let password = match raw_password {
        None => None,
        Some(p) => {
            let bytes = URL_SAFE_NO_PAD.decode(p).map_err(|_| "InvalidData")?;
            if URL_SAFE_NO_PAD.encode(&bytes) != p {
                return invalid();
            }
            let text = String::from_utf8(bytes).map_err(|_| "InvalidData")?;
            access_password(&text).map_err(|_| "InvalidData")?;
            Some(text)
        }
    };
    if id.len() != 16 || key.len() != 32 {
        return invalid();
    }
    // url::Url forbids switching between special and non-special schemes.
    let host = u.host_str().ok_or("InvalidData")?.to_owned();
    let port = u.port().map(|p| format!(":{p}")).unwrap_or_default();
    u.set_fragment(None);
    Ok((format!("wss://{host}{port}/relay/v1/ws"), hex(&id), key, password))
}
pub fn read_token(key: &[u8]) -> Result<String> {
    if key.len() != 32 {
        return invalid();
    }
    let mut bytes = b"common-relay/invitation-link/read/v1\0".to_vec();
    bytes.extend(key);
    Ok(digest(&bytes))
}
/// Builds a compact URL; only the encrypted packet and read-token hash go to HTTP.
pub fn make_link(invitation: &Value, key: &[u8], password: Option<&str>) -> Result<String> {
    if key.len() != 32 {
        return invalid();
    }
    let endpoint = super::transport::endpoint(text(invitation, "url")?, false)?;
    let id = unhex(text(invitation, "id")?)?;
    if id.len() != 16 {
        return invalid();
    }
    let authority = &endpoint[url::Position::BeforeHost..url::Position::AfterPort];
    // The access password, like the key, stays in the fragment and never reaches HTTP.
    let suffix = match password {
        Some(p) => format!(".{}", URL_SAFE_NO_PAD.encode(access_password(p)?)),
        None => String::new(),
    };
    Ok(format!(
        "common-relay://{authority}/i/{}#{}{suffix}",
        URL_SAFE_NO_PAD.encode(id),
        URL_SAFE_NO_PAD.encode(key)
    ))
}
