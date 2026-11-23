//! Stateless JSON entry point so the Kotlin and Swift relay clients reuse this protocol
//! through `VaultSession::command` instead of carrying their own implementations.
//! Byte strings (secrets, keys, nonces) are lower-case hex; ops are registered in
//! `contract/commands.json` under the `relay-protocol` group and never touch the vault.
use super::*;

pub const OP_PREFIX: &str = "relay-protocol-";

fn field<'a>(request: &'a Value, key: &str) -> Result<&'a Value> {
    request.get(key).filter(|v| !v.is_null()).ok_or(INVALID)
}

fn bytes(request: &Value, key: &str) -> Result<Zeroizing<Vec<u8>>> {
    Ok(Zeroizing::new(unhex(text(request, key)?)?))
}

fn flag(request: &Value, key: &str) -> bool {
    request[key].as_bool().unwrap_or(false)
}

fn identity(request: &Value, peer: &str) -> Result<Identity> {
    let secret = BoxSecretKey::from_slice(&bytes(request, "secret")?).ok_or(INVALID)?;
    let peer_key = BoxPublicKey::from_slice(&bytes(request, "peerKey")?).ok_or(INVALID)?;
    Ok(Identity {
        app: text(request, "app")?.to_owned(),
        group: text(request, "group")?.to_owned(),
        device: text(request, "device")?.to_owned(),
        secret,
        trusted: [(peer.to_owned(), peer_key)].into(),
    })
}

/// Runs one `relay-protocol-*` op.
pub fn command(request: &Value) -> Result<Value> {
    let op = text(request, "op")?;
    match op.strip_prefix(OP_PREFIX).ok_or(INVALID)? {
        "keys" => {
            let secret = bytes(request, "secret")?;
            let (signing_key, _) = signing(&secret)?;
            let box_secret = BoxSecretKey::from_slice(&secret).ok_or(INVALID)?;
            Ok(
                json!({"publicKey":hex(&box_secret.public_key().0),"signingKey":hex(&signing_key.0)}),
            )
        }
        "unpack" => Ok(json!({"state": unpack(field(request, "entry")?)?})),
        "verify" => {
            verify(field(request, "entry")?, text(request, "key")?)?;
            Ok(json!({"ok":true}))
        }
        "advance" => {
            Ok(json!({"entry": advance(field(request, "current")?, field(request, "entry")?)?}))
        }
        "sign" => Ok(json!({"entry": sign_value(
            field(request, "value")?,
            &bytes(request, "secret")?,
            text(request, "device")?,
        )?})),
        "seal-invitation" => Ok(json!({"packet": seal_invitation(
            field(request, "invitation")?,
            &bytes(request, "key")?,
            &bytes(request, "nonce")?,
        )?})),
        "open-invitation" => Ok(json!({"invitation": open_invitation(
            text(request, "packet")?,
            &bytes(request, "key")?,
        )?})),
        "read-token" => Ok(json!({"token": read_token(&bytes(request, "key")?)?})),
        "make-link" => Ok(json!({"link": make_link_with(
            field(request, "invitation")?,
            &bytes(request, "key")?,
            request["password"].as_str(),
            flag(request, "allowLocal"),
        )?})),
        "parse-link" => {
            let (url, id, key, password) =
                parse_link_with(text(request, "link")?, flag(request, "allowLocal"))?;
            let key = Zeroizing::new(key);
            Ok(json!({"url":url,"id":id,"key":hex(&key),"password":password}))
        }
        "envelope-seal" => {
            let to = text(request, "to")?;
            let body = identity(request, to)?.seal(
                to,
                text(request, "kind")?,
                text(request, "id")?,
                field(request, "value")?.clone(),
            )?;
            Ok(json!({"body":body}))
        }
        "envelope-open" => {
            let from = text(request, "from")?;
            let value = identity(request, from)?.open(
                from,
                text(request, "kind")?,
                text(request, "id")?,
                text(request, "body")?,
            )?;
            Ok(json!({"value":value}))
        }
        _ => invalid(),
    }
}
