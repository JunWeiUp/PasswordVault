//! Wire-compatible common-relay client protocol shared by every PasswordVault client.
//!
//! Pure functions only (no sockets, files or OS keychains): canonical JSON, strict signed
//! payload parsing, signed group-state verification (`advance`), encrypted invitation links
//! and the per-peer message envelope. Byte-for-byte compatibility with the libsodium-based
//! clients is pinned by `tests/fixtures/relay-protocol/*.json` vectors (from upstream common-relay, MIT).
//!
//! Policy decisions (owner, 2026-11-23): a member's `signing_key` can never be added or
//! changed without a full re-admission (only renames are allowed), matching the strict
//! desktop rule.
mod command;
pub mod groups;
pub mod policy;
mod strict;

use base64::{
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
    Engine,
};
use crypto_box::{
    aead::{Aead, AeadCore, OsRng},
    SalsaBox,
};
use crypto_secretbox::{KeyInit, XSalsa20Poly1305};
use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use zeroize::{Zeroize, Zeroizing};

pub use command::{command, OP_PREFIX};
pub use strict::check as strict_check;

/// Protocol error carrying the stable error code shown by clients.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProtocolError(pub &'static str);

impl std::fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

impl std::error::Error for ProtocolError {}

impl From<ProtocolError> for String {
    fn from(e: ProtocolError) -> Self {
        e.0.to_owned()
    }
}

pub type Result<T> = std::result::Result<T, ProtocolError>;

const INVALID: ProtocolError = ProtocolError("InvalidData");

fn invalid<T>() -> Result<T> {
    Err(INVALID)
}

/// Curve25519 public key for the message envelope (libsodium `box_` compatible).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BoxPublicKey(pub [u8; 32]);

impl BoxPublicKey {
    pub fn from_slice(bytes: &[u8]) -> Option<Self> {
        bytes.try_into().ok().map(Self)
    }
}

/// Curve25519 secret key for the message envelope; wiped on drop.
#[derive(Clone)]
pub struct BoxSecretKey(pub [u8; 32]);

impl BoxSecretKey {
    pub fn from_slice(bytes: &[u8]) -> Option<Self> {
        bytes.try_into().ok().map(Self)
    }
    pub fn public_key(&self) -> BoxPublicKey {
        BoxPublicKey(*crypto_box::SecretKey::from(self.0).public_key().as_bytes())
    }
}

impl Drop for BoxSecretKey {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

impl std::fmt::Debug for BoxSecretKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("BoxSecretKey(..)")
    }
}

/// Fresh random envelope key pair, returned as `(public, secret)` like libsodium.
pub fn box_keypair() -> (BoxPublicKey, BoxSecretKey) {
    let secret = crypto_box::SecretKey::generate(&mut OsRng);
    let public = BoxPublicKey(*secret.public_key().as_bytes());
    (public, BoxSecretKey(secret.to_bytes()))
}

/// Ed25519 group-signing public key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SignPublicKey(pub [u8; 32]);

/// Ed25519 group-signing key derived from a device secret; wiped on drop by dalek.
pub struct SignSecretKey(SigningKey);

