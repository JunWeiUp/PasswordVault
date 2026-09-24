use crate::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

fn decode_key(input: &str) -> Result<[u8; 32]> {
    STANDARD
        .decode(input)
        .map_err(|_| VaultError::InvalidData)?
        .try_into()
        .map_err(|_| VaultError::InvalidData)
}

pub fn sharing_identity(doc: &mut Document) -> Result<String> {
    if let Some(public) = doc.settings["sharingIdentity"]["publicKey"].as_str() {
        decode_key(public)?;
        let private = StaticSecret::from(decode_key(
            doc.settings["sharingIdentity"]["privateKey"]
                .as_str()
                .ok_or(VaultError::InvalidData)?,
        )?);
        if PublicKey::from(&private).as_bytes() != &decode_key(public)? {
            return Err(VaultError::Authentication);
        }
        return Ok(public.into());
    }
    let private = StaticSecret::from(random_bytes::<32>());
    let public = STANDARD.encode(PublicKey::from(&private).as_bytes());
    doc.settings["sharingIdentity"] =
        json!({"publicKey":public,"privateKey":STANDARD.encode(private.to_bytes())});
    Ok(public)
}

fn private_key(doc: &Document) -> Result<StaticSecret> {
    Ok(StaticSecret::from(decode_key(
        doc.settings["sharingIdentity"]["privateKey"]
            .as_str()
            .ok_or(VaultError::Authentication)?,
    )?))
}

fn shared_secret(private: &StaticSecret, peer: &str, context: &[u8]) -> Result<Secret> {
    let shared = private.diffie_hellman(&PublicKey::from(decode_key(peer)?));
    if !shared.was_contributory() {
        return Err(VaultError::Authentication);
    }
    let mut key = Zeroizing::new([0; 32]);
    hkdf::Hkdf::<Sha256>::new(Some(context), shared.as_bytes())
        .expand(b"", key.as_mut())
        .map_err(|_| VaultError::InvalidData)?;
    Ok(key)
}

fn wrap_for_recipient(value: &[u8], recipient: &str) -> Result<String> {
    let ephemeral = StaticSecret::from(random_bytes::<32>());
    let key = shared_secret(&ephemeral, recipient, b"PasswordVault-ECIES-v1")?;
    let sealed = seal(&key, value, b"")?;
    let mut bytes = PublicKey::from(&ephemeral).as_bytes().to_vec();
    bytes.extend(
        STANDARD
            .decode(sealed.nonce)
            .map_err(|_| VaultError::InvalidData)?,
    );
    bytes.extend(
        STANDARD
            .decode(sealed.ciphertext)
            .map_err(|_| VaultError::InvalidData)?,
    );
    Ok(STANDARD.encode(bytes))
}

fn unwrap_for_self(doc: &Document, wrapped: &str) -> Result<Secret> {
    let bytes = STANDARD
        .decode(wrapped)
        .map_err(|_| VaultError::InvalidData)?;
    if bytes.len() < 60 {
        return Err(VaultError::InvalidData);
    }
    let key = shared_secret(
        &private_key(doc)?,
        &STANDARD.encode(&bytes[..32]),
        b"PasswordVault-ECIES-v1",
    )?;
    let plain = legacy_decrypt(&bytes[32..], &key)?;
    Ok(Zeroizing::new(
        plain
            .as_slice()
            .try_into()
            .map_err(|_| VaultError::Authentication)?,
    ))
}

pub fn create_shared(doc: &mut Document, name: &str, time: &str) -> Result<Value> {
    if name.trim().is_empty() || name.len() > 256 {
        return Err(VaultError::InvalidData);
    }
    let public = sharing_identity(doc)?;
    let id = new_id();
    let key = Zeroizing::new(random_bytes::<32>());
    let wrapped = wrap_for_recipient(key.as_ref(), &public)?;
    let vault = json!({"id":id,"name":name,"encryptedVaultKey":wrapped,"createdAt":time,"updatedAt":time,"isDiscoverable":false});
    doc.shared_vaults.push(vault.clone());
    doc.shared_members.push(json!({"id":new_id(),"vaultId":id,"userPublicKey":public,"encryptedVaultKey":wrapped,"role":"owner"}));
    Ok(vault)
}

