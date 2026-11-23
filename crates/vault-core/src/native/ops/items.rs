//! `items` ops (see `contract/commands.json`): Item reads and writes, plus encrypted draft sealing/restoring.
//! Routed from `DiskVault::command` after the shared checks (registry, lock, format guards).
use super::super::*;

impl DiskVault {
    pub(in crate::native) fn items_ops(&mut self, op: &str, request: &Value) -> Result<Value> {
        let string = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        match op {
            "list" => {
                let open = self.open()?;
                // Summaries stay zero-hydration: split notes are served directly from L1 metadata
                // in `vault_state` without decrypting `note_bodies`.
                if request["summaries"] == true {
                    let summary = summary_document(&open.document);
                    Ok(json!(relay::peer::editable_document(
                        &open.connection,
                        &open.root,
                        &open.header.vault_id,
                        &summary
                    )?))
                } else {
                    let hydrated = note_bodies::hydrate(
                        &open.connection,
                        &open.root,
                        &open.header.vault_id,
                        open.document.clone(),
                    )?;
                    Ok(json!(relay::peer::editable_document(
                        &open.connection,
                        &open.root,
                        &open.header.vault_id,
                        &hydrated
                    )?))
                }
            }
            "get" => {
                let open = self.open()?;
                let id = string("id")?;
                let mut item = if let Some(cached) = open.get_hydrated(id) {
                    cached
                } else {
                    let mut found = open
                        .document
                        .items
                        .iter()
                        .find(|item| item["id"] == id)
                        .cloned()
                        .ok_or(VaultError::InvalidData)?;
                    if note_bodies::hydrate_item(
                        &open.connection,
                        &open.root,
                        &open.header.vault_id,
                        &mut found,
                    )? {
                        open.put_hydrated(id.to_owned(), found.clone());
                    }
                    found
                };
                item = relay::peer::editable_item(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &open.document,
                    item,
                )?;
                Ok(item)
            }
            "save" => {
                // A summary lacks note structures; writing it back would drop them.
                if request["item"]["noteSummary"] == true {
                    return Err(VaultError::InvalidData);
                }
                let open = self.open()?;
                let mut item = relay::peer::prepare_save(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &open.document,
                    &request["item"],
                )?;
                note_bodies::strip_internal_markers(&mut item);
                preserve_passkeys_for_edit(&open.document, &mut item)?;
                let item_id = item["id"]
                    .as_str()
                    .ok_or(VaultError::InvalidData)?
                    .to_owned();
                // Optimistic concurrency guard: if caller supplies `expectedUpdatedAt`, refuse
                // silently clobbering concurrent AI / sync writes.
                if let Some(expected_at) = request["expectedUpdatedAt"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                {
                    if let Some(existing) = open.document.items.iter().find(|v| v["id"] == item_id)
                    {
                        let actual_at = existing["updatedAt"].as_str().unwrap_or("");
                        if !actual_at.is_empty() && actual_at != expected_at {
                            return Err(VaultError::StaleEdit);
                        }
                    }
                }
                let mut cleaned = request.clone();
                cleaned["item"] = item.clone();
                self.validate_note_save(&cleaned)?;
                let history_meta =
                    history::HistoryMeta::parse(&request["historyMeta"], Some(&item_id))?;
                // AI writes and explicit milestones auto-enable history so every update is reversible.
                if history_meta
                    .as_ref()
                    .is_some_and(|m| m.actor_type.as_deref() == Some("ai") || m.milestone)
                {
                    self.ensure_history_enabled()?;
                }
                self.mutate_with_history(history_meta.as_ref(), |doc| {
                    authorize_item_write(doc, &item)?;
                    if let Some(old) = doc.items.iter().find(|v| v["id"] == item["id"]) {
                        authorize_item_write(doc, old)?;
                    }
                    doc.upsert(item.clone())?;
                    Ok(json!({"ok":true}))
                })?;
                let open = self.open()?;
                open.invalidate_hydrated(&item_id);
                relay::peer::save_result(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &open.document,
                    &item_id,
                )
            }
            "remove" => self.remove_note_record(string("id")?),
            "seal-drafts" => {
                let open = self.open()?;
                let bytes = Zeroizing::new(
                    serde_json::to_vec(&request["items"]).map_err(|_| VaultError::InvalidData)?,
                );
                Ok(
                    json!({"payload":seal(&subkey(&open.root,b"draft-recovery"),&bytes,open.header.vault_id.as_bytes())?}),
                )
            }
            "open-drafts" => {
                let open = self.open()?;
                let sealed: Sealed = serde_json::from_value(request["payload"].clone())
                    .map_err(|_| VaultError::InvalidData)?;
                let bytes = unseal(
                    &subkey(&open.root, b"draft-recovery"),
                    &sealed,
                    open.header.vault_id.as_bytes(),
                )?;
                let items: Vec<Value> =
                    serde_json::from_slice(&bytes).map_err(|_| VaultError::InvalidData)?;
                Ok(json!({"items": items}))
            }
            "restore-drafts" => {
                let open = self.open()?;
                let sealed: Sealed = serde_json::from_value(request["payload"].clone())
                    .map_err(|_| VaultError::InvalidData)?;
                let bytes = unseal(
                    &subkey(&open.root, b"draft-recovery"),
                    &sealed,
                    open.header.vault_id.as_bytes(),
                )?;
                let items: Vec<Value> =
                    serde_json::from_slice(&bytes).map_err(|_| VaultError::InvalidData)?;
                let items = items
                    .iter()
                    .map(|item| {
                        relay::peer::prepare_save(
                            &open.connection,
                            &open.root,
                            &open.header.vault_id,
                            &open.document,
                            item,
                        )
                    })
                    .collect::<Result<Vec<_>>>()?;
                for item in &items {
                    self.validate_note_save(
                        &json!({"item":item,"richNotes":request["richNotes"]}),
                    )?;
                }
                self.mutate(|doc| {
                    for mut item in items {
                        note_bodies::strip_internal_markers(&mut item);
                        preserve_passkeys_for_edit(doc, &mut item)?;
                        authorize_item_write(doc, &item)?;
                        doc.upsert(item)?;
                    }
                    Ok(json!({"ok":true}))
                })
            }
            _ => Err(VaultError::Unsupported),
        }
    }
}
