//! Pure JSON projections, secret-field lookup, and new-entry sanitization for AI access.
//! Keeping these pure helpers isolated from socket/approval state lets policy and
//! projection rules evolve cleanly with zero I/O or lock entanglement.

use serde_json::{Value, json};

type Result<T> = std::result::Result<T, String>;

/// Drops null, empty-string, empty-array and empty-object values so the AI only reads facts.
pub(super) fn prune(v: Value) -> Value {
    match v {
        Value::Object(map) => Value::Object(
            map.into_iter()
                .map(|(k, v)| (k, prune(v)))
                .filter(|(_, v)| !is_empty(v))
                .collect(),
        ),
        Value::Array(list) => {
            Value::Array(list.into_iter().map(prune).filter(|v| !is_empty(v)).collect())
        }
        v => v,
    }
}

pub(super) fn is_empty(v: &Value) -> bool {
    match v {
        Value::Null => true,
        Value::String(s) => s.trim().is_empty(),
        Value::Array(a) => a.is_empty(),
        Value::Object(o) => o.is_empty(),
        _ => false,
    }
}

pub(super) fn copy(src: &Value, keys: &[&str]) -> Value {
    let mut out = json!({});
    for k in keys {
        if let Some(v) = src.get(*k) {
            out[*k] = v.clone();
        }
    }
    out
}

/// Secret fields that hold a value on this entry, so the AI knows what it may request.
/// Only passwords, tokens, private keys, card numbers/CVV, concealed fields and secret scripts require `get_secret`.
pub(super) fn secret_fields(i: &Value) -> Vec<Value> {
    let candidates: &[&str] = match i["type"].as_str() {
        Some("password") => &["password"],
        Some("device") => &["password", "token", "privateKey", "nodeLink"],
        Some("creditCard") => &["number", "securityCode"],
        _ => &[],
    };
    let mut out: Vec<Value> = candidates
        .iter()
        .filter(|f| secret(i, f).is_ok_and(|v| v.as_str().is_some_and(|s| !s.is_empty())))
        .map(|f| json!(f))
        .collect();
    let device = &i["device"];
    for cmd in device["commands"].as_array().into_iter().flatten() {
        if cmd["secret"] != false && cmd["text"].as_str().is_some_and(|s| !s.is_empty()) {
            out.push(json!({
                "field": format!("command:{}", cmd["id"].as_str().unwrap_or("")),
                "label": cmd["title"]
            }));
        }
    }
    for field in i["customFields"].as_array().into_iter().flatten() {
        if field["kind"] == "concealed" && field["value"].as_str().is_some_and(|s| !s.is_empty()) {
            out.push(json!({
                "field": format!("custom:{}", field["id"].as_str().unwrap_or("")),
                "label": field["label"]
            }));
        }
    }
    out
}

/// Search rows carry only what is needed to choose an entry; `get` returns all non-secret fields plainly.
pub(super) fn projection(i: &Value, details: bool) -> Value {
    let mut out = json!({"id": i["id"], "type": i["type"], "title": i["title"]});
    if !details {
        let sub = match i["type"].as_str() {
            Some("password") => &i["username"],
            Some("device") => &i["device"]["host"],
            Some("identity") => &i["identity"]["email"],
            Some("creditCard") => &i["card"]["brand"],
            Some("secureNote") => &i["category"],
            _ => &Value::Null,
        };
        out["sub"] = sub.clone();
        return prune(out);
    }
    out["category"] = i["category"].clone();
    out["tags"] = i["tags"].clone();
    match i["type"].as_str() {
        Some("password") => {
            out["username"] = i["username"].clone();
            out["note"] = i["note"].clone();
            // A website field can itself contain credentials; expose only its origin/path.
            if let Some(raw) = i["url"].as_str() {
                let candidate = if raw.contains("://") {
                    raw.to_string()
                } else {
                    format!("https://{raw}")
                };
                if let Ok(mut url) = reqwest::Url::parse(&candidate)
                    && matches!(url.scheme(), "http" | "https")
                {
                    let _ = url.set_username("");
                    let _ = url.set_password(None);
                    url.set_query(None);
                    url.set_fragment(None);
                    out["url"] = json!(url.to_string());
                }
            }
        }
        // Rich notes keep a plain-text `note`; use `note_read` for canonical Markdown.
        Some("secureNote") => {
            out["slug"] = i["slug"].clone();
            out["properties"] = i["noteProperties"].clone();
            out["note"] = i["note"].clone();
        }
        Some("device") => {
            let device = &i["device"];
            let mut safe = copy(
                device,
                &["host", "port", "username", "authMethod", "aliases", "notes"],
            );
            safe["services"] = json!(
                device["services"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|svc| copy(
                        svc,
                        &["id", "name", "kind", "remotePort", "localPort", "path"]
                    ))
                    .collect::<Vec<_>>()
            );
            safe["commands"] = json!(
                device["commands"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|cmd| cmd["secret"] == false)
                    .map(|cmd| copy(cmd, &["id", "title", "label", "text"]))
                    .collect::<Vec<_>>()
            );
            out["device"] = safe;
        }
        Some("identity") => {
            out["identity"] = copy(
                &i["identity"],
                &[
                    "firstName",
                    "lastName",
                    "email",
                    "phone",
                    "company",
                    "address1",
                    "address2",
                    "city",
                    "region",
                    "postalCode",
                    "country",
                ],
            );
            out["note"] = i["note"].clone();
        }
        Some("creditCard") => {
            out["card"] = copy(
                &i["card"],
                &["cardholder", "expiryMonth", "expiryYear", "brand"],
            );
            out["note"] = i["note"].clone();
        }
        _ => {}
    }
    out["fields"] = json!(
        i["customFields"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|field| field["kind"] != "concealed")
            .map(|field| json!({"label": field["label"], "value": field["value"]}))
            .collect::<Vec<_>>()
    );
    out["secretFields"] = json!(secret_fields(i));
    prune(out)
}

