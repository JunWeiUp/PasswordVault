//! `sharing` ops (see `contract/commands.json`): Shared vaults: identity, membership, sealing and sync packets.
//! Routed from `DiskVault::command` after the shared checks (registry, lock, format guards).
use super::super::*;

impl DiskVault {
    pub(in crate::native) fn sharing_ops(&mut self, op: &str, request: &Value) -> Result<Value> {
        let string = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        match op {
            "share-options" => {
                let open = self.open()?;
                let mut item = open
                    .document
                    .items
                    .iter()
                    .find(|i| i["id"] == string("id").unwrap_or("") && i["isDeleted"] != true)
                    .cloned()
                    .ok_or(VaultError::InvalidData)?;
                note_bodies::hydrate_item(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &mut item,
                )?;
                let mut used = std::collections::HashSet::new();
                crate::archive::item_attachment_refs(&item, &mut used)?;
                let files: Vec<_> = notes::metas(&open.connection)?
                    .into_iter()
                    .filter(|m| m.note_id == item["id"] && used.contains(&m.id))
                    .collect();
                let fields: Vec<_> = SHARE_FIELDS
                    .iter()
                    .filter(|key| item.get(**key).is_some())
                    .collect();
                Ok(json!({"fields":fields,"attachments":files}))
            }
            "share-seal" => {
                let id = string("id")?;
                let fields: Vec<String> = serde_json::from_value(request["fields"].clone())
                    .map_err(|_| VaultError::InvalidData)?;
                let ids: Vec<String> = serde_json::from_value(
                    request.get("attachmentIds").cloned().unwrap_or(json!([])),
                )
                .map_err(|_| VaultError::InvalidData)?;
                if ids.len() > 50 {
                    return Err(VaultError::InvalidData);
                }
                let vault_dir = self.directory.clone();
                let open = self.open()?;
                let mut item = open
                    .document
                    .items
                    .iter()
                    .find(|i| i["id"] == id && i["isDeleted"] != true)
                    .cloned()
                    .ok_or(VaultError::InvalidData)?;
                note_bodies::hydrate_item(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &mut item,
                )?;
                let mut used = std::collections::HashSet::new();
                crate::archive::item_attachment_refs(&item, &mut used)?;
                let metas = notes::metas(&open.connection)?;
                let mut attachments = Vec::new();
                let mut bytes_total = 0;
                for file_id in ids {
                    let meta = metas
                        .iter()
                        .find(|m| m.id == file_id && m.note_id == id && used.contains(&m.id))
                        .ok_or(VaultError::InvalidData)?;
                    bytes_total += meta.size;
                    if bytes_total > 24 * 1024 * 1024 {
                        return Err(VaultError::InvalidData);
                    }
                    let bytes = notes::read(
                        &vault_dir,
                        &open.connection,
                        &open.root,
                        &open.header.vault_id,
                        meta,
                    )?;
                    attachments.push(share_attachment(
                        meta.name.clone(),
                        meta.mime.clone(),
                        &bytes,
                    ));
                }
                seal_share(&item, &fields, &attachments)
            }
            "identity" => self.mutate(|doc| {
                let key = sharing_identity(doc)?;
                Ok(json!({"publicKey":key}))
            }),
            "create-shared" => {
                self.mutate(|doc| create_shared(doc, string("name")?, string("time")?))
            }
            "add-member" => self.mutate(|doc| {
                add_member(
                    doc,
                    string("vaultId")?,
                    string("publicKey")?,
                    request["role"].as_str().unwrap_or("viewer"),
                    request["name"].as_str().unwrap_or(""),
                )
            }),
            "remove-member" => {
                self.mutate(|doc| remove_member(doc, string("vaultId")?, string("publicKey")?))
            }
            "sync-request" => self.mutate_hydrated(|doc| {
                create_sync_request(doc, string("peerKey")?, string("vaultId")?)
            }),
            "sync-respond" => self.mutate_hydrated(|doc| respond_sync(doc, &request["packet"])),
            "sync-apply" => self.mutate_hydrated(|doc| {
                apply_sync(
                    doc,
                    &request["packet"],
                    string("peerKey")?,
                    string("vaultId")?,
                )
            }),
            _ => Err(VaultError::Unsupported),
        }
    }
}
