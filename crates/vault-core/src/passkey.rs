//! WebAuthn ES256 credentials. Records belong exclusively in encrypted vault storage.
//! Callers must obtain trusted user consent, bind the live request and persist before responding.
use crate::{Result, VaultError};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use p256::pkcs8::EncodePublicKey;
use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, ZeroizeOnDrop};

#[derive(Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase")]
pub struct PasskeyRecord {
    pub credential_id: String,
    pub rp_id: String,
    pub user_handle: String,
    pub user_name: String,
    pub private_key: String,
    #[serde(default)]
    pub backup_state: bool,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PasskeyResponse {
    pub id: String,
    pub client_data_json: String,
    pub authenticator_data: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attestation_object: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
    pub user_handle: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub public_key: Option<String>,
}
fn client_data(rp: &str, origin: &str, data: &[u8], kind: &str) -> Result<()> {
    let url = url::Url::parse(origin).map_err(|_| VaultError::InvalidData)?;
    if url.scheme() != "https"
        || !url
            .host_str()
            .is_some_and(|host| passkey_rp_matches(host, rp))
        || rp.is_empty()
        || url.origin().ascii_serialization() != origin
        || !url.username().is_empty()
        || url.password().is_some()
        || data.len() > 16_384
    {
        return Err(VaultError::InvalidData);
    }
    let v: serde_json::Value = serde_json::from_slice(data).map_err(|_| VaultError::InvalidData)?;
    let challenge = v["challenge"].as_str().ok_or(VaultError::InvalidData)?;
    let decoded = URL_SAFE_NO_PAD
        .decode(challenge)
        .map_err(|_| VaultError::InvalidData)?;
    if v["type"] != kind
        || v["origin"] != origin
        || v.get("crossOrigin").is_some_and(|x| x != false)
        || v.get("topOrigin").is_some()
        || decoded.len() < 16
        || decoded.len() > 1024
        || URL_SAFE_NO_PAD.encode(decoded) != challenge
    {
        return Err(VaultError::InvalidData);
    }
    Ok(())
}
fn auth_data(rp: &str, attested: bool, verified: bool, backed_up: bool) -> Vec<u8> {
    let mut data = Sha256::digest(rp.as_bytes()).to_vec();
    // UP=1; UV is deliberately unset: clicking a confirmation is not user verification.
    // BE marks backup eligibility. BS remains unset until actual backup acknowledgement exists.
    data.push(
        (if attested { 0x49 } else { 0x09 })
            | if verified { 4 } else { 0 }
            | if backed_up { 16 } else { 0 },
    );
    data.extend_from_slice(&0u32.to_be_bytes()); // synchronized authenticators use zero counters
    data
}
fn bytes(out: &mut Vec<u8>, value: &[u8]) {
    if value.len() < 24 {
        out.push(0x40 + value.len() as u8);
    } else if value.len() < 256 {
        out.extend_from_slice(&[0x58, value.len() as u8]);
    } else {
        out.push(0x59);
        out.extend_from_slice(&(value.len() as u16).to_be_bytes());
    }
    out.extend_from_slice(value);
}
pub fn passkey_create_verified(
    rp_id: &str,
    origin: &str,
    user_handle: &[u8],
    user_name: &str,
    data: &[u8],
    verified: bool,
) -> Result<(PasskeyRecord, PasskeyResponse)> {
    client_data(rp_id, origin, data, "webauthn.create")?;
    create_credential(rp_id, user_handle, user_name, data, verified)
}
fn create_credential(
    rp_id: &str,
    user_handle: &[u8],
    user_name: &str,
    data: &[u8],
    verified: bool,
) -> Result<(PasskeyRecord, PasskeyResponse)> {
    if user_handle.is_empty() || user_handle.len() > 64 || user_name.len() > 1024 {
        return Err(VaultError::InvalidData);
    }
    let key = SigningKey::random(&mut OsRng);
    let mut id = [0u8; 32];
    OsRng.fill_bytes(&mut id);
    let record = PasskeyRecord {
        credential_id: URL_SAFE_NO_PAD.encode(id),
        rp_id: rp_id.into(),
        user_handle: URL_SAFE_NO_PAD.encode(user_handle),
        user_name: user_name.into(),
        private_key: URL_SAFE_NO_PAD.encode(key.to_bytes()),
        backup_state: false,
    };
    let response = passkey_registration_response(&record, data, verified)?;
    Ok((record, response))
}
pub fn passkey_registration_response(
    record: &PasskeyRecord,
    data: &[u8],
    verified: bool,
) -> Result<PasskeyResponse> {
    let mut secret = URL_SAFE_NO_PAD
        .decode(&record.private_key)
        .map_err(|_| VaultError::InvalidData)?;
    let key = SigningKey::from_slice(&secret).map_err(|_| VaultError::InvalidData);
    secret.zeroize();
    let key = key?;
    let id = URL_SAFE_NO_PAD
        .decode(&record.credential_id)
        .map_err(|_| VaultError::InvalidData)?;
    if id.is_empty() || id.len() > 1024 {
        return Err(VaultError::InvalidData);
    }
    let point = key.verifying_key().to_encoded_point(false);
    let public_key = p256::PublicKey::from_sec1_bytes(point.as_bytes())
        .map_err(|_| VaultError::InvalidData)?
        .to_public_key_der()
        .map_err(|_| VaultError::InvalidData)?;
    // COSE_Key: kty EC2, alg ES256, curve P-256, affine coordinates.
    let mut cose = vec![0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21];
    bytes(&mut cose, point.x().ok_or(VaultError::InvalidData)?);
    cose.push(0x22);
    bytes(&mut cose, point.y().ok_or(VaultError::InvalidData)?);
    let mut auth = auth_data(&record.rp_id, true, verified, record.backup_state);
    auth.extend_from_slice(&[0u8; 16]); // anonymous AAGUID
    auth.extend_from_slice(&(id.len() as u16).to_be_bytes());
    auth.extend_from_slice(&id);
    auth.extend_from_slice(&cose);
    let mut attestation = vec![
        0xa3, 0x63, b'f', b'm', b't', 0x64, b'n', b'o', b'n', b'e', 0x67,
    ];
    attestation.extend_from_slice(b"attStmt");
    attestation.push(0xa0);
    attestation.push(0x68);
    attestation.extend_from_slice(b"authData");
    bytes(&mut attestation, &auth);
    let response = PasskeyResponse {
        id: record.credential_id.clone(),
        client_data_json: URL_SAFE_NO_PAD.encode(data),
        authenticator_data: URL_SAFE_NO_PAD.encode(auth),
        attestation_object: Some(URL_SAFE_NO_PAD.encode(attestation)),
        signature: None,
        user_handle: record.user_handle.clone(),
        public_key: Some(URL_SAFE_NO_PAD.encode(public_key.as_bytes())),
    };
    Ok(response)
}
pub fn passkey_assert_verified(
    record: &PasskeyRecord,
    origin: &str,
    data: &[u8],
    verified: bool,
) -> Result<PasskeyResponse> {
    client_data(&record.rp_id, origin, data, "webauthn.get")?;
    sign_credential(record, &Sha256::digest(data), data, verified)
}
fn sign_credential(
    record: &PasskeyRecord,
    hash: &[u8],
    data: &[u8],
    verified: bool,
) -> Result<PasskeyResponse> {
    if hash.len() != 32 {
        return Err(VaultError::InvalidData);
    }
    let mut secret = URL_SAFE_NO_PAD
        .decode(&record.private_key)
        .map_err(|_| VaultError::InvalidData)?;
    let key = SigningKey::from_slice(&secret).map_err(|_| VaultError::InvalidData);
    secret.zeroize();
    let key = key?;
    let auth = auth_data(&record.rp_id, false, verified, record.backup_state);
    let mut signed = auth.clone();
    signed.extend_from_slice(hash);
    let signature: Signature = key.sign(&signed);
    Ok(PasskeyResponse {
        id: record.credential_id.clone(),
        client_data_json: URL_SAFE_NO_PAD.encode(data),
        authenticator_data: URL_SAFE_NO_PAD.encode(auth),
        attestation_object: None,
        signature: Some(URL_SAFE_NO_PAD.encode(signature.to_der().as_bytes())),
        user_handle: record.user_handle.clone(),
        public_key: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::ecdsa::signature::Verifier;
    fn data(kind: &str) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({"type":kind,"origin":"https://example.com","challenge":URL_SAFE_NO_PAD.encode([7u8;32]),"crossOrigin":false})).unwrap()
    }
    #[test]
    fn registration_and_assertion_verify() {
        let (record, created) = passkey_create(
            "example.com",
            "https://example.com",
            b"user",
            "Alice",
            &data("webauthn.create"),
        )
        .unwrap();
        assert!(created.attestation_object.is_some());
        let spki = URL_SAFE_NO_PAD
            .decode(created.public_key.as_ref().unwrap())
            .unwrap();
        assert_eq!(spki.len(), 91);
        assert_eq!(
            &spki[26..],
            SigningKey::from_slice(&URL_SAFE_NO_PAD.decode(&record.private_key).unwrap())
                .unwrap()
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
        );
        let request = data("webauthn.get");
        let result = passkey_assert(&record, "https://example.com", &request).unwrap();
        let key =
            SigningKey::from_slice(&URL_SAFE_NO_PAD.decode(&record.private_key).unwrap()).unwrap();
        let mut message = URL_SAFE_NO_PAD.decode(result.authenticator_data).unwrap();
        assert_eq!(message[32] & 4, 0);
        message.extend_from_slice(&Sha256::digest(request));
        let signature =
            Signature::from_der(&URL_SAFE_NO_PAD.decode(result.signature.unwrap()).unwrap())
                .unwrap();
        key.verifying_key().verify(&message, &signature).unwrap();
        assert!(!serde_json::to_string(&created)
            .unwrap()
            .contains("privateKey"));
    }
    #[test]
    fn rejects_wrong_origin_kind_and_short_challenge() {
        for (rp, origin) in [
            ("com", "https://example.com"),
            ("example.com", "http://example.com"),
            ("evil.com", "https://example.com"),
            ("example.com", "https://example.com/path"),
        ] {
            assert!(passkey_create(rp, origin, b"u", "u", &data("webauthn.create")).is_err());
        }
        assert!(passkey_create(
            "example.com",
            "https://example.com",
            b"u",
            "u",
            &data("webauthn.get")
        )
        .is_err());
        for patch in [
            serde_json::json!({"challenge":"YQ"}),
            serde_json::json!({"crossOrigin":true}),
            serde_json::json!({"origin":"https://evil.com"}),
        ] {
            let mut v: serde_json::Value =
                serde_json::from_slice(&data("webauthn.create")).unwrap();
            for (k, x) in patch.as_object().unwrap() {
                v[k] = x.clone();
            }
            assert!(passkey_create(
                "example.com",
                "https://example.com",
                b"u",
                "u",
                &serde_json::to_vec(&v).unwrap()
            )
            .is_err());
        }
    }
}

/// Metadata only; encrypted credential source never leaves this API.
pub fn passkey_matches(items: &[serde_json::Value], rp_id: &str) -> serde_json::Value {
    let mut result = Vec::new();
    for item in items.iter().filter(|item| item["isDeleted"] != true) {
        for credential in item["passkeys"].as_array().into_iter().flatten() {
            if credential["rpId"] == rp_id {
                result.push(serde_json::json!({"itemId":item["id"],"id":credential["credentialId"],"userName":credential["userName"],"rpId":rp_id}));
            }
        }
    }
    serde_json::json!(result)
}
/// Callers enforce writable-vault permissions and commit atomically before returning response.
#[allow(clippy::too_many_arguments)]
pub fn passkey_register_item(
    item: &mut serde_json::Value,
    origin: &str,
    rp_id: &str,
    user_handle: &[u8],
    user_name: &str,
    data: &[u8],
    excluded: &[String],
    verified: bool,
) -> Result<PasskeyResponse> {
    if item["isDeleted"] == true || !item.is_object() {
        return Err(VaultError::InvalidData);
    }
    if item["passkeys"].as_array().is_some_and(|keys| {
        keys.iter().any(|key| {
            key["rpId"] == rp_id
                && key["credentialId"]
                    .as_str()
                    .is_some_and(|id| excluded.iter().any(|v| v == id))
        })
    }) {
        return Err(VaultError::AlreadyExists);
    }
    let (record, response) =
        passkey_create_verified(rp_id, origin, user_handle, user_name, data, verified)?;
    if item.get("passkeys").is_none() {
        item["passkeys"] = serde_json::json!([]);
    }
    let keys = item["passkeys"]
        .as_array_mut()
        .ok_or(VaultError::InvalidData)?;
    if keys.len() >= 100 {
        return Err(VaultError::InvalidData);
    }
    keys.push(serde_json::to_value(&record).map_err(|_| VaultError::InvalidData)?);
    Ok(response)
}
pub fn passkey_assert_item(
    item: &serde_json::Value,
    credential_id: &str,
    origin: &str,
    data: &[u8],
    allowed: &[String],
    verified: bool,
) -> Result<PasskeyResponse> {
    if item["isDeleted"] == true
        || (!allowed.is_empty() && !allowed.iter().any(|id| id == credential_id))
    {
        return Err(VaultError::Authentication);
    }
    let value = item["passkeys"]
        .as_array()
        .and_then(|keys| keys.iter().find(|key| key["credentialId"] == credential_id))
        .ok_or(VaultError::InvalidData)?;
    let record: PasskeyRecord =
        serde_json::from_value(value.clone()).map_err(|_| VaultError::InvalidData)?;
    passkey_assert_verified(&record, origin, data, verified)
}

// Unverified entry points never set the UV bit. Verified variants are only for trusted authenticators.
pub fn passkey_create(
    rp_id: &str,
    origin: &str,
    user_handle: &[u8],
    user_name: &str,
    data: &[u8],
) -> Result<(PasskeyRecord, PasskeyResponse)> {
    passkey_create_verified(rp_id, origin, user_handle, user_name, data, false)
}
pub fn passkey_assert(
    record: &PasskeyRecord,
    origin: &str,
    data: &[u8],
) -> Result<PasskeyResponse> {
    passkey_assert_verified(record, origin, data, false)
}

/// System provider only: caller must authenticate the OS request and verify the vault owner.
/// Never expose these raw-hash entry points to an extension/page transport.
pub fn passkey_create_system(
    rp_id: &str,
    user_handle: &[u8],
    user_name: &str,
    client_data_hash: &[u8],
) -> Result<(PasskeyRecord, PasskeyResponse)> {
    validate_system_rp(rp_id)?;
    if client_data_hash.len() != 32 {
        return Err(VaultError::InvalidData);
    }
    create_credential(rp_id, user_handle, user_name, &[], true)
}
pub fn passkey_assert_system(
    record: &PasskeyRecord,
    rp_id: &str,
    client_data_hash: &[u8],
) -> Result<PasskeyResponse> {
    validate_system_rp(rp_id)?;
    if record.rp_id != rp_id {
        return Err(VaultError::Authentication);
    }
    sign_credential(record, client_data_hash, &[], true)
}
fn validate_system_rp(rp_id: &str) -> Result<()> {
    let url = url::Url::parse(&format!("https://{rp_id}")).map_err(|_| VaultError::InvalidData)?;
    if !url
        .host_str()
        .is_some_and(|host| passkey_rp_matches(host, rp_id))
        || url.origin().ascii_serialization() != format!("https://{rp_id}")
    {
        return Err(VaultError::InvalidData);
    }
    Ok(())
}

#[cfg(test)]
mod system_tests {
    use super::*;
    use p256::ecdsa::signature::Verifier;
    #[test]
    fn system_hash_is_signed_exactly_and_verification_is_explicit() {
        let hash = [11u8; 32];
        let (record, response) =
            passkey_create_system("example.com", b"owner", "Owner", &hash).unwrap();
        assert_eq!(
            URL_SAFE_NO_PAD.decode(response.authenticator_data).unwrap()[32] & 4,
            4
        );
        let response = passkey_assert_system(&record, "example.com", &hash).unwrap();
        let mut signed = URL_SAFE_NO_PAD.decode(response.authenticator_data).unwrap();
        assert_eq!(signed[32] & 0x10, 0); // backup state is not claimed before acknowledgement
        signed.extend_from_slice(&hash);
        let key =
            SigningKey::from_slice(&URL_SAFE_NO_PAD.decode(&record.private_key).unwrap()).unwrap();
        let signature =
            Signature::from_der(&URL_SAFE_NO_PAD.decode(response.signature.unwrap()).unwrap())
                .unwrap();
        key.verifying_key().verify(&signed, &signature).unwrap();
        assert!(passkey_assert_system(&record, "evil.com", &hash).is_err());
        assert!(passkey_assert_system(&record, "example.com", &[1; 31]).is_err());
        assert!(passkey_create_system("example.com/path", b"owner", "Owner", &hash).is_err());
    }
}

/// PSL-backed RP suffix matching. Reject public suffixes even when equal to the host.
pub fn passkey_rp_matches(host: &str, rp: &str) -> bool {
    psl::domain_str(rp).is_some()
        && (host == rp
            || host
                .strip_suffix(rp)
                .is_some_and(|prefix| prefix.ends_with('.')))
}
#[cfg(test)]
mod rp_tests {
    use super::*;
    #[test]
    fn public_suffixes_and_suffix_confusion_are_rejected() {
        assert!(passkey_rp_matches("login.example.co.uk", "example.co.uk"));
        assert!(!passkey_rp_matches("example.co.uk", "co.uk"));
        assert!(!passkey_rp_matches("evilexample.com", "example.com"));
        assert!(!passkey_rp_matches("user.github.io", "github.io"));
    }
}

/// Remove only a selected credential; caller must reauthenticate before mutation.
pub fn remove_passkey(
    doc: &mut crate::Document,
    item_id: &str,
    credential_id: &str,
) -> Result<serde_json::Value> {
    let mut item = doc
        .items
        .iter()
        .find(|item| item["id"] == item_id)
        .cloned()
        .ok_or(VaultError::InvalidData)?;
    crate::authorize_item_write(doc, &item)?;
    let keys = item["passkeys"]
        .as_array_mut()
        .ok_or(VaultError::InvalidData)?;
    let previous = keys.len();
    keys.retain(|key| key["credentialId"] != credential_id);
    if keys.len() == previous {
        return Err(VaultError::InvalidData);
    }
    item["updatedAt"] = serde_json::json!(web_time::SystemTime::now()
        .duration_since(web_time::UNIX_EPOCH)
        .map_err(|_| VaultError::InvalidData)?
        .as_millis() as u64);
    doc.upsert(item)?;
    Ok(serde_json::json!({"removed":true}))
}

/// Ordinary editors/drafts cannot create credentials or resurrect a removed source.
/// Only explicit authenticator commands and reviewed archive/history restoration own this field.
pub fn preserve_passkeys_for_edit(
    doc: &crate::Document,
    incoming: &mut serde_json::Value,
) -> Result<()> {
    let current = doc.items.iter().find(|item| item["id"] == incoming["id"]);
    let keys = current.and_then(|item| item.get("passkeys")).cloned();
    let object = incoming.as_object_mut().ok_or(VaultError::InvalidData)?;
    match keys {
        Some(keys) => {
            object.insert("passkeys".into(), keys);
        }
        None => {
            object.remove("passkeys");
        }
    }
    Ok(())
}
#[cfg(test)]
mod editor_authority_tests {
    use super::*;
    #[test]
    fn stale_editor_cannot_resurrect_removed_credential_or_inject_new_key() {
        let doc = crate::Document {
            items: vec![serde_json::json!({"id":"existing","passkeys":[]})],
            ..Default::default()
        };
        let mut stale = serde_json::json!({"id":"existing","passkeys":[{"credentialId":"removed","privateKey":"OLD"}]});
        preserve_passkeys_for_edit(&doc, &mut stale).unwrap();
        assert_eq!(stale["passkeys"], serde_json::json!([]));
        let mut new = serde_json::json!({"id":"new","passkeys":[{"credentialId":"injected"}]});
        preserve_passkeys_for_edit(&doc, &mut new).unwrap();
        assert!(new.get("passkeys").is_none());
    }
}

/// Device identity metadata across every library the current member may read.
pub fn passkey_identity_index(libraries: &[(String, crate::Document)]) -> serde_json::Value {
    let mut keys = Vec::new();
    let mut passwords = Vec::new();
    for (library, doc) in libraries {
        for item in doc.items.iter().filter(|item| item["isDeleted"] != true) {
            for key in item["passkeys"].as_array().into_iter().flatten() {
                keys.push(serde_json::json!({"library":library,"itemId":item["id"],"id":key["credentialId"],"rpId":key["rpId"],"userName":key["userName"],"userHandle":key["userHandle"]}));
            }
            if item["type"] == concat!("pass", "word") {
                passwords.push(serde_json::json!({"library":library,"itemId":item["id"],"url":item["url"],"username":item["username"]}));
            }
        }
    }
    serde_json::json!({"passkeys":keys,"passwords":passwords})
}

/// Receipt identity binds the credential ID, RP, user handle and actual P-256 public key.
pub fn passkey_fingerprint(record: &PasskeyRecord) -> Result<String> {
    let mut secret = URL_SAFE_NO_PAD
        .decode(&record.private_key)
        .map_err(|_| VaultError::InvalidData)?;
    let key = SigningKey::from_slice(&secret).map_err(|_| VaultError::InvalidData);
    secret.zeroize();
    let key = key?;
    let bytes=serde_json::to_vec(&serde_json::json!({"id":record.credential_id,"rp":record.rp_id,"user":record.user_handle,"key":URL_SAFE_NO_PAD.encode(key.verifying_key().to_encoded_point(false).as_bytes())})).map_err(|_|VaultError::InvalidData)?;
    Ok(hex::encode(Sha256::digest(bytes)))
}
