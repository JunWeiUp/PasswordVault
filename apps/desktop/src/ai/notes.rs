//! Knowledge-base note MCP operations: `note_list`, `note_read`, `note_update`, `note_history`.
//! Strictly scoped to `secureNote` items; credential types remain immutable and unaffected.
use super::*;
use crate::markdown;

const NOTE_WRITE_LIMIT: usize = 30;
const NOTE_WRITE_WINDOW: Duration = Duration::from_secs(60);

pub(super) fn cat_matches(category: &str, prefix: &str) -> bool {
    !prefix.is_empty()
        && (category == prefix
            || category
                .strip_prefix(prefix)
                .is_some_and(|rest| rest.starts_with('/')))
}

pub(super) fn category_writable(d: &Value, category: &str) -> bool {
    if d["settings"]["aiAccessEnabled"] != true
        || d["settings"]["aiAccessScopes"]["notes"] != true
        || d["settings"]["aiAccessNoteAutoWrite"] != true
        || category.is_empty()
    {
        return false;
    }
    d["settings"]["aiAccessNoteWritableCategories"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .any(|prefix| cat_matches(category, prefix.trim().trim_matches('/')))
}

pub(super) fn note_writable(d: &Value, item: &Value) -> bool {
    item["type"] == "secureNote"
        && !item["isDeleted"].as_bool().unwrap_or(false)
        && !excluded(d, item)
        && item["sharedVaultId"].as_str().is_none_or(|s| s.is_empty())
        && category_writable(d, item["category"].as_str().unwrap_or(""))
}

pub(super) fn note_readable(d: &Value, _c: &Value, item: &Value) -> bool {
    item["type"] == "secureNote"
        && !item["isDeleted"].as_bool().unwrap_or(false)
        && !excluded(d, item)
        && d["settings"]["aiAccessScopes"]["notes"] == true
}

pub(super) fn note_assets_enabled(d: &Value) -> bool {
    d["settings"]["aiAccessEnabled"] == true
        && d["settings"]["aiAccessScopes"]["notes"] == true
        && d["settings"]["aiAccessScopes"]["noteAssets"] != false
}

fn note_asset_text_allowed(d: &Value, note_id: &str, attachment_id: &str) -> bool {
    d["settings"]["aiAccessNoteAssetText"][note_id][attachment_id] == true
}

pub(super) fn note_version_hash(item: &Value) -> String {
    let md = markdown::item_to_markdown(item);
    let canonical = json!({
        "title": item["title"],
        "category": item["category"],
        "slug": item["slug"],
        "tags": item["tags"],
        "noteProperties": item["noteProperties"],
        "markdown": md,
    });
    hash(&canonical.to_string()).chars().take(16).collect()
}

pub(super) fn find_note<'a>(d: &'a Value, r: &Value) -> Option<&'a Value> {
    let items = d["items"].as_array()?;
    if let Some(id) = r["id"].as_str().filter(|s| !s.is_empty()) {
        return items.iter().find(|i| {
            i["type"] == "secureNote" && !i["isDeleted"].as_bool().unwrap_or(false) && i["id"] == id
        });
    }
    if let Some(slug) = r["slug"]
        .as_str()
        .map(|s| s.trim().trim_matches('/').to_lowercase())
        .filter(|s| !s.is_empty())
    {
        return items.iter().find(|i| {
            i["type"] == "secureNote"
                && !i["isDeleted"].as_bool().unwrap_or(false)
                && i["slug"]
                    .as_str()
                    .is_some_and(|s| s.trim().trim_matches('/').to_lowercase() == slug)
        });
    }
    None
}

