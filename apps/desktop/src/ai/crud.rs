//! Five public MCP tools (find / read / create / update / delete) routed onto the internal
//! operations, plus entry update and delete. Every write is a normal encrypted save with an
//! AI-attributed history revision, so any change or deletion can be restored.
use super::*;
use projection::{append_note, new_item, split_fields};

const REF_PREFIXES: &[&str] = &["passwordvault:", "pv:"];

/// Strips a `passwordvault:<ref>` prefix (case-insensitive, optional `//` and `item/`/`note/`). `None` when the
/// text is not a reference.
pub(super) fn strip_ref(raw: &str) -> Option<String> {
    let t = raw.trim();
    REF_PREFIXES.iter().find_map(|p| {
        t.get(..p.len())
            .filter(|head| head.eq_ignore_ascii_case(p))
            .map(|_| {
                let rest = t[p.len()..].trim_start_matches('/').trim();
                // `passwordvault://item/<id>` and `passwordvault://note/<id|slug>` links.
                ["item/", "note/"]
                    .iter()
                    .find_map(|k| {
                        rest.get(..k.len())
                            .filter(|h| h.eq_ignore_ascii_case(k))
                            .map(|_| &rest[k.len()..])
                    })
                    .unwrap_or(rest)
                    .to_string()
            })
            .filter(|rest| !rest.is_empty())
    })
}

/// Resolves a reference to one visible entry: exact ID, then note slug, then exact title
/// (case-insensitive). Several equal titles are ambiguous rather than guessed.
pub(super) fn resolve_ref(d: &Value, c: &Value, reference: &str) -> Result<String> {
    let visible: Vec<&Value> = d["items"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|i| allowed(d, c, i))
        .collect();
    let id_of = |i: &Value| i["id"].as_str().unwrap_or("").to_string();
    if let Some(i) = visible.iter().find(|i| i["id"] == reference) {
        return Ok(id_of(i));
    }
    let slug = reference.trim_matches('/').to_lowercase();
    if let Some(i) = visible.iter().find(|i| {
        i["slug"]
            .as_str()
            .is_some_and(|s| s.trim().trim_matches('/').to_lowercase() == slug)
    }) {
        return Ok(id_of(i));
    }
    let title = reference.to_lowercase();
    let mut hits = visible.iter().filter(|i| {
        i["title"]
            .as_str()
            .is_some_and(|t| t.trim().to_lowercase() == title)
    });
    match (hits.next(), hits.next()) {
        (Some(i), None) => Ok(id_of(i)),
        (Some(_), Some(_)) => Err("AmbiguousReference".into()),
        _ => Err("UnscopedOrMissing".into()),
    }
}

fn has(r: &Value, key: &str) -> bool {
    r.get(key).is_some_and(|v| !v.is_null())
}

/// Rewrites a public CRUD request into the internal operation. Only the five public names
/// are accepted; internal operation names are never reachable from a client.
pub(super) fn route(d: &Value, c: &Value, mut r: Value) -> Result<Value> {
    if let Some(reference) = r["id"].as_str().and_then(strip_ref) {
        r["id"] = json!(resolve_ref(d, c, &reference)?);
    }
    let is_rich_note = |r: &Value| {
        notes::find_note(d, r)
            .is_some_and(|n| n["noteFormat"].as_str().is_some_and(|f| f != "plain"))
    };
    let op = r["op"].as_str().unwrap_or("").to_string();
    let internal = match op.as_str() {
        "find" => {
            if let Some(reference) = r["query"].as_str().and_then(strip_ref) {
                r["id"] = json!(resolve_ref(d, c, &reference)?);
                r["query"] = json!("");
                "search"
            } else if r["kind"] == "note"
                || [
                    "category",
                    "categoryPrefix",
                    "tag",
                    "propertyKey",
                    "propertyValue",
                ]
                .iter()
                .any(|k| has(&r, k))
            {
                "note_list"
            } else {
                "search"
            }
        }
        "read" => {
            if has(&r, "field") {
                "get_secret"
            } else if has(&r, "attachmentId") {
                "note_read_asset"
            } else if r["history"] == true || has(&r, "revisionId") {
                "note_history"
            } else if has(&r, "fileId") {
                "get"
            } else if has(&r, "slug") || has(&r, "section") || is_rich_note(&r) {
                "note_read"
            } else {
                "get"
            }
        }
        "create" => {
            if r["type"] == "note" && (has(&r, "category") || has(&r, "content")) {
                if !has(&r, "content") {
                    r["content"] = r["note"].clone();
                }
                r["createIfMissing"] = json!(true);
                r["mode"] = json!("replace");
                if !has(&r, "summary") {
                    r["summary"] = json!("AI created");
                }
                "note_update"
            } else {
                "add"
            }
        }
        "update" => {
            if let Some(attach) = r["attach"].as_object().cloned() {
                for (k, v) in attach {
                    if matches!(
                        k.as_str(),
                        "path" | "name" | "insertLink" | "aiTextAllowed" | "section"
                    ) {
                        r[k.as_str()] = v;
                    }
                }
                if !has(&r, "summary") {
                    r["summary"] = json!("AI attached a file");
                }
                "note_attach"
            } else if has(&r, "content") || has(&r, "mode") || has(&r, "slug") {
                if has(&r, "version") && !has(&r, "expectedVersion") {
                    r["expectedVersion"] = r["version"].clone();
                }
                if !has(&r, "mode") {
                    r["mode"] = json!("replace");
                }
                if !has(&r, "summary") {
                    r["summary"] = json!("AI update");
                }
                "note_update"
            } else {
                "entry_update"
            }
        }
        "delete" => "entry_delete",
        _ => return Err("ReadOnlyUnsupportedOperation".into()),
    };
    r["op"] = json!(internal);
    Ok(r)
}

