use super::*;
impl BrowserVault {
    pub(super) fn draft_command(&mut self, request: &Value) -> Result<Value> {
        match request["op"].as_str().ok_or(VaultError::InvalidData)? {
            "draft-read" => Ok(json!({"item":self.extras.draft})),
            "draft-clear" => {
                self.extras.draft = None;
                Ok(json!({"ok":true}))
            }
            "draft-save" => {
                let mut item = request["item"].clone();
                normalize_item(&mut item)?;
                authorize_item_write(&self.document, &item)?;
                if let Some(current) = self
                    .document
                    .items
                    .iter()
                    .find(|current| current["id"] == item["id"])
                {
                    authorize_item_write(&self.document, current)?;
                }
                if serde_json::to_vec(&item)
                    .map_err(|_| VaultError::InvalidData)?
                    .len()
                    > MAX_INPUT
                {
                    return Err(VaultError::InvalidData);
                }
                item["_draftLibrary"] = self.document.settings["activePeerLibrary"].clone();
                self.extras.draft = Some(item);
                self.validate_extras()?;
                Ok(json!({"ok":true}))
            }
            _ => Err(VaultError::Unsupported),
        }
    }
}