fn sanitize_properties(raw: &Value) -> Result<Option<Vec<Value>>> {
    if raw.is_null() {
        return Ok(None);
    }
    let arr = raw.as_array().ok_or_else(|| "InvalidData".to_string())?;
    if arr.len() > 64 {
        return Err("InvalidData".into());
    }
    let mut out = Vec::with_capacity(arr.len());
    for entry in arr {
        let k = entry["key"]
            .as_str()
            .map(str::trim)
            .filter(|s| {
                !s.is_empty() && s.chars().count() <= 80 && !s.chars().any(char::is_control)
            })
            .ok_or_else(|| "InvalidData".to_string())?;
        let v = entry["value"]
            .as_str()
            .map(str::trim)
            .filter(|s| s.chars().count() <= 500)
            .ok_or_else(|| "InvalidData".to_string())?;
        out.push(json!({"key": k, "value": v}));
    }
    Ok(Some(out))
}

fn sanitize_slug(raw: &Value) -> Result<Option<String>> {
    if raw.is_null() {
        return Ok(None);
    }
    let s = raw
        .as_str()
        .map(|t| t.trim().trim_matches('/'))
        .ok_or_else(|| "InvalidData".to_string())?;
    if s.chars().count() > 120 || s.chars().any(char::is_control) {
        return Err("InvalidData".into());
    }
    Ok(Some(s.to_owned()))
}

fn summary_projection(d: &Value, item: &Value) -> Value {
    prune(json!({
        "id": item["id"],
        "slug": item["slug"],
        "title": item["title"],
        "category": item["category"],
        "tags": item["tags"],
        "properties": item["noteProperties"],
        "writable": note_writable(d, item),
        "updatedAt": item["updatedAt"],
        "versionHash": note_version_hash(item),
        "lastActor": item["lastActor"],
        "lastSummary": item["lastSummary"],
    }))
}

fn reserve_note_write(st: &mut State, client: &str, now: Instant) -> Result<()> {
    let recent = st.note_writes.entry(client.to_string()).or_default();
    recent.retain(|t| now.duration_since(*t) < NOTE_WRITE_WINDOW);
    if recent.len() >= NOTE_WRITE_LIMIT {
        return Err("RateLimited".into());
    }
    recent.push(now);
    Ok(())
}

