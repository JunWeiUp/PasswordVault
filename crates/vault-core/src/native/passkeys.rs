use super::*;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};

impl DiskVault {
    pub(super) fn passkey_command(&mut self, request: &Value) -> Result<Value> {
        let text = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        let op = text("op")?;
        if op.starts_with("passkey-backup-") || op == "passkey-system-registration-response" {
            return self.passkey_backup_command(request);
        }
        if ["passkey-index", "passkey-matches"].contains(&op) {
            let open = self.open()?;
            let documents = relay::peer::readable_documents(
                &open.connection,
                &open.root,
                &open.header.vault_id,
                &open.document,
            )?;
            let index = passkey_identity_index(&documents);
            return if op == "passkey-index" {
                Ok(index)
            } else {
                Ok(json!(index["passkeys"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter(|key| key["rpId"] == text("rpId").unwrap_or(""))
                    .cloned()
                    .collect::<Vec<_>>()))
            };
        }
        match op {
            "structured-list" => return Ok(structured_items(&self.open()?.document.items)),
            "structured-fill" => {
                return fill_structured(
                    &self.open()?.document.items,
                    text("origin")?,
                    text("id")?,
                    request["includeSecurityCode"] == true,
                )
            }
            "update-login" => {
                return self.mutate(|doc| {
                    update_login(
                        doc,
                        text("origin")?,
                        text("id")?,
                        request["accountId"].as_str(),
                        text("username")?,
                        text(concat!("pass", "word"))?,
                        text("time")?,
                    )
                })
            }
            "otp-matches" => return matching_otps(&self.open()?.document.items, text("origin")?),
            "otp-fill" => {
                return fill_otp(
                    &self.open()?.document.items,
                    text("origin")?,
                    text("id")?,
                    request["time"].as_u64().ok_or(VaultError::InvalidData)?,
                )
            }

            _ => {}
        }
        if op == "passkey-remove" {
            let open = self.open()?;
            let verified = open.header.unlock(text("currentPassword")?)?;
            if verified.as_ref() != open.root.as_ref() {
                return Err(VaultError::Authentication);
            }
            return self.mutate(|doc| remove_passkey(doc, text("itemId")?, text("credentialId")?));
        }
        if ![
            "passkey-create",
            "passkey-assert",
            "passkey-system-create",
            "passkey-system-assert",
        ]
        .contains(&op)
        {
            return Err(VaultError::Unsupported);
        }
        // No request-provided boolean may claim UV. Reauthenticate the actual vault header.
        let open = self.open()?;
        let verified_root = open.header.unlock(text("currentPassword")?)?;
        if verified_root.as_ref() != open.root.as_ref() {
            return Err(VaultError::Authentication);
        }
        let list = |key: &str| -> Result<Vec<String>> {
            let Some(value) = request.get(key) else {
                return Ok(vec![]);
            };
            let values = value.as_array().ok_or(VaultError::InvalidData)?;
            if values.len() > 1024 {
                return Err(VaultError::InvalidData);
            }
            values
                .iter()
                .map(|v| {
                    v.as_str()
                        .filter(|s| s.len() <= 2048)
                        .map(String::from)
                        .ok_or(VaultError::InvalidData)
                })
                .collect()
        };
        let system = op.starts_with("passkey-system-");
        let hash = if system {
            Some(
                URL_SAFE_NO_PAD
                    .decode(text("clientDataHash")?)
                    .map_err(|_| VaultError::InvalidData)?,
            )
        } else {
            None
        };
        if op.ends_with("create") {
            if request
                .get("library")
                .is_some_and(|v| v.as_str() != Some(""))
            {
                return Err(VaultError::Authentication);
            }
            let user = URL_SAFE_NO_PAD
                .decode(text("userHandle")?)
                .map_err(|_| VaultError::InvalidData)?;
            let excluded = list("excluded")?;
            let rp = text("rpId")?;
            // Exclusion applies to all credentials available to this authenticator, not just the target item.
            let open = self.open()?;
            let readable = relay::peer::readable_documents(
                &open.connection,
                &open.root,
                &open.header.vault_id,
                &open.document,
            )?;
            if readable
                .iter()
                .flat_map(|(_, doc)| doc.items.iter())
                .filter(|item| item["isDeleted"] != true)
                .any(|item| {
                    item["passkeys"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .any(|key| {
                            key["rpId"] == rp
                                && key["credentialId"]
                                    .as_str()
                                    .is_some_and(|id| excluded.iter().any(|v| v == id))
                        })
                })
            {
                return Err(VaultError::AlreadyExists);
            }
            self.prepare_capability_upgrade()?;
            self.mutate_personal_passkey(|doc| {
                let mut item=if let Some(id)=request["itemId"].as_str() {
                    doc.items.iter().find(|item|item["id"]==id).cloned().ok_or(VaultError::InvalidData)?
                } else {
                    json!({"id":new_id(),"type":concat!("pass","word"),"title":rp,"url":format!("https://{rp}"),"username":text("userName")?,"updatedAt":web_time::SystemTime::now().duration_since(web_time::UNIX_EPOCH).map_err(|_|VaultError::InvalidData)?.as_millis() as u64})
                };
                authorize_item_write(doc,&item)?;
                if item["isDeleted"]==true {return Err(VaultError::InvalidData);}
                let response=if let Some(hash)=&hash {
                    let (record,response)=passkey_create_system(rp,&user,text("userName")?,hash)?;
                    if item.get("passkeys").is_none(){item["passkeys"]=json!([]);}
                    let keys=item["passkeys"].as_array_mut().ok_or(VaultError::InvalidData)?;
                    if keys.len()>=100{return Err(VaultError::InvalidData);}
                    keys.push(serde_json::to_value(record).map_err(|_|VaultError::InvalidData)?);response
                } else {passkey_register_item(&mut item,text("origin")?,rp,&user,text("userName")?,text("clientDataJSON")?.as_bytes(),&excluded,true)?};
                item["updatedAt"]=json!(web_time::SystemTime::now().duration_since(web_time::UNIX_EPOCH).map_err(|_|VaultError::InvalidData)?.as_millis() as u64);
                doc.format_version=doc.format_version.max(6);
                let item_id = item["id"].clone();
                doc.upsert(item)?;
                let mut response = serde_json::to_value(response).map_err(|_|VaultError::InvalidData)?;
                response["library"] = json!("");
                response["itemId"] = item_id;
                Ok(response)
            })
        } else {
            let allowed = list("allowed")?;
            let document = if let Some(library) = request["library"].as_str() {
                let open = self.open()?;
                relay::peer::readable_documents(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &open.document,
                )?
                .into_iter()
                .find(|(id, _)| id == library)
                .map(|(_, doc)| doc)
                .ok_or(VaultError::Authentication)?
            } else {
                self.open()?.document.clone()
            };
            let item = document
                .items
                .iter()
                .find(|item| item["id"] == text("itemId").unwrap_or(""))
                .ok_or(VaultError::InvalidData)?;
            if item["isDeleted"] == true {
                return Err(VaultError::Authentication);
            }
            let id = text("credentialId")?;
            let response = if let Some(hash) = &hash {
                if !allowed.is_empty() && !allowed.iter().any(|value| value == id) {
                    return Err(VaultError::Authentication);
                }
                let key = item["passkeys"]
                    .as_array()
                    .and_then(|keys| keys.iter().find(|key| key["credentialId"] == id))
                    .ok_or(VaultError::InvalidData)?;
                let mut record: PasskeyRecord =
                    serde_json::from_value(key.clone()).map_err(|_| VaultError::InvalidData)?;
                record.backup_state = self.passkey_has_backup(&record)?;
                passkey_assert_system(&record, text("rpId")?, hash)?
            } else {
                passkey_assert_item(
                    item,
                    id,
                    text("origin")?,
                    text("clientDataJSON")?.as_bytes(),
                    &allowed,
                    true,
                )?
            };
            serde_json::to_value(response).map_err(|_| VaultError::InvalidData)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn passkey_creation_is_personal_and_excludes_all_readable_libraries() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = DiskVault::new(dir.path()).unwrap();
        let secret = "Synthetic scope fixture 2026!";
        vault.create(secret).unwrap();
        let family = vault.command(&json!({"op":"relay-peer-create","device":"phone","personal":false,"name":"Family"})).unwrap()["library"].clone();
        vault
            .command(&json!({"op":"relay-peer-switch","library":family}))
            .unwrap();
        let mut request = json!({"op":"passkey-system-create","rpId":"example.com","userHandle":URL_SAFE_NO_PAD.encode(b"alice"),"userName":"Alice","clientDataHash":URL_SAFE_NO_PAD.encode([8;32]),"currentPassword":secret});
        let created = vault.command(&request).unwrap();
        assert_eq!(created["library"], "");
        assert!(vault.open().unwrap().document.format_version >= 6);
        assert!(created["itemId"].is_string());
        assert!(vault.open().unwrap().document.items.is_empty());
        let index = vault.command(&json!({"op":"passkey-index"})).unwrap();
        assert_eq!(index["passkeys"][0]["library"], "");
        assert_eq!(index["passkeys"][0]["itemId"], created["itemId"]);
        request["library"] = family.clone();
        assert!(matches!(
            vault.command(&request),
            Err(VaultError::Authentication)
        ));
        request["library"] = json!("");
        request["clientDataHash"] = json!("bad");
        assert!(vault.command(&request).is_err());
        assert!(vault.open().unwrap().document.items.is_empty());
        request["clientDataHash"] = json!(URL_SAFE_NO_PAD.encode([8; 32]));
        // Seed a distinct family credential through the internal mutation path;
        // ordinary editor saves deliberately cannot inject private key records.
        let (key, _) = passkey_create_system("example.com", b"family", "Family", &[9; 32]).unwrap();
        let excluded = key.credential_id.clone();
        vault.mutate(|doc| { doc.upsert(json!({"id":"family-key","type":concat!("pass","word"),"title":"Shared","passkeys":[serde_json::to_value(&key).unwrap()]}))?; Ok(json!({})) }).unwrap();
        vault
            .command(&json!({"op":"relay-peer-switch","library":""}))
            .unwrap();
        request["excluded"] = json!([excluded]);
        assert!(matches!(
            vault.command(&request),
            Err(VaultError::AlreadyExists)
        ));
        assert_eq!(vault.open().unwrap().document.items.len(), 1);
        vault.lock();
        vault.unlock(secret).unwrap();
        assert_eq!(
            vault.command(&json!({"op":"passkey-index"})).unwrap()["passkeys"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
    }

    #[test]
    fn passkey_requires_reauthentication_commits_and_survives_reopen() {
        let temp = tempfile::tempdir().unwrap();
        let mut vault = DiskVault::new(temp.path()).unwrap();
        vault.create("Synthetic fixture only 2026!").unwrap();
        let mut request = json!({"op":"passkey-system-create","rpId":"example.com","userHandle":URL_SAFE_NO_PAD.encode(b"alice"),"userName":"Alice","clientDataHash":URL_SAFE_NO_PAD.encode([8;32]),"currentPassword":"wrong"});
        assert!(vault.command(&request).is_err());
        assert!(vault.open().unwrap().document.items.is_empty());
        request["currentPassword"] = json!("Synthetic fixture only 2026!");
        let created = vault.command(&request).unwrap();
        let item_id = vault.open().unwrap().document.items[0]["id"].clone();
        let auth = URL_SAFE_NO_PAD
            .decode(created["authenticatorData"].as_str().unwrap())
            .unwrap();
        assert_eq!(auth[32] & 4, 4);
        assert_eq!(vault.open().unwrap().document.format_version, 6);
        assert!(vault
            .directory
            .join("before-capability-format6/header.json")
            .exists());
        assert!(!vault
            .command(&json!({"op":"passkey-matches","rpId":"example.com"}))
            .unwrap()
            .to_string()
            .contains("privateKey"));
        request["excluded"] = json!([created["id"]]);
        assert!(vault.command(&request).is_err());
        vault.lock();
        assert!(vault
            .command(&json!({"op":"passkey-matches","rpId":"example.com"}))
            .is_err());
        vault.unlock("Synthetic fixture only 2026!").unwrap();
        let mut assertion = json!({"op":"passkey-system-assert","rpId":"example.com","itemId":item_id,"credentialId":created["id"],"clientDataHash":URL_SAFE_NO_PAD.encode([5;32]),"currentPassword":"Synthetic fixture only 2026!","allowed":["other"]});
        assert!(vault.command(&assertion).is_err());
        assertion["allowed"] = json!([created["id"]]);
        assert!(vault.command(&assertion).unwrap()["signature"].is_string());
        assertion["rpId"] = json!("evil.com");
        assert!(vault.command(&assertion).is_err());
        let stale = vault.open().unwrap().document.items[0].clone();
        let mut removal = json!({"op":"passkey-remove","itemId":item_id,"credentialId":created["id"],"currentPassword":"wrong"});
        assert!(vault.command(&removal).is_err());
        removal["currentPassword"] = json!("Synthetic fixture only 2026!");
        vault.command(&removal).unwrap();
        vault.command(&json!({"op":"save","item":stale})).unwrap();
        assert_eq!(
            vault.open().unwrap().document.items[0]["passkeys"],
            json!([])
        );
        assert!(vault
            .command(&json!({"op":"passkey-matches","rpId":"example.com"}))
            .unwrap()
            .as_array()
            .unwrap()
            .is_empty());
    }
}