pub fn add_member(
    doc: &mut Document,
    vault_id: &str,
    public: &str,
    role: &str,
    name: &str,
) -> Result<Value> {
    decode_key(public)?;
    if !["viewer", "editor"].contains(&role) {
        return Err(VaultError::InvalidData);
    }
    let own = sharing_identity(doc)?;
    if !doc
        .shared_members
        .iter()
        .any(|m| m["vaultId"] == vault_id && m["userPublicKey"] == own && m["role"] == "owner")
    {
        return Err(VaultError::Authentication);
    }
    if doc
        .shared_members
        .iter()
        .any(|m| m["vaultId"] == vault_id && m["userPublicKey"] == public)
    {
        return Err(VaultError::AlreadyExists);
    }
    let vault = doc
        .shared_vaults
        .iter()
        .find(|v| v["id"] == vault_id)
        .ok_or(VaultError::InvalidData)?;
    let key = unwrap_for_self(
        doc,
        vault["encryptedVaultKey"]
            .as_str()
            .ok_or(VaultError::InvalidData)?,
    )?;
    let member = json!({"id":new_id(),"vaultId":vault_id,"userPublicKey":public,"encryptedVaultKey":wrap_for_recipient(key.as_ref(),public)?,"role":role,"name":name});
    doc.shared_members.push(member.clone());
    Ok(member)
}

fn packet(
    doc: &mut Document,
    recipient: &str,
    vault_id: &str,
    kind: &str,
    body: &Value,
) -> Result<Value> {
    let sender = sharing_identity(doc)?;
    let id = new_id();
    let context = json!({"version":2,"sender":sender,"recipient":recipient,"vaultId":vault_id,"kind":kind,"id":id,"issuedAt":unix_time()?});
    let aad = serde_json::to_vec(&context).map_err(|_| VaultError::InvalidData)?;
    let key = shared_secret(&private_key(doc)?, recipient, b"PasswordVault-Sync-v2")?;
    let bytes = Zeroizing::new(serde_json::to_vec(body).map_err(|_| VaultError::InvalidData)?);
    Ok(json!({"context":context,"payload":seal(&key,&bytes,&aad)?}))
}