/// Canonical objects are sorted even if another crate enables serde's preserve_order.
pub fn canonical(v: &Value) -> Vec<u8> {
    fn write(v: &Value, out: &mut String) {
        match v {
            Value::Object(m) => {
                out.push('{');
                let sorted: BTreeMap<_, _> = m.iter().collect();
                for (i, (k, v)) in sorted.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    out.push_str(&Value::String((*k).clone()).to_string());
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

/// Lower-case hex only; anything else is rejected.
pub fn unhex(s: &str) -> Result<Vec<u8>> {
    if !s.len().is_multiple_of(2)
        || !s
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return invalid();
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|_| INVALID))
        .collect()
}

pub fn digest(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

pub fn text<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str().ok_or(INVALID)
}

pub fn payload(entry: &Value) -> Result<Vec<u8>> {
    let bytes = STANDARD
        .decode(text(entry, "payload")?)
        .map_err(|_| INVALID)?;
    if bytes.len() > 32768 {
        return invalid();
    }
    Ok(bytes)
}

/// Decodes a signed entry's payload after strict (unambiguous) JSON validation.
pub fn unpack(entry: &Value) -> Result<Value> {
    let bytes = payload(entry)?;
    if !strict::check(&bytes) {
        return invalid();
    }
    serde_json::from_slice(&bytes).map_err(|_| INVALID)
}

/// Verifies a detached Ed25519 signature over the entry payload (libsodium strictness).
pub fn verify(entry: &Value, key: &str) -> Result<()> {
    let key: [u8; 32] = unhex(key)?.try_into().map_err(|_| INVALID)?;
    let pk = VerifyingKey::from_bytes(&key).map_err(|_| INVALID)?;
    let sig: [u8; 64] = unhex(text(entry, "signature")?)?
        .try_into()
        .map_err(|_| INVALID)?;
    pk.verify_strict(
        &payload(entry)?,
        &ed25519_dalek::Signature::from_bytes(&sig),
    )
    .map_err(|_| INVALID)
}

/// Derives the group-signing key pair from a 32-byte device secret.
pub fn signing(secret: &[u8]) -> Result<(SignPublicKey, SignSecretKey)> {
    if secret.len() != 32 {
        return invalid();
    }
    let mut bytes = Zeroizing::new(b"common-relay/group-signing/v1\0".to_vec());
    bytes.extend(secret);
    let mut seed: [u8; 32] = Sha256::digest(bytes.as_slice()).into();
    let key = SigningKey::from_bytes(&seed);
    seed.zeroize();
    Ok((
        SignPublicKey(key.verifying_key().to_bytes()),
        SignSecretKey(key),
    ))
}

pub fn sign_value(value: &Value, secret: &[u8], device: &str) -> Result<Value> {
    let (_, SignSecretKey(key)) = signing(secret)?;
    let bytes = canonical(value);
    Ok(
        json!({"payload":STANDARD.encode(&bytes),"signature":hex(&key.sign(&bytes).to_bytes()),"signer":device}),
    )
}

fn members(v: &Value) -> Result<&Vec<Value>> {
    v["members"].as_array().ok_or(INVALID)
}

pub fn valid_state(v: &Value) -> Result<()> {
    let ms = members(v)?;
    let closed = v["closed"] == true;
    let ids: BTreeSet<_> = ms.iter().map(|m| m["device"].as_str()).collect();
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

/// Verifies that `entry` is a valid successor of `old_entry`.
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
        .ok_or(INVALID)?;
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
                .ok_or(INVALID)?
                .clone();
            // Only the display name may change in place; keys (including a missing
            // signing_key) can never be filled in or rotated without re-admission.
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

fn secretbox(key: &[u8]) -> Result<XSalsa20Poly1305> {
    XSalsa20Poly1305::new_from_slice(key).map_err(|_| INVALID)
}

pub fn seal_invitation(inv: &Value, key: &[u8], nonce: &[u8]) -> Result<String> {
    let cipher = secretbox(key)?;
    if nonce.len() != 24 {
        return invalid();
    }
    let plain = Zeroizing::new(canonical(
        &json!({"version":1,"purpose":"common-relay/invitation-link/v1","invitation":inv}),
    ));
    let mut packet = nonce.to_vec();
    packet.extend(
        cipher
            .encrypt(nonce.into(), plain.as_slice())
            .map_err(|_| INVALID)?,
    );
    Ok(STANDARD.encode(packet))
}

pub fn open_invitation(packet: &str, key: &[u8]) -> Result<Value> {
    let raw = STANDARD.decode(packet).map_err(|_| INVALID)?;
    if !(40..=16384).contains(&raw.len()) {
        return invalid();
    }
    let cipher = secretbox(key)?;
    let plain = Zeroizing::new(
        cipher
            .decrypt(raw[..24].into(), &raw[24..])
            .map_err(|_| INVALID)?,
    );
    let value: Value = serde_json::from_slice(&plain).map_err(|_| INVALID)?;
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
        Err(ProtocolError("RelayPasswordInvalid"))
    }
}

/// Reads the optional configured access password from a relay/group config.
pub fn configured_password(c: &Value) -> Result<Option<&str>> {
    match c.get("password").and_then(Value::as_str) {
        None | Some("") => Ok(None),
        Some(p) => access_password(p).map(Some),
    }
}

/// Validates a relay WebSocket endpoint (`wss`, or loopback `ws` when `local`).
pub fn endpoint(raw: &str, local: bool) -> Result<url::Url> {
    let u = url::Url::parse(raw).map_err(|_| INVALID)?;
    if !(u.scheme() == "wss" || (local && u.scheme() == "ws" && u.host_str() == Some("127.0.0.1")))
        || u.host_str().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
        || (u.path() != "/relay/v1/ws" && u.path() != "/v2/ws")
    {
        return invalid();
    }
    Ok(u)
}

/// Parsed invitation link: relay URL, invitation ID, link key and optional access password.
pub type ParsedLink = (String, String, Vec<u8>, Option<String>);

/// Returns relay URL, invitation ID, link key and the optional access password from `#key.password`.
pub fn parse_link(link: &str) -> Result<ParsedLink> {
    parse_link_with(link, false)
}

/// Like [`parse_link`]; `allow_local` maps `127.0.0.1` links to a loopback `ws://` relay for tests.
pub fn parse_link_with(link: &str, allow_local: bool) -> Result<ParsedLink> {
    if link.len() > 2048 {
        return invalid();
    }
    let mut u = url::Url::parse(link).map_err(|_| INVALID)?;
    if u.scheme() != "common-relay"
        || u.host_str().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
    {
        return invalid();
    }
    let (is_v2, id_part) = if let Some(rest) = u.path().strip_prefix("/v2/i/") {
        (true, rest)
    } else if let Some(rest) = u.path().strip_prefix("/i/") {
        (false, rest)
    } else {
        return invalid();
    };
    let id = URL_SAFE_NO_PAD.decode(id_part).map_err(|_| INVALID)?;
    let fragment = u.fragment().ok_or(INVALID)?.to_owned();
    let (raw_key, raw_password) = match fragment.split_once('.') {
        Some((k, p)) => (k, Some(p)),
        None => (fragment.as_str(), None),
    };
    let key = URL_SAFE_NO_PAD.decode(raw_key).map_err(|_| INVALID)?;
    let password = match raw_password {
        None => None,
        Some(p) => {
            let bytes = URL_SAFE_NO_PAD.decode(p).map_err(|_| INVALID)?;
            if URL_SAFE_NO_PAD.encode(&bytes) != p {
                return invalid();
            }
            let text = String::from_utf8(bytes).map_err(|_| INVALID)?;
            access_password(&text).map_err(|_| INVALID)?;
            Some(text)
        }
    };
    if id.len() != 16 || key.len() != 32 {
        return invalid();
    }
    // url::Url forbids switching between special and non-special schemes.
    let host = u.host_str().ok_or(INVALID)?.to_owned();
    let port = u.port().map(|p| format!(":{p}")).unwrap_or_default();
    u.set_fragment(None);
    let ws_path = if is_v2 { "/v2/ws" } else { "/relay/v1/ws" };
    let scheme = if allow_local && host == "127.0.0.1" {
        "ws"
    } else {
        "wss"
    };
    Ok((
        format!("{scheme}://{host}{port}{ws_path}"),
        hex(&id),
        key,
        password,
    ))
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
    make_link_with(invitation, key, password, false)
}

/// Like [`make_link`]; `allow_local` accepts a loopback `ws://127.0.0.1` relay for tests.
pub fn make_link_with(
    invitation: &Value,
    key: &[u8],
    password: Option<&str>,
    allow_local: bool,
) -> Result<String> {
    if key.len() != 32 {
        return invalid();
    }
    let endpoint = endpoint(text(invitation, "url")?, allow_local)?;
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
    let link_prefix = if endpoint.path() == "/v2/ws" {
        "/v2/i/"
    } else {
        "/i/"
    };
    Ok(format!(
        "common-relay://{authority}{link_prefix}{}#{}{suffix}",
        URL_SAFE_NO_PAD.encode(id),
        URL_SAFE_NO_PAD.encode(key)
    ))
}

/// Per-device envelope identity: seals messages for, and opens messages from, trusted peers.
pub struct Identity {
    pub app: String,
    pub group: String,
    pub device: String,
    pub secret: BoxSecretKey,
    pub trusted: BTreeMap<String, BoxPublicKey>,
}

impl Identity {
    fn context(&self, from: &str, to: &str, kind: &str, id: &str) -> Value {
        json!([1, self.app, self.group, from, to, kind, id])
    }

    fn cipher(&self, peer: &str) -> Result<SalsaBox> {
        let key = self
            .trusted
            .get(peer)
            .ok_or(ProtocolError("UntrustedPeer"))?;
        Ok(SalsaBox::new(
            &crypto_box::PublicKey::from(key.0),
            &crypto_box::SecretKey::from(self.secret.0),
        ))
    }

    pub fn seal(&self, to: &str, kind: &str, id: &str, value: Value) -> Result<String> {
        let cipher = self.cipher(to)?;
        let nonce = SalsaBox::generate_nonce(&mut OsRng);
        let plain = Zeroizing::new(
            json!({"context":self.context(&self.device,to,kind,id),"value":value}).to_string(),
        );
        let mut raw = nonce.to_vec();
        raw.extend(
            cipher
                .encrypt(&nonce, plain.as_bytes())
                .map_err(|_| INVALID)?,
        );
        Ok(STANDARD.encode(raw))
    }

    pub fn open(&self, from: &str, kind: &str, id: &str, body: &str) -> Result<Value> {
        let cipher = self.cipher(from)?;
        let raw = STANDARD.decode(body).map_err(|_| INVALID)?;
        if !(40..=270336).contains(&raw.len()) {
            return invalid();
        }
        let plain = Zeroizing::new(
            cipher
                .decrypt(raw[..24].into(), &raw[24..])
                .map_err(|_| ProtocolError("Authentication"))?,
        );
        let v: Value = serde_json::from_slice(&plain).map_err(|_| INVALID)?;
        if v["context"] != self.context(from, &self.device, kind, id) || !v["value"].is_object() {
            return invalid();
        }
        Ok(v["value"].clone())
    }
}

#[cfg(test)]
mod tests;
