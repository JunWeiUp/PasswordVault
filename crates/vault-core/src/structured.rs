//! Versioned structured records. Values remain inside the encrypted document.
use crate::{Result, VaultError};
use serde_json::Value;
use std::collections::HashSet;

pub const STRUCTURED_FORMAT: u32 = 6;
pub const CARD_FIELDS: &[&str] = &[
    "cardholder",
    "number",
    "expiryMonth",
    "expiryYear",
    "securityCode",
    "brand",
];
pub const IDENTITY_FIELDS: &[&str] = &[
    "firstName",
    "lastName",
    "email",
    "phone",
    "address1",
    "address2",
    "city",
    "region",
    "postalCode",
    "country",
    "company",
];

pub fn requires_structured_format(item: &Value) -> bool {
    matches!(item["type"].as_str(), Some("creditCard" | "identity"))
        || item.get("customFields").is_some()
        || item.get("importSource").is_some()
}

pub fn validate_structured_item(item: &Value) -> Result<()> {
    for (kind, key, fields) in [
        ("creditCard", "card", CARD_FIELDS),
        ("identity", "identity", IDENTITY_FIELDS),
    ] {
        if item["type"] == kind {
            let object = item[key].as_object().ok_or(VaultError::InvalidData)?;
            if object.len() > 64
                || object.iter().any(|(key, value)| {
                    !fields.contains(&key.as_str()) || value.as_str().is_none_or(|s| s.len() > 8192)
                })
            {
                return Err(VaultError::InvalidData);
            }
        }
    }
    if let Some(fields) = item.get("customFields") {
        let fields = fields
            .as_array()
            .filter(|v| v.len() <= 256)
            .ok_or(VaultError::InvalidData)?;
        let mut ids = HashSet::new();
        for field in fields {
            let id = field["id"]
                .as_str()
                .filter(|v| !v.is_empty() && v.len() <= 256)
                .ok_or(VaultError::InvalidData)?;
            if field
                .get("group")
                .is_some_and(|v| v.as_str().is_none_or(|s| s.len() > 512))
                || !ids.insert(id)
                || field["label"].as_str().is_none_or(|s| s.len() > 512)
                || field["value"].as_str().is_none_or(|s| s.len() > 65536)
                || !matches!(
                    field["kind"].as_str(),
                    Some("text" | "concealed" | "url" | "email" | "date")
                )
            {
                return Err(VaultError::InvalidData);
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn structured_records_reject_wrong_shapes_and_duplicate_ids() {
        assert!(validate_structured_item(
            &json!({"type":"creditCard","card":{"number":"4111111111111111"}})
        )
        .is_ok());
        assert!(
            validate_structured_item(&json!({"type":"creditCard","card":{"number":4111}})).is_err()
        );
        let field = json!({"id":"a","label":"PIN","value":"1234","kind":"concealed"});
        assert!(validate_structured_item(&json!({"customFields":[field,field]})).is_err());
        assert!(requires_structured_format(&json!({"type":"identity"})));
    }
}
