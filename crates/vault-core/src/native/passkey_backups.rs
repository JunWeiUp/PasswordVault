//! Native provider backup acknowledgement. No browser-native transport exposes these operations.
use super::*;

fn table(connection: &Connection) -> Result<()> {
    storage(connection.execute_batch("CREATE TABLE IF NOT EXISTS passkey_backup_receipts(nonce TEXT PRIMARY KEY, credential_id TEXT NOT NULL, fingerprint TEXT NOT NULL);CREATE INDEX IF NOT EXISTS passkey_backup_identity ON passkey_backup_receipts(credential_id,fingerprint);"))
}
fn now() -> Result<u64> {
    web_time::SystemTime::now()
        .duration_since(web_time::UNIX_EPOCH)
        .map(|v| v.as_secs())
        .map_err(|_| VaultError::InvalidData)
}
impl DiskVault {
    pub(super) fn passkey_source(
        &mut self,
        request: &Value,
    ) -> Result<(String, String, PasskeyRecord)> {
        let id = request["credentialId"]
            .as_str()
            .ok_or(VaultError::InvalidData)?;
        let open = self.open()?;
        let documents = relay::peer::readable_documents(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            &open.document,
        )?;
        for (library, doc) in documents {
            if request["library"]
                .as_str()
                .is_some_and(|wanted| wanted != library)
            {
                continue;
            }
            for item in doc.items.iter().filter(|item| item["isDeleted"] != true) {
                if request["itemId"]
                    .as_str()
                    .is_some_and(|wanted| item["id"] != wanted)
                {
                    continue;
                }
                if let Some(key) = item["passkeys"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|key| key["credentialId"] == id)
                {
                    let record =
                        serde_json::from_value(key.clone()).map_err(|_| VaultError::InvalidData)?;
                    return Ok((
                        library,
                        item["id"].as_str().ok_or(VaultError::InvalidData)?.into(),
                        record,
                    ));
                }
            }
        }
        Err(VaultError::Authentication)
    }
    pub(super) fn passkey_has_backup(&mut self, record: &PasskeyRecord) -> Result<bool> {
        if record.backup_state {
            return Ok(true);
        }
        let open = self.open()?;
        table(&open.connection)?;
        let count:i64=storage(open.connection.query_row("SELECT count(*) FROM passkey_backup_receipts WHERE credential_id=?1 AND fingerprint=?2",rusqlite::params![record.credential_id,passkey_fingerprint(record)?],|row|row.get(0)))?;
        Ok(count > 0)
    }
    pub(super) fn passkey_backup_command(&mut self, request: &Value) -> Result<Value> {
        let text = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        let open = self.open()?;
        let verified = open.header.unlock(text("currentPassword")?)?;
        if verified.as_ref() != open.root.as_ref() {
            return Err(VaultError::Authentication);
        }
        match text("op")? {
            "passkey-backup-export" => {
                if text("backupPassword")?.chars().count() < 10
                    || text("backupPassword")? == text("currentPassword")?
                {
                    return Err(VaultError::InvalidData);
                }
                let (library, item_id, record) = self.passkey_source(request)?;
                let fingerprint = passkey_fingerprint(&record)?;
                let mut exported = record.clone();
                exported.backup_state = true;
                let mut doc = Document {
                    format_version: 6,
                    ..Document::default()
                };
                doc.upsert(json!({"id":new_id(),"type":concat!("pass","word"),"title":format!("Passkey · {}",record.rp_id),"url":format!("https://{}",record.rp_id),"username":record.user_name,"passkeys":[exported]}))?;
                let encoded = crate::archive::encode_archive(
                    &doc,
                    vec![],
                    vec![],
                    false,
                    text("backupPassword")?,
                    |_| Err(VaultError::InvalidData),
                );
                for item in &mut doc.items {
                    wipe_value(item);
                }
                let content = encoded?;
                let claim = json!({"version":1,"library":library,"itemId":item_id,"credentialId":record.credential_id,"fingerprint":fingerprint,"nonce":new_id(),"expires":now()?+900,"archiveHash":hex::encode(Sha256::digest(content.as_bytes()))});
                let open = self.open()?;
                let receipt = seal(
                    &subkey(&open.root, b"passkey-backup-confirmation-v1"),
                    &serde_json::to_vec(&claim).map_err(|_| VaultError::InvalidData)?,
                    open.header.vault_id.as_bytes(),
                )?;
                Ok(json!({"content":content,"receipt":receipt}))
            }
            "passkey-backup-confirm" => {
                let receipt: Sealed = serde_json::from_value(request["receipt"].clone())
                    .map_err(|_| VaultError::InvalidData)?;
                let open = self.open()?;
                let bytes = unseal(
                    &subkey(&open.root, b"passkey-backup-confirmation-v1"),
                    &receipt,
                    open.header.vault_id.as_bytes(),
                )?;
                let claim: Value =
                    serde_json::from_slice(&bytes).map_err(|_| VaultError::InvalidData)?;
                if claim["version"] != 1
                    || claim["expires"]
                        .as_u64()
                        .is_none_or(|expires| expires < now().unwrap_or(u64::MAX))
                {
                    return Err(VaultError::Authentication);
                }
                for field in ["credentialId", "library", "itemId"] {
                    if request[field].as_str().is_none() || request[field] != claim[field] {
                        return Err(VaultError::Authentication);
                    }
                }
                if request["actualArchiveHash"].as_str().is_none()
                    || request["actualArchiveHash"] != claim["archiveHash"]
                {
                    return Err(VaultError::Authentication);
                }
                let (_, _, record) = self.passkey_source(&claim)?;
                if claim["fingerprint"] != passkey_fingerprint(&record)? {
                    return Err(VaultError::Authentication);
                }
                let nonce = claim["nonce"].as_str().ok_or(VaultError::InvalidData)?;
                let open = self.open()?;
                table(&open.connection)?;
                let existing: i64 = storage(open.connection.query_row(
                    "SELECT count(*) FROM passkey_backup_receipts WHERE nonce=?1",
                    [nonce],
                    |row| row.get(0),
                ))?;
                if existing != 0 {
                    return Err(VaultError::Authentication);
                }
                storage(open.connection.execute("INSERT INTO passkey_backup_receipts(nonce,credential_id,fingerprint) VALUES(?1,?2,?3)",rusqlite::params![nonce,record.credential_id,passkey_fingerprint(&record)?]))?;
                Ok(json!({"confirmed":true}))
            }
            "passkey-system-registration-response" => {
                let (_, _, mut record) = self.passkey_source(request)?;
                if record.rp_id != text("rpId")? {
                    return Err(VaultError::Authentication);
                }
                use base64::Engine;
                if base64::engine::general_purpose::URL_SAFE_NO_PAD
                    .decode(text("clientDataHash")?)
                    .map_err(|_| VaultError::InvalidData)?
                    .len()
                    != 32
                {
                    return Err(VaultError::InvalidData);
                }
                record.backup_state = self.passkey_has_backup(&record)?;
                if !record.backup_state {
                    return Err(VaultError::Authentication);
                }
                serde_json::to_value(passkey_registration_response(&record, &[], true)?)
                    .map_err(|_| VaultError::InvalidData)
            }
            _ => Err(VaultError::Unsupported),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
    #[test]
    fn backup_requires_acknowledgement_and_receipt_matches_current_key() {
        let temp = tempfile::tempdir().unwrap();
        let mut vault = DiskVault::new(temp.path()).unwrap();
        let master = "Synthetic master only!";
        let backup = "Independent backup only!";
        vault.create(master).unwrap();
        let created=vault.command(&json!({"op":"passkey-system-create","rpId":"example.com","userHandle":URL_SAFE_NO_PAD.encode(b"owner"),"userName":"Owner","clientDataHash":URL_SAFE_NO_PAD.encode([5;32]),"currentPassword":master})).unwrap();
        let id = created["id"].as_str().unwrap();
        let (_, item_id, record) = vault.passkey_source(&json!({"credentialId":id})).unwrap();
        let mut export = json!({"op":"passkey-backup-export","credentialId":id,"currentPassword":master,"backupPassword":master});
        assert!(vault.command(&export).is_err());
        export["backupPassword"] = json!(backup);
        let package = vault.command(&export).unwrap();
        // Generation or picker cancellation alone never confirms a backup.
        assert!(!vault.passkey_has_backup(&record).unwrap());
        let archive =
            crate::archive::decode_archive(package["content"].as_str().unwrap(), backup).unwrap();
        assert_eq!(archive.manifest.document.items.len(), 1);
        assert_eq!(
            archive.manifest.document.items[0]["passkeys"][0]["backupState"],
            true
        );
        assert!(crate::archive::decode_archive(
            package["content"].as_str().unwrap(),
            "Wrong backup secret"
        )
        .is_err());
        let mut tampered = package["receipt"].clone();
        tampered["ciphertext"] = json!("invalid");
        assert!(vault
            .command(
                &json!({"op":"passkey-backup-confirm","receipt":tampered,"currentPassword":master})
            )
            .is_err());
        let confirmation = json!({"op":"passkey-backup-confirm","receipt":package["receipt"],"currentPassword":master,"credentialId":id,"itemId":item_id,"library":"","actualArchiveHash":hex::encode(Sha256::digest(package["content"].as_str().unwrap().as_bytes()))});
        let mut wrong_credential = confirmation.clone();
        wrong_credential["credentialId"] = json!("another-credential");
        assert!(vault.command(&wrong_credential).is_err());
        assert!(!vault.passkey_has_backup(&record).unwrap());
        let mut wrong_archive = confirmation.clone();
        wrong_archive["actualArchiveHash"] = json!("00".repeat(32));
        assert!(vault.command(&wrong_archive).is_err());
        assert!(!vault.passkey_has_backup(&record).unwrap());
        vault.command(&confirmation).unwrap();
        assert!(vault.passkey_has_backup(&record).unwrap());
        assert!(vault.command(&confirmation).is_err());
        let response=vault.command(&json!({"op":"passkey-system-registration-response","credentialId":id,"rpId":"example.com","clientDataHash":URL_SAFE_NO_PAD.encode([5;32]),"currentPassword":master})).unwrap();
        assert_eq!(
            URL_SAFE_NO_PAD
                .decode(response["authenticatorData"].as_str().unwrap())
                .unwrap()[32]
                & 16,
            16
        );
        let old = vault.command(&export).unwrap();
        let (replacement, _) =
            passkey_create_system("example.com", b"owner", "Owner", &[3; 32]).unwrap();
        vault
            .mutate(|doc| {
                let item = doc
                    .items
                    .iter_mut()
                    .find(|item| item["id"] == item_id)
                    .unwrap();
                item["passkeys"][0]["privateKey"] = json!(replacement.private_key);
                Ok(json!({}))
            })
            .unwrap();
        assert!(vault.command(&json!({"op":"passkey-backup-confirm","receipt":old["receipt"],"currentPassword":master,"credentialId":id,"itemId":item_id,"library":"","actualArchiveHash":hex::encode(Sha256::digest(old["content"].as_str().unwrap().as_bytes()))})).is_err());
        let (_, _, changed) = vault.passkey_source(&json!({"credentialId":id})).unwrap();
        assert!(!vault.passkey_has_backup(&changed).unwrap());
    }
}
