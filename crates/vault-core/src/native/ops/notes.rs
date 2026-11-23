//! `notes` ops (see `contract/commands.json`): Note attachment bookkeeping and note-body storage status.
//! Routed from `DiskVault::command` after the shared checks (registry, lock, format guards).
use super::super::*;

impl DiskVault {
    pub(in crate::native) fn notes_ops(&mut self, op: &str, request: &Value) -> Result<Value> {
        let string = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        match op {
            "collect-note-attachments" if request["richNotes"] == true => {
                self.collect_note_attachments()
            }
            "note-attachments-status" => {
                let vault_dir = self.directory.clone();
                note_blobs::status(&vault_dir, &self.open()?.connection)
            }
            "note-attachments-list" => {
                let note_id = string("noteId")?;
                notes::list_note_attachments(&self.open()?.connection, note_id)
            }
            "note-attachment-cache-put" => {
                let note_id = string("noteId")?;
                let id = string("id")?;
                let excerpt = request.get("excerpt").filter(|v| !v.is_null());
                let thumb = request.get("thumb").filter(|v| !v.is_null());
                let open = self.open()?;
                notes::put_cache(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    note_id,
                    id,
                    excerpt,
                    thumb,
                )?;
                Ok(json!({"ok":true}))
            }
            "note-attachment-cache-get" => {
                let note_id = string("noteId")?;
                let id = string("id")?;
                let open = self.open()?;
                notes::get_cache(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    note_id,
                    id,
                )
            }
            "note-attachment-state" => {
                let note_id = string("noteId")?;
                let id = string("id")?;
                let state = string("state")?;
                let source_device = request["sourceDevice"].as_str();
                let error_reason = request["errorReason"].as_str();
                let open = self.open()?;
                notes::set_state(
                    &open.connection,
                    note_id,
                    id,
                    state,
                    source_device,
                    error_reason,
                )?;
                Ok(json!({"ok":true}))
            }
            "note-bodies-status" => note_bodies::status(&self.open()?.connection),
            _ => Err(VaultError::Unsupported),
        }
    }
}
