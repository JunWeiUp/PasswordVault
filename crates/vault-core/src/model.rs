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
        if ![2, 3, 4, 5, 6, 7].contains(&result.format_version) || result.items.len() > 100_000 {
            return Err(VaultError::UpdateRequired);
        }
        if result.format_version >= 7 {
            result.settings["devicesEnabled"] = json!(true);
        }
        if result.format_version < 7 && result.items.iter().any(|i| i["type"] == "device") {
            return Err(VaultError::DevicesUpgradeRequired);
        }
        if result.format_version < 3 && result.items.iter().any(|n| n["noteFormat"] == "rich-v1") {
            return Err(VaultError::Unsupported);
        }
        if result.format_version < 6
            && result.items.iter().any(|item| {
                crate::requires_structured_format(item) || item.get("passkeys").is_some()
            })
        {
            return Err(VaultError::Unsupported);
        }
        if result.format_version == 5 {
            result.settings["entryHistoryEnabled"] = json!(true);
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
        if item["type"] == "device" && self.format_version < 7 {
            return Err(VaultError::DevicesUpgradeRequired);
        }
        normalize_item(&mut item)?;
        if crate::requires_structured_format(&item) || item.get("passkeys").is_some() {
            if self.format_version == 5 {
                self.settings["entryHistoryEnabled"] = json!(true);
            }
            self.format_version = self.format_version.max(6);
        }
        if item["noteFormat"] == "rich-v1" {
            if item["noteDocument"]["type"] != "doc" || !item["noteDocument"]["content"].is_array()
            {
                return Err(VaultError::InvalidData);
            }
            self.format_version = self.format_version.max(3);
        }
        if item["type"] == "secureNote" {
            let mut categories = self.note_categories();
            if let Some(name) = item["category"].as_str().filter(|s| !s.is_empty()) {
                let mut prefix = String::new();
                for seg in name.split('/').filter(|s| !s.trim().is_empty()) {
                    if !prefix.is_empty() {
                        prefix.push('/');
                    }
                    prefix.push_str(seg.trim());
                    categories.push(prefix.clone());
                }
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
        if self.format_version < 7 && incoming.format_version >= 7 {
            return Err(VaultError::DevicesUpgradeRequired);
        }
        self.format_version = self.format_version.max(incoming.format_version);
        if self.format_version >= 7 {
            self.settings["devicesEnabled"] = json!(true);
        }
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
        let name = normalize_category_path(name)?;
        let mut categories = self.note_categories();
        if categories
            .iter()
            .any(|value| value.to_lowercase() == name.to_lowercase())
        {
            return Err(VaultError::AlreadyExists);
        }
        // Automatically ensure parent folders exist for hierarchical `/` paths.
        let mut prefix = String::new();
        for seg in name.split('/') {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(seg);
            if !categories
                .iter()
                .any(|value| value.to_lowercase() == prefix.to_lowercase())
            {
                categories.push(prefix.clone());
            }
        }
        self.store_note_categories(categories)?;
        Ok(name)
    }

    /// Removing a category never deletes a note or changes a non-note category.
    /// Include trashed notes so restoring them cannot resurrect a removed category.
    /// Removing a parent folder also removes its nested sub-paths.
    pub fn remove_note_category(&mut self, name: &str, updated_at: &str) -> Result<usize> {
        if name.is_empty()
            || !self.note_categories().iter().any(|value| value == name)
            || chrono::DateTime::parse_from_rfc3339(updated_at).is_err()
        {
            return Err(VaultError::InvalidData);
        }
        for item in self.items.iter().filter(|item| {
            item["type"] == "secureNote"
                && item["category"]
                    .as_str()
                    .is_some_and(|c| category_matches(c, name))
        }) {
            crate::authorize_item_write(self, item)?;
        }
        let categories = self
            .note_categories()
            .into_iter()
            .filter(|value| !category_matches(value, name))
            .collect();
        self.store_note_categories(categories)?;
        let mut count = 0;
        for item in self.items.iter_mut().filter(|item| {
            item["type"] == "secureNote"
                && item["category"]
                    .as_str()
                    .is_some_and(|c| category_matches(c, name))
        }) {
            item["category"] = json!("");
            item["updatedAt"] = json!(updated_at);
            count += 1;
        }
        Ok(count)
    }

    /// Renames a note category: every note in it (and nested sub-paths), including trashed
    /// ones, moves to the new name. Non-note items are untouched; categories stay sorted by name.
    pub fn rename_note_category(
        &mut self,
        from: &str,
        to: &str,
        updated_at: &str,
    ) -> Result<usize> {
        let to = normalize_category_path(to)?;
        if from.is_empty() || chrono::DateTime::parse_from_rfc3339(updated_at).is_err() {
            return Err(VaultError::InvalidData);
        }
        let categories = self.note_categories();
        if !categories.iter().any(|value| value == from) {
            return Err(VaultError::InvalidData);
        }
        // Prevent renaming a folder into one of its own descendants.
        if to != from && category_matches(&to, from) {
            return Err(VaultError::InvalidData);
        }
        // A different category may not take the new name; changing only letter case is allowed.
        if categories
            .iter()
            .any(|value| value != from && value.to_lowercase() == to.to_lowercase())
        {
            return Err(VaultError::AlreadyExists);
        }
        if from == to {
            return Ok(0);
        }
        for item in self.items.iter().filter(|item| {
            item["type"] == "secureNote"
                && item["category"]
                    .as_str()
                    .is_some_and(|c| category_matches(c, from))
        }) {
            crate::authorize_item_write(self, item)?;
        }
        let remap = |value: &str| -> String {
            if value == from {
                to.clone()
            } else if let Some(rest) = value.strip_prefix(&format!("{from}/")) {
                format!("{to}/{rest}")
            } else {
                value.to_owned()
            }
        };
        let mut renamed: Vec<String> = categories.iter().map(|v| remap(v)).collect();
        let mut prefix = String::new();
        for seg in to.split('/') {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(seg);
            if !renamed
                .iter()
                .any(|v| v.to_lowercase() == prefix.to_lowercase())
            {
                renamed.push(prefix.clone());
            }
        }
        self.store_note_categories(renamed)?;
        let mut count = 0;
        for item in self.items.iter_mut().filter(|item| {
            item["type"] == "secureNote"
                && item["category"]
                    .as_str()
                    .is_some_and(|c| category_matches(c, from))
        }) {
            if let Some(cat) = item["category"].as_str() {
                item["category"] = json!(remap(cat));
            }
            item["updatedAt"] = json!(updated_at);
            count += 1;
        }
        Ok(count)
    }
}

pub fn category_matches(category: &str, prefix: &str) -> bool {
    category == prefix
        || category
            .strip_prefix(prefix)
            .is_some_and(|rest| rest.starts_with('/'))
}

fn normalize_category_path(raw: &str) -> Result<String> {
    let trimmed = raw.trim().trim_matches('/');
    if trimmed.is_empty() || trimmed.chars().count() > 80 || trimmed.chars().any(char::is_control) {
        return Err(VaultError::InvalidData);
    }
    let mut segments = Vec::new();
    for seg in trimmed.split('/') {
        let seg = seg.trim();
        if seg.is_empty() || seg == "." || seg == ".." {
            return Err(VaultError::InvalidData);
        }
        segments.push(seg);
    }
    if segments.len() > 6 {
        return Err(VaultError::InvalidData);
    }
    Ok(segments.join("/"))
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
    if ![
        "password",
        "totp",
        "crypto",
        "secureNote",
        "device",
        "creditCard",
        "identity",
    ]
    .contains(&kind)
    {
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
    if obj["noteFormat"] == "rich-v1"
        && obj
            .get("sharedVaultId")
            .and_then(Value::as_str)
            .is_some_and(|s| !s.is_empty())
    {
        return Err(VaultError::Unsupported);
    }
    if obj["noteFormat"]
        .as_str()
        .is_some_and(|s| s.starts_with("rich-") && s != "rich-v1")
    {
        return Err(VaultError::Unsupported);
    }
    obj.entry("username").or_insert(json!(""));
    obj.entry("isDeleted").or_insert(json!(false));
    obj.entry("isFavorite").or_insert(json!(false));
    obj.entry("isPinned").or_insert(json!(false));
    obj.entry("tags").or_insert(json!([]));
    if obj.get("type").and_then(Value::as_str) == Some("secureNote") {
        if let Some(slug) = obj.get("slug").and_then(Value::as_str) {
            let trimmed = slug.trim().trim_matches('/');
            if trimmed.chars().count() > 120 || trimmed.chars().any(char::is_control) {
                return Err(VaultError::InvalidData);
            }
            if trimmed.is_empty() {
                obj.remove("slug");
            } else {
                obj.insert("slug".into(), json!(trimmed));
            }
        } else if obj.get("slug").is_some_and(|v| !v.is_null()) {
            return Err(VaultError::InvalidData);
        }
        if let Some(props) = obj.get("noteProperties") {
            if !props.is_null() {
                let arr = props
                    .as_array()
                    .filter(|a| a.len() <= 64)
                    .ok_or(VaultError::InvalidData)?;
                for row in arr {
                    let k = row
                        .get("key")
                        .and_then(Value::as_str)
                        .ok_or(VaultError::InvalidData)?;
                    let v = row
                        .get("value")
                        .and_then(Value::as_str)
                        .ok_or(VaultError::InvalidData)?;
                    if k.chars().count() > 80
                        || v.chars().count() > 500
                        || k.chars().any(char::is_control)
                    {
                        return Err(VaultError::InvalidData);
                    }
                }
            }
        }
        for (field, max) in [("lastActor", 120usize), ("lastSummary", 240usize)] {
            if let Some(v) = obj.get(field) {
                if !v.is_null() {
                    let s = v.as_str().ok_or(VaultError::InvalidData)?;
                    if s.chars().count() > max {
                        return Err(VaultError::InvalidData);
                    }
                }
            }
        }
    }
    if let Some(meta) = obj.get("uiMeta") {
        if meta.is_null() {
            obj.remove("uiMeta");
        } else {
            validate_passthrough_object(meta, UI_META_LIMIT, 6)?;
        }
    }
    crate::validate_device(item)?;
    crate::validate_structured_item(item)?;
    if let Some(passkeys) = item.get("passkeys") {
        let records = passkeys
            .as_array()
            .filter(|records| records.len() <= 64)
            .ok_or(VaultError::InvalidData)?;
        for record in records {
            let _: crate::PasskeyRecord =
                serde_json::from_value(record.clone()).map_err(|_| VaultError::InvalidData)?;
        }
    }
    Ok(())
}

const UI_META_LIMIT: usize = 16 * 1024;
const UI_PREFS_LIMIT: usize = 64 * 1024;

/// Validates a bounded generic pass-through JSON object (arbitrary keys/values owned by
/// client TS/UI layers so new UI metadata never requires Rust schema whitelist changes).
fn validate_passthrough_object(value: &Value, max_bytes: usize, max_depth: usize) -> Result<()> {
    if !value.is_object() {
        return Err(VaultError::InvalidData);
    }
    fn check_depth(v: &Value, depth: usize, max_depth: usize) -> bool {
        if depth > max_depth {
            return false;
        }
        match v {
            Value::Object(map) => {
                map.len() <= 256 && map.values().all(|c| check_depth(c, depth + 1, max_depth))
            }
            Value::Array(arr) => {
                arr.len() <= 256 && arr.iter().all(|c| check_depth(c, depth + 1, max_depth))
            }
            _ => true,
        }
    }
    if !check_depth(value, 1, max_depth) {
        return Err(VaultError::InvalidData);
    }
    let bytes = serde_json::to_vec(value).map_err(|_| VaultError::InvalidData)?;
    if bytes.len() > max_bytes {
        return Err(VaultError::InvalidData);
    }
    Ok(())
}

pub fn update_settings(doc: &mut Document, settings: &Value) -> Result<()> {
    let input = settings.as_object().ok_or(VaultError::InvalidData)?;
    if let Some(minutes) = input.get("autoLockMinutes") {
        if !minutes.as_u64().is_some_and(|v| (1..=120).contains(&v)) {
            return Err(VaultError::InvalidData);
        }
    }
    if let Some(ui_prefs) = input.get("uiPrefs") {
        if !ui_prefs.is_null() {
            validate_passthrough_object(ui_prefs, UI_PREFS_LIMIT, 6)?;
        }
    }
    for (key, value) in input {
        // Core-owned identity and replay state must not be overwritten by stale UI snapshots.
        // The peer-library keys are retired; stale clients or backups still cannot set them.
        if [
            "sharingIdentity",
            "syncSeen",
            "syncPending",
            "noteCategories",
            "entryHistoryEnabled",
            "devicesEnabled",
            "activePeerLibrary",
            "peerLibrarySnapshots",
            "_peerLibraryRole",
            "_peerLibraryReadOnly",
            "_peerLibraryName",
        ]
        .contains(&key.as_str())
        {
            continue;
        }
        doc.settings[key] = value.clone();
    }
    Ok(())
}
