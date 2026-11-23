use super::*;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
impl BrowserVault {
    pub(super) fn passkey_command(&mut self, request: &Value) -> Result<Value> {
        let text = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        let op = text("op")?;
        if ["passkey-index", "passkey-matches"].contains(&op) {
            let index = passkey_identity_index(&[(String::new(), self.document.clone())]);
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
        if !["passkey-create", "passkey-assert", "passkey-remove"].contains(&op) {
            return Err(VaultError::Unsupported);
        }
        let verified_root = self.header.unlock(text("currentPassword")?)?;
        if verified_root.as_ref() != self.root.as_ref() {
            return Err(VaultError::Authentication);
        }
        if op == "passkey-remove" {
            return remove_passkey(&mut self.document, text("itemId")?, text("credentialId")?);
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
        let response: Value = if op == "passkey-create" {
            if request
                .get("library")
                .is_some_and(|v| v.as_str() != Some(""))
            {
                return Err(VaultError::Authentication);
            }
            let excluded = list("excluded")?;
            let rp = text("rpId")?;
            let readable = [(String::new(), self.document.clone())];
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
            let document = &mut self.document;
            return (|| {
                let mut item = if let Some(id) = request["itemId"].as_str() {
                    document
                        .items
                        .iter()
                        .find(|item| item["id"] == id)
                        .cloned()
                        .ok_or(VaultError::InvalidData)?
                } else {
                    json!({"id":new_id(),"type":concat!("pass","word"),"title":rp,"url":text("origin")?,"username":text("userName")?})
                };
                authorize_item_write(document, &item)?;
                let user = URL_SAFE_NO_PAD
                    .decode(text("userHandle")?)
                    .map_err(|_| VaultError::InvalidData)?;
                let response = passkey_register_item(
                    &mut item,
                    text("origin")?,
                    rp,
                    &user,
                    text("userName")?,
                    text("clientDataJSON")?.as_bytes(),
                    &excluded,
                    true,
                )?;
                item["updatedAt"] = json!(web_time::SystemTime::now()
                    .duration_since(web_time::UNIX_EPOCH)
                    .map_err(|_| VaultError::InvalidData)?
                    .as_millis() as u64);
                document.format_version = document.format_version.max(6);
                let item_id = item["id"].clone();
                let credential = item["passkeys"]
                    .as_array()
                    .and_then(|keys| keys.last())
                    .cloned()
                    .unwrap_or_default();
                document.upsert(item)?;
                let mut response =
                    serde_json::to_value(response).map_err(|_| VaultError::InvalidData)?;
                passkey_attach_prf(&mut response, &credential, request, true)?;
                response["library"] = json!("");
                response["itemId"] = item_id;
                Ok(response)
            })();
        } else {
            let id = text("itemId")?;
            // Only the personal library exists; a stale library scope cannot match.
            if request["library"].as_str().is_some_and(|l| !l.is_empty()) {
                return Err(VaultError::Authentication);
            }
            let document = self.document.clone();
            let item = document
                .items
                .iter()
                .find(|item| item["id"] == id)
                .ok_or(VaultError::InvalidData)?;
            let response = passkey_assert_item(
                item,
                text("credentialId")?,
                text("origin")?,
                text("clientDataJSON")?.as_bytes(),
                &list("allowed")?,
                true,
            )?;
            let mut response =
                serde_json::to_value(response).map_err(|_| VaultError::InvalidData)?;
            if let Some(credential) = item["passkeys"].as_array().and_then(|keys| {
                keys.iter()
                    .find(|key| key["credentialId"] == text("credentialId").unwrap_or(""))
            }) {
                passkey_attach_prf(&mut response, credential, request, false)?;
            }
            response
        };
        Ok(response)
    }
}
