//! `categories` ops (see `contract/commands.json`): Note categories.
//! Routed from `DiskVault::command` after the shared checks (registry, lock, format guards).
use super::super::*;

impl DiskVault {
    pub(in crate::native) fn categories_ops(&mut self, op: &str, request: &Value) -> Result<Value> {
        let string = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        match op {
            "category-add" => {
                self.mutate(|doc| Ok(json!({"name":doc.add_note_category(string("name")?)?})))
            }
            "category-remove" => self.mutate(|doc| {
                Ok(json!({"updated":doc.remove_note_category(string("name")?,string("time")?)?}))
            }),
            "category-rename" => self.mutate(|doc| {
                Ok(json!({"updated":doc.rename_note_category(string("name")?,string("to")?,string("time")?)?}))
            }),
            _ => Err(VaultError::Unsupported),
        }
    }
}
