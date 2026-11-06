//! Stateless import preview. Commit regenerates the preview from source and applies to a clone.
//! Source material is deliberately retained in encrypted records, never in logs.
use crate::{Document, Result, VaultError};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashSet},
    io::{Cursor, Read},
};

const LIMIT: usize = 64 * 1024 * 1024;
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportRow {
    pub index: usize,
    pub item: Value,
    pub duplicate_ids: Vec<String>,
    pub warnings: Vec<String>,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportPreview {
    pub rows: Vec<ImportRow>,
    pub failures: Vec<Value>,
    pub columns: Vec<String>,
}

/// Mapping keys are destination fields (title, username, password, url, notes), values CSV headers.
pub fn preview_import(
    format: &str,
    bytes: &[u8],
    mapping: &BTreeMap<String, String>,
    doc: &Document,
) -> Result<ImportPreview> {
    if bytes.len() > LIMIT {
        return Err(VaultError::InvalidData);
    }
    let mut preview = ImportPreview {
        rows: vec![],
        failures: vec![],
        columns: vec![],
    };
    match format {
        "csv" => csv_rows(bytes, mapping, &mut preview)?,
        "1pux" => one_password_rows(bytes, &mut preview)?,
        _ => return Err(VaultError::Unsupported),
    }
    if preview.rows.len() > 100_000 {
        return Err(VaultError::InvalidData);
    }
    let mut titles: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut credentials: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for old in doc.items.iter().filter(|v| v["isDeleted"] != true) {
        remember_duplicate(
            &mut titles,
            old["title"].to_string(),
            old["id"].as_str().unwrap_or("").to_owned(),
        );
        if let Some(key) = credential_key(old) {
            remember_duplicate(
                &mut credentials,
                key,
                old["id"].as_str().unwrap_or("").to_owned(),
            );
        }
    }
    for row in &mut preview.rows {
        let title = row.item["title"].to_string();
        row.duplicate_ids = titles.get(&title).cloned().unwrap_or_default();
        if let Some(key) = credential_key(&row.item) {
            row.duplicate_ids
                .extend(credentials.get(&key).cloned().unwrap_or_default());
            remember_duplicate(&mut credentials, key, format!("import-row:{}", row.index));
        }
        row.duplicate_ids.sort();
        row.duplicate_ids.dedup();
        remember_duplicate(&mut titles, title, format!("import-row:{}", row.index));
    }
    Ok(preview)
}
fn remember_duplicate(index: &mut BTreeMap<String, Vec<String>>, key: String, id: String) {
    let ids = index.entry(key).or_default();
    if ids.len() < 16 {
        ids.push(id);
    }
}
fn credential_key(item: &Value) -> Option<String> {
    if item["type"] != "password" {
        return None;
    }
    Some(json!([item["username"], item["url"], item["password"]]).to_string())
}
fn csv_rows(
    bytes: &[u8],
    mapping: &BTreeMap<String, String>,
    out: &mut ImportPreview,
) -> Result<()> {
    let bytes = bytes.strip_prefix(&[239, 187, 191]).unwrap_or(bytes);
    let mut reader = csv::ReaderBuilder::new().flexible(false).from_reader(bytes);
    let headers = reader
        .headers()
        .map_err(|_| VaultError::InvalidData)?
        .clone();
    out.columns = headers.iter().map(str::to_owned).collect();
    if headers.is_empty()
        || headers.len() > 256
        || headers.iter().collect::<HashSet<_>>().len() != headers.len()
    {
        return Err(VaultError::InvalidData);
    }
    let aliases: [(&str, &[&str]); 5] = [
        ("title", &["name", "title"]),
        ("username", &["username", "login_username", "login"]),
        ("password", &["password", "login_password"]),
        ("url", &["url", "origin", "website", "login_uri"]),
        ("notes", &["note", "notes", "extra"]),
    ];
    let mut selected = BTreeMap::new();
    for (target, aliases) in aliases {
        let index = if let Some(name) = mapping.get(target) {
            Some(
                headers
                    .iter()
                    .position(|h| h == name)
                    .ok_or(VaultError::InvalidData)?,
            )
        } else {
            headers
                .iter()
                .position(|h| aliases.contains(&h.to_lowercase().as_str()))
        };
        if let Some(index) = index {
            selected.insert(target, index);
        }
    }
    if mapping
        .keys()
        .any(|k| !aliases.iter().any(|(target, _)| target == k))
        || selected.is_empty()
    {
        return Err(VaultError::InvalidData);
    }
    for (index, record) in reader.records().enumerate() {
        let record = match record {
            Ok(v) => v,
            Err(_) => {
                out.failures.push(
                    json!({"row":index+1,"reason":"Malformed CSV row; original file retained"}),
                );
                continue;
            }
        };
        let mut item = json!({"id":crate::new_id(),"type":"password","title":"","username":"","password":"","url":"","note":""});
        for (target, column) in &selected {
            item[if *target == "notes" { "note" } else { *target }] =
                json!(record.get(*column).unwrap_or(""));
        }
        if item["title"] == "" {
            item["title"] = item["url"].clone();
        }
        if item["title"] == "" {
            item["title"] = json!(format!("Imported account {}", index + 1));
        }
        let unknown: BTreeMap<_, _> = headers
            .iter()
            .enumerate()
            .filter(|(i, _)| !selected.values().any(|v| v == i))
            .map(|(i, h)| (h, record.get(i).unwrap_or("")))
            .collect();
        let warnings = if unknown.is_empty() {
            vec![]
        } else {
            vec!["Unmapped columns retained in encrypted importSource".into()]
        };
        item["importSource"] = json!({"format":"csv","unmapped":unknown});
        out.rows.push(ImportRow {
            index,
            item,
            duplicate_ids: vec![],
            warnings,
        });
    }
    Ok(())
}
fn one_password_rows(bytes: &[u8], out: &mut ImportPreview) -> Result<()> {
    let mut archive =
        zip::ZipArchive::new(Cursor::new(bytes)).map_err(|_| VaultError::InvalidData)?;
    if archive.len() > 100_000 {
        return Err(VaultError::InvalidData);
    }
    let mut files = BTreeMap::new();
    let mut total = 0usize;
    for index in 0..archive.len() {
        let mut file = archive
            .by_index(index)
            .map_err(|_| VaultError::InvalidData)?;
        if file.is_dir() {
            continue;
        }
        if file.enclosed_name().is_none() || file.size() > LIMIT as u64 {
            return Err(VaultError::InvalidData);
        }
        let name = file.name().to_owned();
        let mut data = Vec::new();
        Read::by_ref(&mut file)
            .take((LIMIT + 1) as u64)
            .read_to_end(&mut data)
            .map_err(|_| VaultError::InvalidData)?;
        total = total
            .checked_add(data.len())
            .ok_or(VaultError::InvalidData)?;
        if total > LIMIT || files.insert(name, data).is_some() {
            return Err(VaultError::InvalidData);
        }
    }
    let attributes: Value = serde_json::from_slice(
        files
            .get("export.attributes")
            .ok_or(VaultError::InvalidData)?,
    )
    .map_err(|_| VaultError::InvalidData)?;
    if attributes["version"] != 3 {
        return Err(VaultError::Unsupported);
    }
    let data = files.get("export.data").ok_or(VaultError::InvalidData)?;
    let export: Value = serde_json::from_slice(data).map_err(|_| VaultError::InvalidData)?;
    let accounts = export["accounts"]
        .as_array()
        .ok_or(VaultError::InvalidData)?;
    for account in accounts {
        let vaults = account["vaults"]
            .as_array()
            .ok_or(VaultError::InvalidData)?;
        for vault in vaults {
            for source in vault["items"].as_array().ok_or(VaultError::InvalidData)? {
                let index = out.rows.len() + out.failures.len();
                let details = &source["details"];
                let category = source["categoryUuid"].as_str().unwrap_or("");
                let kind = match category {
                    "001" => "password",
                    "002" => "creditCard",
                    "003" => "secureNote",
                    "004" => "identity",
                    _ => "secureNote",
                };
                let mut item = json!({"id":crate::new_id(),"type":kind,"title":source["overview"]["title"].as_str().unwrap_or("Imported item"),"note":details["notesPlain"].as_str().unwrap_or(""),"tags":source["overview"]["tags"].as_array().cloned().unwrap_or_default(),"username":"","password":"","url":source["overview"]["url"].as_str().unwrap_or(""),"customFields":[],"card":{},"identity":{}});
                let mut warnings = vec![];
                if source.to_string().contains("passkey")
                    || source.to_string().contains("credentialId")
                {
                    warnings.push("Passkey material is retained only in encrypted original fields; it is not imported as a usable Passkey".into());
                }
                if !["001", "002", "003", "004"].contains(&category) {
                    warnings.push("Unsupported category retained as a secure note with complete original fields".into());
                }
                for field in details["loginFields"].as_array().into_iter().flatten() {
                    let target = match field["designation"].as_str() {
                        Some("username") => Some("username"),
                        Some("password") => Some("password"),
                        _ => None,
                    };
                    if let Some(target) = target {
                        item[target] = field["value"].clone();
                    }
                }
                for section in details["sections"].as_array().into_iter().flatten() {
                    for field in section["fields"].as_array().into_iter().flatten() {
                        let id = field["id"].as_str().unwrap_or("");
                        let val = &field["value"];
                        let value = val
                            .as_object()
                            .and_then(|o| o.values().find_map(Value::as_str))
                            .unwrap_or("");
                        let target = match (kind, id) {
                            ("creditCard", "ccnum") => Some(("card", "number")),
                            ("creditCard", "cvv") => Some(("card", "securityCode")),
                            ("creditCard", "cardholder") => Some(("card", "cardholder")),
                            ("creditCard", "type") => Some(("card", "brand")),
                            ("identity", "firstname") => Some(("identity", "firstName")),
                            ("identity", "lastname") => Some(("identity", "lastName")),
                            ("identity", "email") => Some(("identity", "email")),
                            ("identity", "phone") => Some(("identity", "phone")),
                            ("identity", "company") => Some(("identity", "company")),
                            _ => None,
                        };
                        if let Some((group, key)) = target {
                            item[group][key] = json!(value);
                        }
                        if kind == "creditCard" && id == "expiry" {
                            let raw = val["monthYear"]
                                .as_u64()
                                .or_else(|| val["monthYear"].as_str().and_then(|v| v.parse().ok()));
                            if let Some(raw) = raw.filter(|v| (1..=12).contains(&(v % 100))) {
                                item["card"]["expiryYear"] = json!((raw / 100).to_string());
                                item["card"]["expiryMonth"] = json!(format!("{:02}", raw % 100));
                            }
                        }
                        if kind == "identity" {
                            if let Some(address) = val["address"].as_object() {
                                for (from, to) in [
                                    ("street", "address1"),
                                    ("city", "city"),
                                    ("state", "region"),
                                    ("zip", "postalCode"),
                                    ("country", "country"),
                                ] {
                                    if let Some(value) = address.get(from).and_then(Value::as_str) {
                                        item["identity"][to] = json!(value);
                                    }
                                }
                            }
                        }
                        let label = field["title"].as_str().unwrap_or(id);
                        item["customFields"].as_array_mut().unwrap().push(json!({"id":crate::new_id(),"label":label,"group":section["title"].as_str().unwrap_or(""),"value":if value.is_empty(){val.to_string()}else{value.to_owned()},"kind":"concealed"}));
                    }
                }
                let mut attachments = vec![];
                let documents: Vec<&Value> = details["documents"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .chain(details.get("documentAttributes"))
                    .collect();
                for document in documents {
                    let name = document["documentId"].as_str().unwrap_or("");
                    let filename = document["fileName"].as_str().unwrap_or(name);
                    let prefix = format!("files/{name}___");
                    let candidates: Vec<_> = files
                        .iter()
                        .filter(|(path, _)| {
                            *path == &format!("files/{name}") || path.starts_with(&prefix)
                        })
                        .collect();
                    let data = if candidates.len() == 1 {
                        Some(candidates[0].1)
                    } else {
                        None
                    };
                    if let Some(data) = data {
                        attachments.push(json!({"name":filename,"data":STANDARD.encode(data)}));
                    } else {
                        warnings.push(format!("Attachment unavailable: {filename}"));
                    }
                }
                if !attachments.is_empty() {
                    warnings
                        .push("Original attachments preserved in encrypted importSource".into());
                }
                item["importSource"] =
                    json!({"format":"1pux","original":source,"attachments":attachments});
                match crate::structured::validate_structured_item(&item) {
                    Ok(())=>out.rows.push(ImportRow{index,item,duplicate_ids:vec![],warnings}),
                    Err(_)=>out.failures.push(json!({"row":index,"reason":"Item exceeds supported field limits; original file retained"})),
                }
            }
        }
    }
    Ok(())
}

/// Choices map preview indices to "skip" or "add". Duplicates default to skip; never overwrite.
/// Call with a freshly generated preview to avoid trusting client-edited preview items.
pub fn apply_import(
    doc: &mut Document,
    preview: ImportPreview,
    choices: &BTreeMap<usize, String>,
) -> Result<Value> {
    if choices.values().any(|v| v != "skip" && v != "add")
        || choices
            .keys()
            .any(|i| !preview.rows.iter().any(|r| r.index == *i))
    {
        return Err(VaultError::InvalidData);
    }
    let mut next = doc.clone();
    let mut added = 0;
    let mut skipped = 0;
    for row in preview.rows {
        let add = choices
            .get(&row.index)
            .map(|v| v == "add")
            .unwrap_or(row.duplicate_ids.is_empty());
        if !add {
            skipped += 1;
            continue;
        }
        crate::structured::validate_structured_item(&row.item)?;
        next.upsert(row.item)?;
        added += 1;
    }
    if added > 0 {
        next.format_version = next
            .format_version
            .max(crate::structured::STRUCTURED_FORMAT);
    }
    if serde_json::to_vec(&next)
        .map_err(|_| VaultError::InvalidData)?
        .len()
        > crate::MAX_INPUT
    {
        return Err(VaultError::InvalidData);
    }
    *doc = next;
    Ok(json!({"added":added,"skipped":skipped,"failures":preview.failures}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn csv_preview_preserves_multiline_unknown_and_skips_duplicates() {
        let mut doc = Document::default();
        let bytes=b"name,url,username,password,extra-field\r\nExample,https://example.com,a,p,\"line1\nline2\"\r\n";
        let preview = preview_import("csv", bytes, &BTreeMap::new(), &doc).unwrap();
        assert_eq!(
            preview.rows[0].item["importSource"]["unmapped"]["extra-field"],
            "line1\nline2"
        );
        assert_eq!(
            apply_import(&mut doc, preview, &BTreeMap::new()).unwrap()["added"],
            1
        );
        let preview = preview_import("csv", bytes, &BTreeMap::new(), &doc).unwrap();
        assert_eq!(
            apply_import(&mut doc, preview, &BTreeMap::new()).unwrap()["skipped"],
            1
        );
        assert_eq!(doc.items.len(), 1);
    }
    #[test]
    fn invalid_choices_leave_document_unchanged() {
        let mut doc = Document::default();
        let preview = preview_import("csv", b"name,password\na,b", &BTreeMap::new(), &doc).unwrap();
        assert!(apply_import(&mut doc, preview, &BTreeMap::from([(0, "replace".into())])).is_err());
        assert!(doc.items.is_empty());
    }
    #[test]
    fn mapping_is_explicit_and_malformed_rows_reported() {
        let p = preview_import(
            "csv",
            b"account,secret\na,b\nbad,row,extra",
            &BTreeMap::from([
                ("title".into(), "account".into()),
                ("password".into(), "secret".into()),
            ]),
            &Document::default(),
        )
        .unwrap();
        assert_eq!(p.rows.len(), 1);
        assert_eq!(p.failures.len(), 1);
        assert_eq!(p.rows[0].item["password"], "b");
    }
}

#[cfg(test)]
mod archive_tests {
    use super::*;
    use std::io::Write;
    fn zip_files(files: &[(&str, Vec<u8>)]) -> Vec<u8> {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for (name, data) in files {
            writer
                .start_file(*name, zip::write::SimpleFileOptions::default())
                .unwrap();
            writer.write_all(data).unwrap();
        }
        writer.finish().unwrap().into_inner()
    }
    #[test]
    fn onepux_preserves_notes_sections_original_and_document_bytes() {
        let source = json!({"accounts":[{"vaults":[{"items":[{"categoryUuid":"003","overview":{"title":"Fixture"},"details":{"notesPlain":"original note","sections":[{"fields":[{"id":"pin","title":"PIN","value":{"concealed":"synthetic-only"}}]}],"documentAttributes":{"documentId":"fixture-id","fileName":"fixture.txt"}}}]}]}]});
        let bytes = zip_files(&[
            ("export.attributes", br#"{"version":3}"#.to_vec()),
            ("export.data", serde_json::to_vec(&source).unwrap()),
            (
                "files/fixture-id___fixture.txt",
                b"synthetic attachment".to_vec(),
            ),
        ]);
        let preview =
            preview_import("1pux", &bytes, &BTreeMap::new(), &Document::default()).unwrap();
        let item = &preview.rows[0].item;
        assert_eq!(item["note"], "original note");
        assert_eq!(item["customFields"][0]["kind"], "concealed");
        assert_eq!(
            item["importSource"]["attachments"][0]["data"],
            STANDARD.encode(b"synthetic attachment")
        );
        assert_eq!(item["importSource"]["original"]["categoryUuid"], "003");
    }
    #[test]
    fn archives_reject_traversal_and_unknown_version_without_extracting_files() {
        let bad = zip_files(&[("../export.data", b"{}".to_vec())]);
        assert!(preview_import("1pux", &bad, &BTreeMap::new(), &Document::default()).is_err());
        let bad = zip_files(&[
            ("export.attributes", br#"{"version":99}"#.to_vec()),
            ("export.data", b"{}".to_vec()),
        ]);
        assert!(matches!(
            preview_import("1pux", &bad, &BTreeMap::new(), &Document::default()),
            Err(VaultError::Unsupported)
        ));
    }
}