pub(super) fn secret<'a>(i: &'a Value, field: &str) -> Result<&'a Value> {
    if !matches!(
        field,
        "password"
            | "token"
            | "privateKey"
            | "nodeLink"
            | "notes"
            | "phone"
            | "address1"
            | "address2"
            | "postalCode"
            | "number"
            | "securityCode"
    ) && !["custom:", "service:", "command:"]
        .iter()
        .any(|p| field.starts_with(p))
    {
        return Err("DeniedField".into());
    }
    // Device services and private commands: sensitive by default, released only after approval.
    if i["type"] == "device" {
        let (list, key, id) = if let Some(id) = field.strip_prefix("service:") {
            ("services", "path", id)
        } else if let Some(id) = field.strip_prefix("command:") {
            ("commands", "text", id)
        } else {
            ("", "", "")
        };
        if !list.is_empty() {
            return i["device"][list]
                .as_array()
                .into_iter()
                .flatten()
                .find(|row| row["id"] == id && (list == "services" || row["secret"] != false))
                .and_then(|row| row.get(key))
                .filter(|v| v.as_str().is_some_and(|s| !s.is_empty()))
                .ok_or("MissingField".into());
        }
    }
    if let Some(id) = field.strip_prefix("custom:") {
        return i["customFields"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|custom| custom["id"] == id && custom["kind"] == "concealed")
            .and_then(|custom| custom.get("value"))
            .filter(|value| value.is_string())
            .ok_or("DeniedField".into());
    }
    let source = match i["type"].as_str() {
        Some("device") => &i["device"],
        Some("password") if field == "password" => i,
        Some("identity") if matches!(field, "phone" | "address1" | "address2" | "postalCode") => {
            &i["identity"]
        }
        Some("creditCard") if matches!(field, "number" | "securityCode") => &i["card"],
        _ => return Err("DeniedField".into()),
    };
    source
        .get(field)
        .filter(|v| v.is_string())
        .ok_or("MissingField".into())
}

pub(super) fn bounded(v: &Value, max: usize) -> Value {
    v.as_str()
        .map_or(Value::Null, |t| json!(t.trim().chars().take(max).collect::<String>()))
}