pub(super) fn note_list(s: &VaultSession, d: &Value, c: &Value, r: &Value) -> Result<Value> {
    if d["settings"]["aiAccessScopes"]["notes"] != true {
        return Err("UnscopedOrMissing".into());
    }
    let cat_prefix = r["categoryPrefix"]
        .as_str()
        .or_else(|| r["category"].as_str())
        .map(|s| s.trim().trim_matches('/'))
        .unwrap_or("");
    let query = r["query"].as_str().unwrap_or("").trim().to_lowercase();
    let tag = r["tag"].as_str().unwrap_or("").trim().to_lowercase();
    let prop_key = r["propertyKey"]
        .as_str()
        .unwrap_or("")
        .trim()
        .to_lowercase();
    let prop_val = r["propertyValue"]
        .as_str()
        .unwrap_or("")
        .trim()
        .to_lowercase();
    let limit = r["limit"].as_u64().unwrap_or(50).clamp(1, 100) as usize;

    // Only hydrate full note bodies up front when a full-text `query` is supplied;
    // otherwise filter on L1 summaries and hydrate only the `limit` returned notes.
    let full_doc_owned;
    let source = if query.is_empty() {
        d
    } else {
        full_doc_owned = doc_full(s)?;
        &full_doc_owned
    };

    let mut matched: Vec<&Value> = source["items"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|item| note_readable(source, c, item))
        .filter(|item| {
            if !cat_prefix.is_empty()
                && !cat_matches(item["category"].as_str().unwrap_or(""), cat_prefix)
            {
                return false;
            }
            if !tag.is_empty()
                && !item["tags"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|t| t.as_str().is_some_and(|s| s.to_lowercase() == tag))
            {
                return false;
            }
            if !prop_key.is_empty() || !prop_val.is_empty() {
                let props = item["noteProperties"].as_array();
                let ok = props.into_iter().flatten().any(|p| {
                    let km = prop_key.is_empty()
                        || p["key"]
                            .as_str()
                            .is_some_and(|k| k.to_lowercase() == prop_key);
                    let vm = prop_val.is_empty()
                        || p["value"]
                            .as_str()
                            .is_some_and(|v| v.to_lowercase().contains(&prop_val));
                    km && vm
                });
                if !ok {
                    return false;
                }
            }
            if !query.is_empty() {
                let props_text: String = item["noteProperties"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|p| {
                        format!(
                            "{} {}",
                            p["key"].as_str().unwrap_or(""),
                            p["value"].as_str().unwrap_or("")
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(" ");
                let hay = format!(
                    "{} {} {} {} {} {}",
                    item["title"].as_str().unwrap_or(""),
                    item["slug"].as_str().unwrap_or(""),
                    item["category"].as_str().unwrap_or(""),
                    item["tags"],
                    props_text,
                    item["note"].as_str().unwrap_or("")
                )
                .to_lowercase();
                if !hay.contains(&query) {
                    return false;
                }
            }
            true
        })
        .collect();
    matched.sort_by(|a, b| {
        b["updatedAt"]
            .as_str()
            .unwrap_or("")
            .cmp(a["updatedAt"].as_str().unwrap_or(""))
    });
    let auto_write = d["settings"]["aiAccessEnabled"] == true
        && d["settings"]["aiAccessScopes"]["notes"] == true
        && d["settings"]["aiAccessNoteAutoWrite"] == true;
    let writable_categories: Vec<String> = if auto_write {
        d["settings"]["aiAccessNoteWritableCategories"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(|s| s.trim().trim_matches('/').to_owned())
            .filter(|s| !s.is_empty())
            .collect()
    } else {
        Vec::new()
    };
    let mut notes: Vec<Value> = Vec::new();
    for item in matched.into_iter().take(limit) {
        if item["noteSummary"] == true {
            if let Some(nid) = item["id"].as_str() {
                if let Ok(full) = full_item(s, nid) {
                    notes.push(summary_projection(source, &full));
                    continue;
                }
            }
        }
        notes.push(summary_projection(source, item));
    }
    Ok(json!({
        "notes": notes,
        "autoWriteEnabled": auto_write,
        "writableCategories": writable_categories,
    }))
}

pub(super) fn note_read(s: &VaultSession, d: &Value, c: &Value, r: &Value) -> Result<Value> {
    let summary_item = find_note(d, r)
        .filter(|i| note_readable(d, c, i))
        .ok_or("UnscopedOrMissing")?;
    let note_id = summary_item["id"].as_str().ok_or("InvalidData")?;
    let hydrated;
    let item = if summary_item["noteSummary"] == true {
        hydrated = full_item(s, note_id)?;
        &hydrated
    } else {
        summary_item
    };
    let full_md = markdown::item_to_markdown(item);
    let (body, section_out) = if let Some(sec) = r["section"]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        let extracted = markdown::extract_section(&full_md, sec).ok_or("SectionNotFound")?;
        (extracted, Some(sec.to_owned()))
    } else {
        (full_md, None)
    };
    let mut out = summary_projection(d, item);
    out["markdown"] = json!(body);
    if let Some(sec) = section_out {
        out["section"] = json!(sec);
    }
    if let Ok(list) = core(s, json!({"op":"note-attachments-list","noteId":note_id})) {
        let mut attachments = Vec::new();
        for a in list["attachments"].as_array().into_iter().flatten() {
            let aid = a["id"].as_str().unwrap_or("");
            if aid.is_empty() {
                continue;
            }
            let name = a["name"].as_str().unwrap_or("");
            let mime = a["mime"].as_str().unwrap_or("");
            attachments.push(json!({
                "id": aid,
                "name": name,
                "mime": mime,
                "size": a["size"],
                "aiReadable": note_assets_enabled(d) && note_asset_text_allowed(d, note_id, aid),
                "canExtractText": crate::text_extract::can_extract_text(name, mime),
            }));
        }
        if !attachments.is_empty() {
            out["attachments"] = json!(attachments);
        }
    }
    Ok(out)
}

pub(super) fn note_update(s: &VaultSession, r: &Value, digest: &str) -> Result<Value> {
    let summary = r["summary"]
        .as_str()
        .map(str::trim)
        .filter(|t| !t.is_empty() && t.chars().count() <= 240 && !t.chars().any(char::is_control))
        .ok_or("MissingSummary")?
        .to_owned();
    let mode = match r["mode"].as_str().unwrap_or("") {
        m @ ("append" | "replace_section" | "replace") => m,
        _ => return Err("InvalidMode".into()),
    };
    let content = r["content"].as_str().ok_or("EmptyContent")?;
    if content.len() > 2 * 1024 * 1024 {
        return Err("NoteTooLarge".into());
    }
    if projection::contains_redacted_placeholder(content)
        || r["title"]
            .as_str()
            .is_some_and(projection::contains_redacted_placeholder)
    {
        return Err("RedactedPlaceholderDetected".into());
    }
    projection::reject_redacted_placeholders(&r["properties"])?;
    let props_patch = sanitize_properties(&r["properties"])?;
    let slug_patch = sanitize_slug(&r["slug"])?;

    let (saved_item, created) = {
        let _guard = SERIAL.lock().unwrap();
        let d = doc(s)?;
        let c = client_digest(&d, digest)?;
        let cid = c["id"].as_str().unwrap_or("").to_string();
        let cname = c["name"].as_str().unwrap_or("AI").to_string();
        let actor = format!("AI · {cname}");
        let now = chrono::Utc::now().to_rfc3339();

        let existing = find_note(&d, r).cloned();
        let (mut next_item, created) = if let Some(mut item) = existing {
            if !note_writable(&d, &item) {
                return Err("NoteWriteDenied".into());
            }
            if item["noteSummary"] == true {
                let nid = item["id"].as_str().ok_or("InvalidData")?;
                item = full_item(s, nid)?;
            }
            let current_ver = note_version_hash(&item);
            if let Some(expected) = r["expectedVersion"].as_str().filter(|s| !s.is_empty()) {
                if expected != current_ver {
                    return Err("VersionConflict".into());
                }
            } else if matches!(mode, "replace" | "replace_section") {
                return Err("VersionConflict".into());
            }
            if let Some(new_cat) = r["category"]
                .as_str()
                .map(|c| c.trim().trim_matches('/'))
                .filter(|c| !c.is_empty())
            {
                if !category_writable(&d, new_cat) {
                    return Err("NoteWriteDenied".into());
                }
                item["category"] = json!(new_cat);
            }
            let current_md = markdown::item_to_markdown(&item);
            let next_md = match mode {
                "append" => markdown::append_markdown(&current_md, r["section"].as_str(), content)?,
                "replace_section" => {
                    let sec = r["section"]
                        .as_str()
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .ok_or("MissingSection")?;
                    markdown::replace_section(&current_md, sec, content)?
                }
                "replace" => content.trim().to_owned(),
                _ => unreachable!(),
            };
            let (plain_text, mut note_doc) = markdown::parse_markdown_patch(&next_md)?;
            let existing_metas = item["id"]
                .as_str()
                .and_then(|nid| core(s, json!({"op":"note-attachments-list","noteId":nid})).ok())
                .and_then(|v| v["attachments"].as_array().cloned())
                .unwrap_or_default();
            markdown::hydrate_attachment_nodes(
                &mut note_doc,
                item.get("noteDocument"),
                &existing_metas,
            );
            item["note"] = json!(plain_text);
            item["noteFormat"] = json!("rich-v1");
            item["noteDocument"] = note_doc;
            if let Some(title) = r["title"].as_str().map(str::trim).filter(|t| !t.is_empty()) {
                item["title"] = json!(title.chars().take(200).collect::<String>());
            }
            (item, false)
        } else {
            if r["createIfMissing"] != true {
                return Err("UnscopedOrMissing".into());
            }
            let title = r["title"]
                .as_str()
                .map(str::trim)
                .filter(|t| !t.is_empty())
                .ok_or("MissingTitle")?;
            let cat = r["category"]
                .as_str()
                .map(|c| c.trim().trim_matches('/'))
                .filter(|c| !c.is_empty())
                .ok_or("NoteWriteDenied")?;
            if !category_writable(&d, cat) {
                return Err("NoteWriteDenied".into());
            }
            let initial_md = if mode == "append" {
                markdown::append_markdown("", r["section"].as_str(), content)?
            } else {
                content.trim().to_owned()
            };
            let (plain_text, note_doc) = markdown::parse_markdown_patch(&initial_md)?;
            let item = json!({
                "id": id(),
                "type": "secureNote",
                "title": title.chars().take(200).collect::<String>(),
                "category": cat,
                "username": "",
                "note": plain_text,
                "noteFormat": "rich-v1",
                "noteDocument": note_doc,
                "tags": [],
                "isDeleted": false,
                "isFavorite": false,
                "isPinned": false,
                "createdAt": now,
                "updatedAt": now,
            });
            (item, true)
        };

        if let Some(slug) = slug_patch {
            if slug.is_empty() {
                next_item.as_object_mut().unwrap().remove("slug");
            } else {
                next_item["slug"] = json!(slug);
            }
        }
        if let Some(tags) = r["tags"].as_array() {
            let clean: Vec<Value> = tags
                .iter()
                .take(20)
                .filter_map(Value::as_str)
                .map(str::trim)
                .filter(|t| !t.is_empty())
                .map(|t| json!(t.chars().take(60).collect::<String>()))
                .collect();
            next_item["tags"] = json!(clean);
        }
        if let Some(props) = props_patch {
            next_item["noteProperties"] = json!(props);
        }
        next_item["lastActor"] = json!(actor);
        next_item["lastSummary"] = json!(summary);
        next_item["updatedAt"] = json!(now);

        reserve_note_write(&mut state(), &cid, Instant::now())?;
        let save_res = core(
            s,
            json!({
                "op": "save",
                "richNotes": true,
                "item": next_item,
                "historyMeta": {
                    "actorType": "ai",
                    "actor": actor,
                    "summary": summary,
                    "milestone": false
                }
            }),
        );
        if let Err(e) = save_res {
            if let Some(recent) = state().note_writes.get_mut(&cid) {
                recent.pop();
            }
            return Err(e);
        }
        (next_item, created)
    };

    if created {
        grant_entry(s, digest, saved_item["id"].as_str().unwrap_or(""))?;
    }
    let unix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    {
        let mut st = state();
        st.changes += 1;
        st.last_note_change = Some(json!({
            "id": saved_item["id"],
            "title": saved_item["title"],
            "actor": saved_item["lastActor"],
            "summary": saved_item["lastSummary"],
            "unixSeconds": unix,
        }));
    }
    crate::events::notify("ai");
    Ok(prune(json!({
        "id": saved_item["id"],
        "slug": saved_item["slug"],
        "title": saved_item["title"],
        "category": saved_item["category"],
        "versionHash": note_version_hash(&saved_item),
        "updatedAt": saved_item["updatedAt"],
        "created": created,
        "saved": true,
    })))
}

pub(super) fn note_history(s: &VaultSession, d: &Value, c: &Value, r: &Value) -> Result<Value> {
    let item = find_note(d, r)
        .filter(|i| note_readable(d, c, i))
        .ok_or("UnscopedOrMissing")?;
    let note_id = item["id"].as_str().ok_or("UnscopedOrMissing")?;
    let limit = r["limit"].as_u64().unwrap_or(30).clamp(1, 50);
    let page = core(
        s,
        json!({"op": "history-list", "id": note_id, "offset": 0, "limit": limit}),
    )?;
    let revisions = page["revisions"].as_array().cloned().unwrap_or_default();
    if let Some(rev_id) = r["revisionId"].as_str().filter(|s| !s.is_empty()) {
        let rev = revisions
            .into_iter()
            .find(|row| row["id"] == rev_id)
            .ok_or("UnscopedOrMissing")?;
        let snap = &rev["item"];
        if snap.is_null() {
            return Err("UnscopedOrMissing".into());
        }
        return Ok(prune(json!({
            "id": note_id,
            "revisionId": rev["id"],
            "capturedAt": rev["capturedAt"],
            "actorType": rev["actorType"],
            "actor": rev["actor"],
            "summary": rev["summary"],
            "milestone": rev["milestone"],
            "title": snap["title"],
            "category": snap["category"],
            "slug": snap["slug"],
            "tags": snap["tags"],
            "properties": snap["noteProperties"],
            "markdown": markdown::item_to_markdown(snap),
        })));
    }
    let rows: Vec<Value> = revisions
        .into_iter()
        .map(|rev| {
            prune(json!({
                "id": rev["id"],
                "capturedAt": rev["capturedAt"],
                "actorType": rev["actorType"],
                "actor": rev["actor"],
                "summary": rev["summary"],
                "milestone": rev["milestone"],
            }))
        })
        .collect();
    Ok(prune(json!({
        "id": note_id,
        "slug": item["slug"],
        "title": item["title"],
        "total": page["total"],
        "revisions": rows,
    })))
}

/// Archives a local file (<= 100 MiB) into a user-authorized writable note as chunked encrypted
/// `.pvblob` storage, inserts a clean `[name](pv-asset://<id>)` Markdown link, and records history.
/// Never modifies or deletes the original file on disk.
pub(super) fn note_attach(s: &VaultSession, r: &Value, digest: &str) -> Result<Value> {
    let summary = r["summary"]
        .as_str()
        .map(str::trim)
        .filter(|t| !t.is_empty() && t.chars().count() <= 240 && !t.chars().any(char::is_control))
        .ok_or("MissingSummary")?
        .to_owned();
    let path_str = r["path"]
        .as_str()
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .ok_or("InvalidData")?;
    let path = std::path::Path::new(path_str);
    if !path.is_absolute() {
        return Err("InvalidData".into());
    }
    let (detected_name, mime, _) = crate::attachments::inspect_import_file(path)?;
    let final_name = r["name"]
        .as_str()
        .map(str::trim)
        .filter(|n| {
            !n.is_empty()
                && n.len() <= 240
                && !n.contains('/')
                && !n.contains('\\')
                && !n.chars().any(char::is_control)
        })
        .unwrap_or(&detected_name)
        .to_owned();
    let insert_link = r["insertLink"].as_bool().unwrap_or(true);

    let (saved_item, meta, link_md) = {
        let _guard = SERIAL.lock().unwrap();
        let d = doc(s)?;
        let c = client_digest(&d, digest)?;
        if !note_assets_enabled(&d) {
            return Err("AssetAccessDisabled".into());
        }
        let cid = c["id"].as_str().unwrap_or("").to_string();
        let cname = c["name"].as_str().unwrap_or("AI").to_string();
        let actor = format!("AI · {cname}");
        let now = chrono::Utc::now().to_rfc3339();

        let mut item = find_note(&d, r).cloned().ok_or("UnscopedOrMissing")?;
        if !note_writable(&d, &item) {
            return Err("NoteWriteDenied".into());
        }
        let note_id = item["id"].as_str().ok_or("InvalidData")?.to_owned();
        if item["noteSummary"] == true {
            item = full_item(s, &note_id)?;
        }
        reserve_note_write(&mut state(), &cid, Instant::now())?;

        let meta_raw = match s.import_note_attachment_file(
            note_id.clone(),
            path_str.to_owned(),
            final_name.clone(),
            mime.clone(),
        ) {
            Ok(raw) => raw,
            Err(e) => {
                if let Some(recent) = state().note_writes.get_mut(&cid) {
                    recent.pop();
                }
                return Err(error_code(e));
            }
        };
        let meta: Value = serde_json::from_str(&meta_raw).map_err(|_| "InvalidData")?;
        let aid = meta["id"].as_str().ok_or("InvalidData")?;
        let is_img = mime.starts_with("image/");
        let link_md = format!(
            "{}[{}](pv-asset://{aid})",
            if is_img { "!" } else { "" },
            final_name
        );

        let current_md = markdown::item_to_markdown(&item);
        let next_md = if insert_link {
            markdown::append_markdown(&current_md, r["section"].as_str(), &link_md)?
        } else {
            current_md
        };
        let (plain_text, mut note_doc) = markdown::parse_markdown_patch(&next_md)?;
        let mut all_metas = core(s, json!({"op":"note-attachments-list","noteId":note_id}))
            .ok()
            .and_then(|v| v["attachments"].as_array().cloned())
            .unwrap_or_default();
        all_metas.push(meta.clone());
        markdown::hydrate_attachment_nodes(&mut note_doc, item.get("noteDocument"), &all_metas);

        item["note"] = json!(plain_text);
        item["noteFormat"] = json!("rich-v1");
        item["noteDocument"] = note_doc;
        item["lastActor"] = json!(actor);
        item["lastSummary"] = json!(summary);
        item["updatedAt"] = json!(now);

        let save_res = core(
            s,
            json!({
                "op": "save",
                "richNotes": true,
                "item": item,
                "historyMeta": {
                    "actorType": "ai",
                    "actor": actor,
                    "summary": summary,
                    "milestone": false
                }
            }),
        );
        if let Err(e) = save_res {
            let _ = s.discard_note_attachment(note_id, aid.to_owned());
            if let Some(recent) = state().note_writes.get_mut(&cid) {
                recent.pop();
            }
            return Err(e);
        }
        (item, meta, link_md)
    };

    let unix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    {
        let mut st = state();
        st.changes += 1;
        st.last_note_change = Some(json!({
            "id": saved_item["id"],
            "title": saved_item["title"],
            "actor": saved_item["lastActor"],
            "summary": saved_item["lastSummary"],
            "unixSeconds": unix,
        }));
    }
    crate::events::notify("ai");
    Ok(prune(json!({
        "id": saved_item["id"],
        "slug": saved_item["slug"],
        "title": saved_item["title"],
        "attachmentId": meta["id"],
        "name": meta["name"],
        "mime": meta["mime"],
        "size": meta["size"],
        "markdownLink": link_md,
        "versionHash": note_version_hash(&saved_item),
        "saved": true,
    })))
}

/// Reads locally extracted plain text from a PDF/Word/Excel/text note attachment ONLY when
/// the user has explicitly enabled `AI 可读文本` for that specific attachment.
pub(super) fn note_read_asset(s: &VaultSession, d: &Value, c: &Value, r: &Value) -> Result<Value> {
    if !note_assets_enabled(d) {
        return Err("AssetAccessDisabled".into());
    }
    let item = find_note(d, r)
        .filter(|i| note_readable(d, c, i))
        .ok_or("UnscopedOrMissing")?;
    let note_id = item["id"].as_str().ok_or("UnscopedOrMissing")?;
    let attachment_id = r["attachmentId"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("MissingFile")?;
    if !note_asset_text_allowed(d, note_id, attachment_id) {
        return Err("AssetTextDenied".into());
    }
    let list = core(s, json!({"op":"note-attachments-list","noteId":note_id}))?;
    let meta = list["attachments"]
        .as_array()
        .and_then(|arr| arr.iter().find(|a| a["id"] == attachment_id))
        .ok_or("MissingFile")?;
    let name = meta["name"].as_str().unwrap_or("");
    let mime = meta["mime"].as_str().unwrap_or("");
    let bytes = zeroize::Zeroizing::new(
        s.read_note_attachment(note_id.into(), attachment_id.into())
            .map_err(error_code)?,
    );
    let extracted = crate::text_extract::extract_text(name, mime, &bytes)?;
    let total_chars = extracted.chars().count();
    let offset = r["offset"].as_u64().unwrap_or(0) as usize;
    let limit = r["limit"].as_u64().unwrap_or(4096).clamp(1, 16384) as usize;
    let chunk: String = extracted.chars().skip(offset).take(limit).collect();
    let next = offset.saturating_add(chunk.chars().count());
    Ok(json!({
        "id": note_id,
        "attachmentId": attachment_id,
        "name": name,
        "mime": mime,
        "text": chunk,
        "nextOffset": next,
        "totalChars": total_chars,
        "eof": next >= total_chars,
    }))
}
