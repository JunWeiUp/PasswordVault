use crate::{Result, VaultError, MAX_INPUT};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Document {
    #[serde(default = "format_version")]
    pub format_version: u32,
    #[serde(default)]
    pub items: Vec<Value>,
    #[serde(default)]
    pub shared_vaults: Vec<Value>,
    #[serde(default)]
    pub shared_members: Vec<Value>,
    #[serde(default = "default_settings")]
    pub settings: Value,
}

fn format_version() -> u32 {
    2
}
fn default_settings() -> Value {
    json!({"autoLockMinutes":60,"language":"zh","theme":"system"})
}

impl Default for Document {
    fn default() -> Self {
        Self {
            format_version: 2,
            items: vec![],
            shared_vaults: vec![],
            shared_members: vec![],
            settings: default_settings(),
        }
    }
}

impl Document {
    pub fn parse(input: &[u8]) -> Result<Self> {
        if input.len() > MAX_INPUT {
            return Err(VaultError::InvalidData);
        }
        let value: Value = serde_json::from_slice(input).map_err(|_| VaultError::InvalidData)?;
        let mut result: Self = if value.is_array() {
            Self {
                items: value.as_array().unwrap().clone(),
                ..Self::default()
            }
        } else {
            if !value.get("items").is_some_and(Value::is_array) {
                return Err(VaultError::InvalidData);
            }
            serde_json::from_value(value).map_err(|_| VaultError::InvalidData)?
        };
        if result.format_version != 2 || result.items.len() > 100_000 {
            return Err(VaultError::Unsupported);
        }
        let mut ids = HashSet::new();
        for item in &mut result.items {
            normalize_item(item)?;
            if !ids.insert(item["id"].as_str().unwrap().to_owned()) {
                return Err(VaultError::InvalidData);
            }
        }
        Ok(result)
    }
    pub fn upsert(&mut self, mut item: Value) -> Result<()> {
        normalize_item(&mut item)?;
        if item["type"] == "secureNote" {
            let mut categories = self.note_categories();
            if let Some(name) = item["category"].as_str().filter(|s| !s.is_empty()) {
                categories.push(name.to_owned());
            }
            self.store_note_categories(categories)?;
        }
        if let Some(old) = self.items.iter_mut().find(|old| old["id"] == item["id"]) {
            *old = item;
        } else {
            self.items.push(item);
        }
        Ok(())
    }
    pub fn merge(&mut self, incoming: Document) -> Result<usize> {
        // A restore must preserve the identity that can unwrap shared-vault keys.
        // Never silently combine two unrelated identities into unusable shared metadata.
        if let Some(identity) = incoming.settings.get("sharingIdentity") {
            let existing = self.settings.get("sharingIdentity");
            if existing.is_some_and(|value| value["publicKey"] != identity["publicKey"])
                && !incoming.shared_vaults.is_empty()
            {
                return Err(VaultError::Authentication);
            }
            if existing.is_none() {
                self.settings["sharingIdentity"] = identity.clone();
            }
        }
        let mut categories = self.note_categories();
        categories.extend(incoming.note_categories());
        self.store_note_categories(categories)?;
        let mut count = 0;
        for item in incoming.items {
            let should_write = match self.items.iter().find(|v| v["id"] == item["id"]) {
                Some(old) => timestamp(&item) > timestamp(old),
                None => true,
            };
            if should_write {
                self.upsert(item)?;
                count += 1;
            }
        }
        merge_named(&mut self.shared_vaults, incoming.shared_vaults);
        merge_named(&mut self.shared_members, incoming.shared_members);
        Ok(count)
    }