/// Builds a new entry from whitelisted AI input. Never reads or replaces an existing record.
pub(super) fn new_item(r: &Value) -> Result<Value> {
    let text = |v: &Value, max: usize| bounded(v, max);
    let kind = match r["type"].as_str().unwrap_or("account") {
        "account" => "password",
        "note" => "secureNote",
        "totp" => "totp",
        "identity" => "identity",
        "card" => "creditCard",
        "device" => "device",
        _ => return Err("UnsupportedType".into()),
    };
    let title = text(&r["title"], 200);
    if title.as_str().is_none_or(|t| t.is_empty()) {
        return Err("MissingTitle".into());
    }
    let now = chrono::Utc::now().to_rfc3339();
    let tags: Vec<Value> = r["tags"]
        .as_array()
        .into_iter()
        .flatten()
        .take(20)
        .map(|t| text(t, 60))
        .filter(|t| !t.is_null())
        .collect();
    let mut item = json!({
        "id": super::id(), "type": kind, "title": title, "username": text(&r["username"], 500),
        "note": text(&r["note"], 200_000), "tags": tags, "noteFormat": "plain",
        "isDeleted": false, "isFavorite": false, "isPinned": false, "createdAt": now, "updatedAt": now,
    });
    for k in ["username", "note"] {
        if item[k].is_null() {
            item[k] = json!("");
        }
    }
    let pick = |src: &Value, keys: &[&str]| {
        let mut out = json!({});
        for k in keys {
            let v = text(&src[*k], 2000);
            if !v.is_null() {
                out[*k] = v;
            }
        }
        out
    };
    match kind {
        "password" => {
            item["password"] = text(&r["password"], 2000);
            item["url"] = text(&r["url"], 2000);
        }
        "totp" => {
            let secret = text(&r["secret"], 500);
            if secret.as_str().is_none_or(|v| v.is_empty()) {
                return Err("MissingSecret".into());
            }
            item["secret"] = secret;
            item["issuer"] = text(&r["issuer"], 200);
            item["period"] =
                json!(r["period"].as_u64().filter(|p| (10..=300).contains(p)).unwrap_or(30));
        }
        "identity" => {
            item["identity"] = pick(
                &r["identity"],
                &[
                    "firstName",
                    "lastName",
                    "email",
                    "phone",
                    "company",
                    "address1",
                    "address2",
                    "city",
                    "region",
                    "postalCode",
                    "country",
                ],
            );
        }
        "creditCard" => {
            item["card"] = pick(
                &r["card"],
                &[
                    "cardholder",
                    "number",
                    "expiryMonth",
                    "expiryYear",
                    "securityCode",
                    "brand",
                ],
            );
        }
        "device" => {
            let d = &r["device"];
            let mut device = pick(d, &["host", "username", "password", "privateKey", "notes"]);
            device["version"] = json!(1);
            device["port"] =
                json!(d["port"].as_u64().filter(|p| (1..=65535).contains(p)).unwrap_or(22));
            device["authMethod"] = json!(match d["authMethod"].as_str() {
                Some(m @ ("key" | "agent")) => m,
                _ if device["privateKey"].is_string() => "key",
                _ => "password",
            });
            for k in ["host", "username", "password", "privateKey", "notes"] {
                if device[k].is_null() {
                    device[k] = json!("");
                }
            }
            device["aliases"] = json!(
                d["aliases"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .take(20)
                    .map(|a| text(a, 100))
                    .filter(|a| !a.is_null())
                    .collect::<Vec<_>>()
            );
            device["services"] = json!(
                d["services"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .take(50)
                    .map(|svc| {
                        let port = |v: &Value| v.as_u64().filter(|p| (1..=65535).contains(p));
                        let remote = port(&svc["remotePort"]).unwrap_or(22);
                        json!({
                            "id": super::id(),
                            "name": text(&svc["name"], 200).as_str().unwrap_or("服务"),
                            "kind": match svc["kind"].as_str() {
                                Some(k @ ("ssh" | "vnc" | "browser")) => k,
                                _ => "custom",
                            },
                            "remotePort": remote,
                            "localPort": port(&svc["localPort"]).unwrap_or(remote),
                            "path": text(&svc["path"], 2000).as_str().unwrap_or(""),
                        })
                    })
                    .collect::<Vec<_>>()
            );
            // Commands are private unless the AI explicitly marks them ordinary.
            device["commands"] = json!(
                d["commands"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .take(100)
                    .map(|cmd| json!({
                        "id": super::id(),
                        "title": text(&cmd["title"], 200).as_str().unwrap_or("命令"),
                        "text": text(&cmd["text"], 20_000).as_str().unwrap_or(""),
                        "secret": cmd["secret"] != false,
                    }))
                    .collect::<Vec<_>>()
            );
            device["files"] = json!([]);
            item["device"] = device;
        }
        _ => {}
    }
    Ok(prune_top(item))
}

/// Drops unset optional top-level fields while keeping the fields every entry needs.
pub(super) fn prune_top(mut item: Value) -> Value {
    if let Some(map) = item.as_object_mut() {
        map.retain(|_, v| !v.is_null());
    }
    item
}