fn external_type(kind: &str) -> Result<&'static str> {
    Ok(match kind {
        "password" => "account",
        "secureNote" => "note",
        "identity" => "identity",
        "creditCard" => "card",
        "device" => "device",
        _ => return Err("UnsupportedType".into()),
    })
}

/// Knowledge-base notes (those filed in a category) follow the AI-writable category whitelist.
fn check_note_write(d: &Value, item: &Value) -> Result<()> {
    let filed = item["category"]
        .as_str()
        .is_some_and(|c| !c.trim().is_empty());
    if item["type"] == "secureNote" && filed && !notes::note_writable(d, item) {
        return Err("NoteWriteDenied".into());
    }
    Ok(())
}

fn history_meta(c: &Value, r: &Value, fallback: &str) -> Value {
    json!({
        "actorType": "ai",
        "actor": c["name"].as_str().unwrap_or("AI"),
        "summary": projection::bounded(&r["summary"], 200).as_str().unwrap_or(fallback),
        "milestone": false
    })
}

/// Saves `next` under the shared write limit, as an AI history revision.
fn commit(s: &VaultSession, c: &Value, r: &Value, next: Value, fallback: &str) -> Result<()> {
    let cid = c["id"].as_str().unwrap_or("").to_string();
    reserve_add(&mut state(), &cid, Instant::now())?;
    let saved = core(
        s,
        json!({"op":"save","item":next,"richNotes":true,"historyMeta":history_meta(c, r, fallback)}),
    );
    if let Err(e) = saved {
        if let Some(recent) = state().adds.get_mut(&cid) {
            recent.pop();
        }
        return Err(e);
    }
    state().changes += 1;
    crate::events::notify("ai");
    Ok(())
}

fn put(changed: &mut Vec<String>, path: String, slot: &mut Value, v: Value) {
    if *slot != v {
        changed.push(path);
        *slot = v;
    }
}