    /// Include legacy item categories; explicit empty categories live in encrypted settings.
    pub fn note_categories(&self) -> Vec<String> {
        let mut categories: Vec<String> = self.settings["noteCategories"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect();
        categories.extend(
            self.items
                .iter()
                .filter(|item| item["type"] == "secureNote" && item["isDeleted"] != true)
                .filter_map(|item| item["category"].as_str())
                .filter(|s| !s.is_empty())
                .map(str::to_owned),
        );
        categories.sort();
        categories.dedup();
        categories
    }

    fn store_note_categories(&mut self, mut categories: Vec<String>) -> Result<()> {
        if !self.settings.is_object() {
            return Err(VaultError::InvalidData);
        }
        categories.sort();
        categories.dedup();
        self.settings["noteCategories"] = json!(categories);
        Ok(())
    }

    pub fn add_note_category(&mut self, name: &str) -> Result<String> {
        let name = name.trim();
        if name.is_empty() || name.chars().count() > 80 || name.chars().any(char::is_control) {
            return Err(VaultError::InvalidData);
        }
        let mut categories = self.note_categories();
        if categories
            .iter()
            .any(|value| value.to_lowercase() == name.to_lowercase())
        {
            return Err(VaultError::AlreadyExists);
        }
        categories.push(name.to_owned());
        self.store_note_categories(categories)?;
        Ok(name.to_owned())
    }

    /// Removing a category never deletes a note or changes a non-note category.
    /// Include trashed notes so restoring them cannot resurrect a removed category.
    pub fn remove_note_category(&mut self, name: &str, updated_at: &str) -> Result<usize> {
        if name.is_empty()
            || !self.note_categories().iter().any(|value| value == name)
            || chrono::DateTime::parse_from_rfc3339(updated_at).is_err()
        {
            return Err(VaultError::InvalidData);
        }
        for item in self
            .items
            .iter()
            .filter(|item| item["type"] == "secureNote" && item["category"] == name)
        {
            crate::authorize_item_write(self, item)?;
        }
        let categories = self
            .note_categories()
            .into_iter()
            .filter(|value| value != name)
            .collect();
        self.store_note_categories(categories)?;
        let mut count = 0;
        for item in self
            .items
            .iter_mut()
            .filter(|item| item["type"] == "secureNote" && item["category"] == name)
        {
            item["category"] = json!("");
            item["updatedAt"] = json!(updated_at);
            count += 1;
        }
        Ok(count)
    }
}

fn merge_named(dest: &mut Vec<Value>, source: Vec<Value>) {
    for item in source {
        if item.get("id").and_then(Value::as_str).is_none() {
            continue;
        }
        if !dest.iter().any(|old| old["id"] == item["id"]) {
            dest.push(item);
        }
    }
}

pub fn timestamp(item: &Value) -> i64 {
    let Some(value) = item.get("updatedAt").and_then(Value::as_str) else {
        return 0;
    };
    if let Ok(date) = chrono::DateTime::parse_from_rfc3339(value) {
        return date.timestamp_millis();
    }
    chrono::NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M:%S%.f")
        .map(|d| d.and_utc().timestamp_millis())
        .unwrap_or(0)
}

pub fn normalize_item(item: &mut Value) -> Result<()> {
    let obj = item.as_object_mut().ok_or(VaultError::InvalidData)?;
    let id = obj
        .get("id")
        .and_then(Value::as_str)
        .ok_or(VaultError::InvalidData)?;
    if id.is_empty() || id.len() > 256 {
        return Err(VaultError::InvalidData);
    }
    let kind = obj
        .get("type")
        .and_then(Value::as_str)
        .ok_or(VaultError::InvalidData)?;
    if !["password", "totp", "crypto", "secureNote"].contains(&kind) {
        return Err(VaultError::Unsupported);
    }
    if !obj.get("title").is_some_and(Value::is_string) {
        return Err(VaultError::InvalidData);
    }
    if kind == "totp" {
        let period = obj.get("period").and_then(Value::as_u64).unwrap_or(30);
        if period == 0 || period > 86400 {
            return Err(VaultError::InvalidData);
        }
    }
    obj.entry("noteFormat").or_insert(json!("plain"));
    obj.entry("username").or_insert(json!(""));
    obj.entry("isDeleted").or_insert(json!(false));
    obj.entry("isFavorite").or_insert(json!(false));
    obj.entry("isPinned").or_insert(json!(false));
    obj.entry("tags").or_insert(json!([]));
    Ok(())
}

pub fn update_settings(doc: &mut Document, settings: &Value) -> Result<()> {
    let input = settings.as_object().ok_or(VaultError::InvalidData)?;
    if let Some(minutes) = input.get("autoLockMinutes") {
        if !minutes.as_u64().is_some_and(|v| (1..=120).contains(&v)) {
            return Err(VaultError::InvalidData);
        }
    }
    for (key, value) in input {
        // Core-owned identity and replay state must not be overwritten by stale UI snapshots.
        if [
            "sharingIdentity",
            "syncSeen",
            "syncPending",
            "noteCategories",
        ]
        .contains(&key.as_str())
        {
            continue;
        }
        doc.settings[key] = value.clone();
    }
    Ok(())
}
