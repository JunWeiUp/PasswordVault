//! FIDO Credential Exchange Format (CXF v1.0) import and export.
//! Import is stateless like the other formats: preview items are regenerated from source at commit.
//! Export contains private keys in plaintext; callers must reauthenticate and warn before writing.
use crate::import::{ImportPreview, ImportRow};
use crate::{Document, Result, VaultError};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use p256::pkcs8::{DecodePrivateKey, EncodePrivateKey};
use rand::{rngs::OsRng, RngCore};
use serde_json::{json, Value};
use zeroize::Zeroize;

const MAX_ITEMS: usize = 100_000;

fn b64(value: &Value, min: usize, max: usize) -> Option<Vec<u8>> {
    let text = value.as_str()?;
    // Accept padded and standard alphabets as some exporters emit them; re-encode canonically.
    let trimmed = text
        .trim_end_matches('=')
        .replace('+', "-")
        .replace('/', "_");
    let bytes = URL_SAFE_NO_PAD.decode(trimmed).ok()?;
    (bytes.len() >= min && bytes.len() <= max).then_some(bytes)
}
/// EditableField is `{fieldType, value}`; early drafts used a bare string.
fn field(value: &Value) -> Option<String> {
    match value {
        Value::String(s) => Some(s.clone()),
        Value::Object(o) => o.get("value").and_then(Value::as_str).map(str::to_owned),
        _ => None,
    }
    .filter(|s| s.len() <= 65_536)
}
fn timestamp(value: &Value) -> Option<String> {
    let seconds = value.as_i64()?;
    chrono::DateTime::from_timestamp(seconds, 0).map(|t| t.to_rfc3339())
}
fn passkey_record(credential: &Value) -> std::result::Result<Value, String> {
    let rp = credential["rpId"].as_str().ok_or("passkey without rpId")?;
    let url = url::Url::parse(&format!("https://{rp}")).map_err(|_| "invalid rpId")?;
    if url.origin().ascii_serialization() != format!("https://{rp}")
        || !crate::passkey_rp_matches(rp, rp)
    {
        return Err("invalid rpId".into());
    }
    let id = b64(&credential["credentialId"], 1, 1023).ok_or("invalid credentialId")?;
    let user = b64(&credential["userHandle"], 1, 64).ok_or("invalid userHandle")?;
    let mut der = b64(&credential["key"], 1, 4096).ok_or("invalid key")?;
    let key =
        p256::SecretKey::from_pkcs8_der(&der).map_err(|_| "unsupported key (only ES256/P-256)");
    der.zeroize();
    let key = key?;
    let mut scalar = key.to_bytes();
    let user_name = credential["username"]
        .as_str()
        .or(credential["userDisplayName"].as_str())
        .unwrap_or("")
        .chars()
        .take(1024)
        .collect::<String>();
    let mut record = json!({
        "credentialId": URL_SAFE_NO_PAD.encode(id),
        "rpId": rp,
        "userHandle": URL_SAFE_NO_PAD.encode(user),
        "userName": user_name,
        "privateKey": URL_SAFE_NO_PAD.encode(scalar),
        "backupState": false,
    });
    scalar.zeroize();
    // hmac-secret CredRandomWithUV is the PRF secret this authenticator evaluates (always with UV).
    if let Some(secret) = b64(
        &credential["fido2Extensions"]["hmacCredentials"]["credWithUV"],
        32,
        32,
    ) {
        record["prfSecret"] = URL_SAFE_NO_PAD.encode(secret).into();
    }
    let _: crate::PasskeyRecord =
        serde_json::from_value(record.clone()).map_err(|_| "invalid passkey")?;
    Ok(record)
}
/// Appends one preview row per importable CXF item (TOTP credentials become separate items).
pub(crate) fn cxf_rows(bytes: &[u8], out: &mut ImportPreview) -> Result<()> {
    let header: Value = serde_json::from_slice(bytes).map_err(|_| VaultError::InvalidData)?;
    if header["version"]["major"].as_u64() != Some(1) || !header["accounts"].is_array() {
        return Err(VaultError::Unsupported);
    }
    let mut index = 0usize;
    for account in header["accounts"].as_array().into_iter().flatten() {
        for item in account["items"].as_array().into_iter().flatten() {
            if index >= MAX_ITEMS {
                return Err(VaultError::InvalidData);
            }
            let title = item["title"]
                .as_str()
                .unwrap_or("Imported item")
                .chars()
                .take(1024)
                .collect::<String>();
            let url = item["scope"]["urls"]
                .as_array()
                .and_then(|u| u.first())
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned();
            let mut entry = json!({"id":crate::new_id(),"type":"password","title":title,"username":"","password":"","url":url,"note":"","tags":item["tags"].as_array().cloned().unwrap_or_default().into_iter().filter(|t| t.is_string()).take(64).collect::<Vec<_>>(),"isFavorite":item["favorite"] == true,"isDeleted":false});
            if let Some(time) = timestamp(&item["creationAt"]) {
                entry["createdAt"] = time.into();
            }
            if let Some(time) = timestamp(&item["modifiedAt"]) {
                entry["updatedAt"] = time.into();
            }
            let mut warnings = vec![];
            let mut passkeys = vec![];
            let mut extra = vec![];
            let mut useful = false;
            for credential in item["credentials"].as_array().into_iter().flatten() {
                match credential["type"].as_str().unwrap_or("") {
                    "basic-auth" => {
                        if let Some(u) = field(&credential["username"]) {
                            entry["username"] = u.into();
                        }
                        if let Some(p) = field(&credential["password"]) {
                            entry["password"] = p.into();
                        }
                        useful = true;
                    }
                    "passkey" => match passkey_record(credential) {
                        Ok(record) if passkeys.len() < 64 => {
                            if entry["username"] == "" {
                                entry["username"] = record["userName"].clone();
                            }
                            if entry["url"] == "" {
                                entry["url"] =
                                    format!("https://{}", record["rpId"].as_str().unwrap_or(""))
                                        .into();
                            }
                            passkeys.push(record);
                            useful = true;
                        }
                        Ok(_) => warnings.push("too many passkeys in one item".into()),
                        Err(reason) => warnings.push(reason),
                    },
                    "note" => {
                        if let Some(text) = field(&credential["content"]) {
                            entry["note"] = text.into();
                            useful = true;
                        }
                    }
                    "totp" => {
                        let algorithm = credential["algorithm"]
                            .as_str()
                            .unwrap_or("sha1")
                            .to_ascii_lowercase();
                        let digits = credential["digits"].as_u64().unwrap_or(6);
                        let period = credential["period"].as_u64().unwrap_or(30);
                        match credential["secret"].as_str() {
                            Some(secret)
                                if algorithm == "sha1"
                                    && digits == 6
                                    && crate::totp(secret, period, 0).is_ok() =>
                            {
                                extra.push(json!({"id":crate::new_id(),"type":"totp","title":credential["issuer"].as_str().unwrap_or(&title),"username":credential["username"].as_str().unwrap_or(""),"secret":secret,"period":period,"url":url,"note":"","tags":[],"isFavorite":false,"isDeleted":false}));
                            }
                            _ => warnings.push("unsupported TOTP parameters".into()),
                        }
                    }
                    other => warnings.push(format!(
                        "unsupported credential type: {}",
                        other.chars().take(64).collect::<String>()
                    )),
                }
            }
            if !passkeys.is_empty() {
                entry["passkeys"] = Value::Array(passkeys);
            }
            if useful {
                out.rows.push(ImportRow {
                    index,
                    item: entry,
                    duplicate_ids: vec![],
                    warnings: warnings.clone(),
                });
                index += 1;
            } else if extra.is_empty() {
                out.failures.push(json!({"title":title,"reason":warnings.first().cloned().unwrap_or_else(|| "no supported credentials".into())}));
            }
            for totp in extra {
                out.rows.push(ImportRow {
                    index,
                    item: totp,
                    duplicate_ids: vec![],
                    warnings: vec![],
                });
                index += 1;
            }
        }
    }
    Ok(())
}
/// Preview output for clients: private keys and PRF secrets never leave the core before commit.
pub fn redact_import_preview(preview: &mut ImportPreview) {
    for row in &mut preview.rows {
        if let Some(keys) = row.item["passkeys"].as_array_mut() {
            for key in keys {
                if let Some(object) = key.as_object_mut() {
                    object.remove("privateKey");
                    object.remove("prfSecret");
                }
            }
        }
    }
}
/// CXF v1.0 export of password, passkey and TOTP items. Plaintext secrets: reauthenticate first.
pub fn cxf_export(doc: &Document, exporter_rp_id: &str, exporter_name: &str) -> Result<Value> {
    let now = web_time::SystemTime::now()
        .duration_since(web_time::UNIX_EPOCH)
        .map_err(|_| VaultError::InvalidData)?
        .as_secs();
    let seconds = |value: &Value| -> Option<i64> {
        value
            .as_str()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|t| t.timestamp())
            .or_else(|| value.as_u64().map(|ms| (ms / 1000) as i64))
    };
    let mut items = vec![];
    let mut skipped = 0;
    for item in doc.items.iter().filter(|i| i["isDeleted"] != true) {
        let mut credentials = vec![];
        match item["type"].as_str().unwrap_or("") {
            "password" => {
                if item["username"].as_str().is_some_and(|s| !s.is_empty()) || item["password"].as_str().is_some_and(|s| !s.is_empty()) {
                    credentials.push(json!({"type":"basic-auth","username":{"fieldType":"string","value":item["username"].as_str().unwrap_or("")},"password":{"fieldType":"concealed-string","value":item["password"].as_str().unwrap_or("")}}));
                }
                for key in item["passkeys"].as_array().into_iter().flatten() {
                    let record: crate::PasskeyRecord = serde_json::from_value(key.clone()).map_err(|_| VaultError::InvalidData)?;
                    let mut scalar = URL_SAFE_NO_PAD.decode(&record.private_key).map_err(|_| VaultError::InvalidData)?;
                    let secret = p256::SecretKey::from_slice(&scalar).map_err(|_| VaultError::InvalidData);
                    scalar.zeroize();
                    let der = secret?.to_pkcs8_der().map_err(|_| VaultError::InvalidData)?;
                    let mut passkey = json!({"type":"passkey","credentialId":record.credential_id,"rpId":record.rp_id,"username":record.user_name,"userDisplayName":record.user_name,"userHandle":record.user_handle,"key":URL_SAFE_NO_PAD.encode(der.as_bytes())});
                    if let Some(prf) = &record.prf_secret {
                        // This authenticator never evaluates without UV; give that slot an independent value.
                        let mut without = [0u8; 32];
                        OsRng.fill_bytes(&mut without);
                        passkey["fido2Extensions"] = json!({"hmacCredentials":{"algorithm":"hmac-sha256","credWithUV":prf,"credWithoutUV":URL_SAFE_NO_PAD.encode(without)}});
                        without.zeroize();
                    }
                    credentials.push(passkey);
                }
            }
            "totp" => credentials.push(json!({"type":"totp","secret":item["secret"],"period":item["period"].as_u64().unwrap_or(30),"digits":6,"algorithm":"sha1","username":item["username"].as_str().unwrap_or(""),"issuer":item["title"]})),
            _ => {
                skipped += 1;
                continue;
            }
        }
        if credentials.is_empty() {
            skipped += 1;
            continue;
        }
        if item["note"].as_str().is_some_and(|s| !s.is_empty())
            && item["noteFormat"].as_str().unwrap_or("plain") == "plain"
        {
            credentials
                .push(json!({"type":"note","content":{"fieldType":"string","value":item["note"]}}));
        }
        let mut out = json!({"id":URL_SAFE_NO_PAD.encode(item["id"].as_str().unwrap_or("").as_bytes()),"title":item["title"],"credentials":credentials,"favorite":item["isFavorite"] == true});
        if let Some(url) = item["url"].as_str().filter(|s| !s.is_empty()) {
            out["scope"] = json!({"urls":[url],"androidApps":[]});
        }
        if let Some(t) = seconds(&item["createdAt"]) {
            out["creationAt"] = t.into();
        }
        if let Some(t) = seconds(&item["updatedAt"]) {
            out["modifiedAt"] = t.into();
        }
        if let Some(tags) = item["tags"].as_array().filter(|t| !t.is_empty()) {
            out["tags"] = Value::Array(tags.clone());
        }
        items.push(out);
    }
    let mut account = [0u8; 16];
    OsRng.fill_bytes(&mut account);
    Ok(json!({
        "version": {"major": 1, "minor": 0},
        "exporterRpId": exporter_rp_id,
        "exporterDisplayName": exporter_name,
        "timestamp": now,
        "accounts": [{"id": URL_SAFE_NO_PAD.encode(account), "username": "", "email": "", "collections": [], "items": items}],
        "skipped": skipped,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    fn create() -> Vec<u8> {
        serde_json::to_vec(&json!({"type":"webauthn.create","origin":"https://example.com","challenge":URL_SAFE_NO_PAD.encode([7u8;32]),"crossOrigin":false})).unwrap()
    }
    #[test]
    fn round_trip_preserves_passkey_signing_and_prf() {
        let (record, _) = crate::passkey_create(
            "example.com",
            "https://example.com",
            b"user",
            "alice",
            &create(),
        )
        .unwrap();
        let mut doc = Document::default();
        doc.items.push(json!({"id":"a","type":"password","title":"Example","username":"alice","password":"pw","url":"https://example.com","note":"hello","tags":["t"],"passkeys":[serde_json::to_value(&record).unwrap()]}));
        doc.items.push(json!({"id":"b","type":"totp","title":"Issuer","username":"alice","secret":"JBSWY3DPEHPK3PXP","period":30}));
        doc.items
            .push(json!({"id":"c","type":"creditCard","title":"Card","card":{}}));
        let exported = cxf_export(&doc, "passwordvault.local", "PasswordVault").unwrap();
        assert_eq!(exported["skipped"], 1);
        let bytes = serde_json::to_vec(&exported).unwrap();
        let mut preview = ImportPreview {
            rows: vec![],
            failures: vec![],
            columns: vec![],
        };
        cxf_rows(&bytes, &mut preview).unwrap();
        assert_eq!(preview.rows.len(), 2);
        let item = &preview.rows[0].item;
        assert_eq!(item["username"], "alice");
        assert_eq!(item["password"], "pw");
        assert_eq!(item["note"], "hello");
        let key = &item["passkeys"][0];
        assert_eq!(key["privateKey"], record.private_key.as_str());
        assert_eq!(
            key["prfSecret"],
            record.prf_secret.clone().unwrap().as_str()
        );
        assert_eq!(key["credentialId"], record.credential_id.as_str());
        assert_eq!(preview.rows[1].item["type"], "totp");
        // Imported credential signs exactly like the original.
        let imported: crate::PasskeyRecord = serde_json::from_value(key.clone()).unwrap();
        let get = serde_json::to_vec(&json!({"type":"webauthn.get","origin":"https://example.com","challenge":URL_SAFE_NO_PAD.encode([5u8;32])})).unwrap();
        assert!(crate::passkey_assert(&imported, "https://example.com", &get).is_ok());
        // Clients never see private material in the preview.
        redact_import_preview(&mut preview);
        let shown = serde_json::to_string(&preview).unwrap();
        assert!(
            !shown.contains(&record.private_key)
                && !shown.contains(record.prf_secret.as_ref().unwrap())
        );
    }
    #[test]
    fn rejects_bad_versions_keys_and_rp_ids_per_credential() {
        assert!(cxf_rows(
            br#"{"version":{"major":2},"accounts":[]}"#,
            &mut ImportPreview {
                rows: vec![],
                failures: vec![],
                columns: vec![]
            }
        )
        .is_err());
        let ed25519 = "MC4CAQAwBQYDK2VwBCIEINTuctv5E1hK1bbY8fdp-K06_nwoy_HU--CZqg4bxeh2"; // RFC 8410 example key
        let source = json!({"version":{"major":1,"minor":0},"accounts":[{"id":"QQ","items":[
            {"id":"MQ","title":"Bad key","credentials":[{"type":"passkey","credentialId":"AQID","rpId":"example.com","userHandle":"dQ","username":"u","key":ed25519}]},
            {"id":"Mg","title":"Bad rp","credentials":[{"type":"passkey","credentialId":"AQID","rpId":"co.uk","userHandle":"dQ","username":"u","key":ed25519}]},
            {"id":"Mw","title":"Login","credentials":[{"type":"basic-auth","username":{"fieldType":"string","value":"bob"},"password":{"fieldType":"concealed-string","value":"pw"}},{"type":"wifi"}]}
        ]}]});
        let mut preview = ImportPreview {
            rows: vec![],
            failures: vec![],
            columns: vec![],
        };
        cxf_rows(&serde_json::to_vec(&source).unwrap(), &mut preview).unwrap();
        assert_eq!(preview.failures.len(), 2);
        assert_eq!(preview.rows.len(), 1);
        assert_eq!(preview.rows[0].item["username"], "bob");
        assert!(preview.rows[0].warnings[0].contains("unsupported credential type"));
        let mut doc = Document::default();
        let fresh = crate::preview_import(
            "cxf",
            &serde_json::to_vec(&source).unwrap(),
            &BTreeMap::new(),
            &doc,
        )
        .unwrap();
        crate::apply_import(&mut doc, fresh, &BTreeMap::new()).unwrap();
        assert_eq!(doc.items.len(), 1);
    }
}