fn open_packet(doc: &mut Document, packet: &Value, expected_kind: &str) -> Result<Value> {
    let own = sharing_identity(doc)?;
    let c = &packet["context"];
    if c["version"] != 2 || c["recipient"] != own || c["kind"] != expected_kind {
        return Err(VaultError::Authentication);
    }
    let id = c["id"]
        .as_str()
        .filter(|s| s.len() == 32)
        .ok_or(VaultError::InvalidData)?;
    let now = unix_time()?;
    let issued = c["issuedAt"].as_u64().ok_or(VaultError::InvalidData)?;
    if issued.abs_diff(now) > 300 {
        return Err(VaultError::Authentication);
    }
    let mut seen = doc.settings["syncSeen"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    seen.retain(|v| {
        v["time"]
            .as_u64()
            .is_some_and(|t| t.saturating_add(300) >= now)
    });
    if seen.iter().any(|v| v["id"] == id) {
        return Err(VaultError::Authentication);
    }
    if seen.len() >= 4096 {
        return Err(VaultError::InvalidData);
    }
    let sender = c["sender"].as_str().ok_or(VaultError::InvalidData)?;
    let key = shared_secret(&private_key(doc)?, sender, b"PasswordVault-Sync-v2")?;
    let aad = serde_json::to_vec(c).map_err(|_| VaultError::InvalidData)?;
    let sealed =
        serde_json::from_value(packet["payload"].clone()).map_err(|_| VaultError::InvalidData)?;
    let body = unseal(&key, &sealed, &aad)?;
    let parsed = serde_json::from_slice(&body).map_err(|_| VaultError::InvalidData)?;
    seen.push(json!({"id":id,"time":issued}));
    doc.settings["syncSeen"] = json!(seen);
    Ok(parsed)
}

pub fn create_sync_request(doc: &mut Document, peer: &str, vault_id: &str) -> Result<Value> {
    // Only existing editors/owners include local updates. A new member first fetches an invitation.
    let own = sharing_identity(doc)?;
    let editable = doc.shared_members.iter().any(|m| {
        m["vaultId"] == vault_id
            && m["userPublicKey"] == own
            && [json!("owner"), json!("editor")].contains(&m["role"])
    });
    let items: Vec<Value> = if editable {
        doc.items
            .iter()
            .filter(|v| v["sharedVaultId"] == vault_id)
            .cloned()
            .collect()
    } else {
        vec![]
    };
    let request = packet(doc, peer, vault_id, "request", &json!({"items":items}))?;
    let now = unix_time()?;
    let mut pending = doc.settings["syncPending"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    pending.retain(|v| {
        v["time"]
            .as_u64()
            .is_some_and(|t| t.saturating_add(300) >= now)
    });
    if pending.len() >= 64 {
        return Err(VaultError::InvalidData);
    }
    pending.push(json!({"id":request["context"]["id"],"peer":peer,"vaultId":vault_id,"time":now}));
    doc.settings["syncPending"] = json!(pending);
    Ok(request)
}

pub fn respond_sync(doc: &mut Document, request: &Value) -> Result<Value> {
    let peer = request["context"]["sender"]
        .as_str()
        .ok_or(VaultError::InvalidData)?
        .to_owned();
    let id = request["context"]["vaultId"]
        .as_str()
        .ok_or(VaultError::InvalidData)?
        .to_owned();
    let member = doc
        .shared_members
        .iter()
        .find(|m| m["vaultId"] == id && m["userPublicKey"] == peer)
        .cloned()
        .ok_or(VaultError::Authentication)?;
    let body = open_packet(doc, request, "request")?;
    let incoming = body["items"].as_array().ok_or(VaultError::InvalidData)?;
    if !incoming.is_empty() {
        if ![json!("editor"), json!("owner")].contains(&member["role"]) {
            return Err(VaultError::Authentication);
        }
        if incoming.iter().any(|v| v["sharedVaultId"] != id) {
            return Err(VaultError::Authentication);
        }
        if incoming.iter().any(|v| {
            doc.items
                .iter()
                .any(|old| old["id"] == v["id"] && old["sharedVaultId"] != id)
        }) {
            return Err(VaultError::Authentication);
        }
        let import = Document::parse(
            &serde_json::to_vec(&json!({"items":incoming})).map_err(|_| VaultError::InvalidData)?,
        )?;
        doc.merge(import)?;
    }
    let mut vault = doc
        .shared_vaults
        .iter()
        .find(|v| v["id"] == id)
        .cloned()
        .ok_or(VaultError::InvalidData)?;
    vault["encryptedVaultKey"] = member["encryptedVaultKey"].clone();
    let members: Vec<Value> = doc
        .shared_members
        .iter()
        .filter(|m| m["vaultId"] == id)
        .cloned()
        .collect();
    let items: Vec<Value> = doc
        .items
        .iter()
        .filter(|v| v["sharedVaultId"] == id)
        .cloned()
        .collect();
    packet(
        doc,
        &peer,
        &id,
        "response",
        &json!({"items":items,"sharedVaults":[vault],"sharedMembers":members,"replyTo":request["context"]["id"]}),
    )
}

pub fn apply_sync(
    doc: &mut Document,
    response: &Value,
    peer: &str,
    vault_id: &str,
) -> Result<Value> {
    if response["context"]["sender"] != peer || response["context"]["vaultId"] != vault_id {
        return Err(VaultError::Authentication);
    }
    let body = open_packet(doc, response, "response")?;
    let pending = doc.settings["syncPending"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    if !pending
        .iter()
        .any(|v| v["id"] == body["replyTo"] && v["peer"] == peer && v["vaultId"] == vault_id)
    {
        return Err(VaultError::Authentication);
    }
    doc.settings["syncPending"] = json!(pending
        .into_iter()
        .filter(|v| v["id"] != body["replyTo"])
        .collect::<Vec<_>>());
    let mut incoming =
        Document::parse(&serde_json::to_vec(&body).map_err(|_| VaultError::InvalidData)?)?;
    if incoming
        .items
        .iter()
        .any(|v| v["sharedVaultId"] != vault_id)
        || incoming.shared_vaults.iter().any(|v| v["id"] != vault_id)
        || incoming
            .shared_members
            .iter()
            .any(|v| v["vaultId"] != vault_id)
    {
        return Err(VaultError::Authentication);
    }
    if incoming.items.iter().any(|v| {
        doc.items
            .iter()
            .any(|old| old["id"] == v["id"] && old["sharedVaultId"] != vault_id)
    }) {
        return Err(VaultError::Authentication);
    }
    let existing = doc.shared_vaults.iter().any(|v| v["id"] == vault_id);
    let peer_owner = doc
        .shared_members
        .iter()
        .any(|m| m["vaultId"] == vault_id && m["userPublicKey"] == peer && m["role"] == "owner");
    if existing && !peer_owner {
        if !doc.shared_members.iter().any(|m| {
            m["vaultId"] == vault_id && m["userPublicKey"] == peer && m["role"] == "editor"
        }) {
            return Err(VaultError::Authentication);
        }
        incoming.shared_vaults.clear();
        incoming.shared_members.clear();
    } else {
        if !incoming
            .shared_members
            .iter()
            .any(|m| m["vaultId"] == vault_id && m["userPublicKey"] == peer && m["role"] == "owner")
        {
            return Err(VaultError::Authentication);
        }
        let own = sharing_identity(doc)?;
        let self_member = incoming
            .shared_members
            .iter()
            .find(|m| m["vaultId"] == vault_id && m["userPublicKey"] == own)
            .ok_or(VaultError::Authentication)?;
        unwrap_for_self(
            doc,
            self_member["encryptedVaultKey"]
                .as_str()
                .ok_or(VaultError::Authentication)?,
        )?;
        // An authenticated owner snapshot is authoritative, including revoked members.
        doc.shared_members.retain(|m| m["vaultId"] != vault_id);
        doc.shared_vaults.retain(|v| v["id"] != vault_id);
    }
    let count = doc.merge(incoming)?;
    Ok(json!({"imported":count}))
}

fn unix_time() -> Result<u64> {
    web_time::SystemTime::now()
        .duration_since(web_time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .map_err(|_| VaultError::InvalidData)
}

pub fn authorize_item_write(doc: &Document, item: &Value) -> Result<()> {
    let Some(id) = item["sharedVaultId"].as_str().filter(|s| !s.is_empty()) else {
        return Ok(());
    };
    let own = doc.settings["sharingIdentity"]["publicKey"]
        .as_str()
        .ok_or(VaultError::Authentication)?;
    if doc.shared_members.iter().any(|m| {
        m["vaultId"] == id
            && m["userPublicKey"] == own
            && [json!("owner"), json!("editor")].contains(&m["role"])
    }) {
        Ok(())
    } else {
        Err(VaultError::Authentication)
    }
}

pub fn remove_member(doc: &mut Document, vault_id: &str, public: &str) -> Result<Value> {
    let own = sharing_identity(doc)?;
    if own == public
        || !doc
            .shared_members
            .iter()
            .any(|m| m["vaultId"] == vault_id && m["userPublicKey"] == own && m["role"] == "owner")
    {
        return Err(VaultError::Authentication);
    }
    doc.shared_members
        .retain(|m| !(m["vaultId"] == vault_id && m["userPublicKey"] == public));
    Ok(json!({"ok":true}))
}