/// Updates whitelisted fields of an existing entry without approval. The previous record is
/// kept as an encrypted history revision and a replaced password also goes to passwordHistory.
/// Only field names are returned, never values.
pub(super) fn entry_update(s: &VaultSession, r: &Value, digest: &str) -> Result<Value> {
    let _guard = SERIAL.lock().unwrap();
    let d = doc(s)?;
    let c = client_digest(&d, digest)?.clone();
    let old = entry(&d, &c, r)?.clone();
    check_note_write(&d, &old)?;
    if let Some(v) = r["version"].as_str().filter(|v| !v.is_empty())
        && old["updatedAt"].as_str() != Some(v)
    {
        return Err("VersionConflict".into());
    }
    let ext = external_type(old["type"].as_str().unwrap_or(""))?;
    if ext == "note" && has(r, "note") && old["noteFormat"].as_str().is_some_and(|f| f != "plain") {
        return Err("UseNoteContent".into());
    }
    // Reuse the create whitelist, bounds and placeholder check on the requested fields.
    let mut probe = r.clone();
    probe["type"] = json!(ext);
    if !has(&probe, "title") {
        probe["title"] = old["title"].clone();
    }
    if ext == "device" && !probe["device"].is_object() {
        probe["device"] = json!({});
    }
    let fresh = new_item(&probe)?;
    let mut next = old.clone();
    let mut changed: Vec<String> = Vec::new();
    for k in ["title", "username", "password", "url", "note"] {
        if has(r, k) && !fresh[k].is_null() {
            put(&mut changed, k.to_string(), &mut next[k], fresh[k].clone());
        }
    }
    if r["tags"].is_array() {
        put(
            &mut changed,
            "tags".into(),
            &mut next["tags"],
            fresh["tags"].clone(),
        );
    }
    for sub in ["identity", "card", "device"] {
        let Some(keys) = r[sub]
            .as_object()
            .map(|o| o.keys().cloned().collect::<Vec<_>>())
        else {
            continue;
        };
        let Some(clean) = fresh[sub].as_object() else {
            continue;
        };
        if !next[sub].is_object() {
            next[sub] = json!({});
        }
        for key in keys {
            if let Some(v) = clean.get(&key) {
                put(
                    &mut changed,
                    format!("{sub}.{key}"),
                    &mut next[sub][&key],
                    v.clone(),
                );
            }
        }
    }
    let mut list = next["customFields"].as_array().cloned().unwrap_or_default();
    if let Some(remove) = r["removeFields"].as_array() {
        for name in remove
            .iter()
            .filter_map(Value::as_str)
            .map(|n| n.trim().to_lowercase())
        {
            let before = list.len();
            list.retain(|e| {
                e["label"]
                    .as_str()
                    .is_none_or(|l| l.trim().to_lowercase() != name)
            });
            if list.len() != before {
                changed.push(format!("custom:-{name}"));
            }
        }
    }
    let mut note_lines = Vec::new();
    if let Some(fields) = fresh["customFields"]
        .as_array()
        .filter(|_| r["customFields"].is_array())
    {
        // Matching labels update in place; only genuinely new fields count towards the limit.
        let (existing, new): (Vec<Value>, Vec<Value>) = fields.iter().cloned().partition(|f| {
            let label = f["label"].as_str().unwrap_or("").to_lowercase();
            list.iter().any(|e| {
                e["label"]
                    .as_str()
                    .is_some_and(|l| l.to_lowercase() == label)
            })
        });
        let (new, lines) = split_fields(new, list.len());
        note_lines = lines;
        for f in existing.iter().chain(new.iter()) {
            let label = f["label"].as_str().unwrap_or("").to_lowercase();
            match list.iter_mut().find(|e| {
                e["label"]
                    .as_str()
                    .is_some_and(|l| l.to_lowercase() == label)
            }) {
                Some(e) if e["value"] != f["value"] || e["kind"] != f["kind"] => {
                    e["value"] = f["value"].clone();
                    e["kind"] = f["kind"].clone();
                    if f.get("group").is_some() {
                        e["group"] = f["group"].clone();
                    }
                    changed.push(format!("custom:{}", f["label"].as_str().unwrap_or("")));
                }
                Some(_) => {}
                None => {
                    list.push(f.clone());
                    changed.push(format!("custom:{}", f["label"].as_str().unwrap_or("")));
                }
            }
        }
    }
    if list.is_empty() {
        if let Some(map) = next.as_object_mut() {
            map.remove("customFields");
        }
    } else {
        next["customFields"] = json!(list);
    }
    if !note_lines.is_empty() {
        append_note(&mut next["note"], &note_lines);
        changed.push("note".into());
    }
    let id = old["id"].clone();
    if changed.is_empty() {
        return Ok(json!({"id":id,"title":old["title"],"updated":false}));
    }
    let now = chrono::Utc::now().to_rfc3339();
    if changed.iter().any(|f| f == "password")
        && let Some(previous) = old["password"].as_str().filter(|p| !p.is_empty())
    {
        let mut hist = old["passwordHistory"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        hist.insert(0, json!({"password": previous, "changedAt": now}));
        hist.truncate(50);
        next["passwordHistory"] = json!(hist);
    }
    next["updatedAt"] = json!(now);
    commit(s, &c, r, next, "AI update")?;
    Ok(json!({"id":id,"title":old["title"],"updated":true,"fields":changed,"version":now}))
}

/// Moves an entry to the Trash (restorable from the app and from history); never purges.
pub(super) fn entry_delete(s: &VaultSession, r: &Value, digest: &str) -> Result<Value> {
    let _guard = SERIAL.lock().unwrap();
    let d = doc(s)?;
    let c = client_digest(&d, digest)?.clone();
    let old = entry(&d, &c, r)?.clone();
    check_note_write(&d, &old)?;
    external_type(old["type"].as_str().unwrap_or(""))?;
    let now = chrono::Utc::now().to_rfc3339();
    let mut next = old.clone();
    next["isDeleted"] = json!(true);
    next["isPinned"] = json!(false);
    next["deletedAt"] = json!(now);
    next["updatedAt"] = json!(now);
    commit(s, &c, r, next, "AI moved to Trash")?;
    Ok(json!({"id":old["id"],"title":old["title"],"deleted":true,"restorable":true}))
}
