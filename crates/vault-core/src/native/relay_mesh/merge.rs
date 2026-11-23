//! Deterministic C1 + R9 + C3 concurrent note merge logic for personal mesh sync.
use super::*;

fn split_md_sections(text: &str) -> Vec<(String, String)> {
    let mut sections: Vec<(String, String)> = Vec::new();
    let mut cur_heading = String::new();
    let mut cur_lines: Vec<&str> = Vec::new();
    for line in text.lines() {
        if line.starts_with("## ") {
            if !cur_heading.is_empty() || !cur_lines.is_empty() {
                sections.push((cur_heading.clone(), cur_lines.join("\n")));
            }
            cur_heading = line.trim().to_owned();
            cur_lines.clear();
        } else {
            cur_lines.push(line);
        }
    }
    if !cur_heading.is_empty() || !cur_lines.is_empty() {
        sections.push((cur_heading, cur_lines.join("\n")));
    }
    sections
}

fn collect_attachment_nodes(node: &Value, out: &mut Vec<(String, Value)>) {
    if matches!(
        node["type"].as_str(),
        Some("vaultImage" | "vaultAttachment")
    ) {
        if let Some(id) = node["attrs"]["attachmentId"].as_str() {
            out.push((id.to_owned(), node.clone()));
        }
    }
    if let Some(children) = node["content"].as_array() {
        for child in children {
            collect_attachment_nodes(child, out);
        }
    }
}

pub(super) struct MergedNote {
    pub(super) item: Value,
    pub(super) has_overlap: bool,
    pub(super) conflict_section: String,
    pub(super) auto_merged: Vec<String>,
    pub(super) asset_guard: String,
}

/// Deterministic C1 + R9 merge for concurrent `secureNote` edits:
/// - Unions tags and non-conflicting structured properties.
/// - Protects heavy attachments from both sides via union (R9) so assets never vanish.
/// - Auto-merges disjoint `## ` Markdown sections cleanly (C1), using 3-way common ancestor `base` when available.
/// - Flags overlapping paragraph/section edits for visible C3 parallel-branch resolution.
pub(super) fn merge_concurrent_note(
    base: Option<&Value>,
    winner: &Value,
    loser: &Value,
) -> MergedNote {
    let mut merged = winner.clone();
    let mut auto_merged = Vec::new();

    // 1. C1 Tag union (sorted, deduplicated).
    let w_tags: BTreeSet<String> = winner["tags"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
    let l_tags: BTreeSet<String> = loser["tags"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
    if w_tags != l_tags {
        let union: Vec<String> = w_tags.union(&l_tags).cloned().collect();
        merged["tags"] = json!(union);
        auto_merged.push("标签（取并集自动合并）".into());
    }

    // 2. C1 Structured `noteProperties` merge: preserve unique keys from loser.
    if let Some(l_props) = loser["noteProperties"].as_array() {
        let mut w_props = winner["noteProperties"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let existing_keys: BTreeSet<String> = w_props
            .iter()
            .filter_map(|p| p["key"].as_str().map(str::to_owned))
            .collect();
        let mut added = 0usize;
        for prop in l_props {
            if let Some(k) = prop["key"].as_str() {
                if !existing_keys.contains(k) {
                    w_props.push(prop.clone());
                    added += 1;
                }
            }
        }
        if added > 0 {
            merged["noteProperties"] = json!(w_props);
            auto_merged.push(format!("结构化属性（合入 {added} 项无冲突属性）"));
        }
    }

    // 3. R9 Attachment union guard: rescue any attachment node referenced in loser but absent from winner.
    let mut w_nodes = Vec::new();
    let mut l_nodes = Vec::new();
    collect_attachment_nodes(&winner["noteDocument"], &mut w_nodes);
    collect_attachment_nodes(&loser["noteDocument"], &mut l_nodes);
    let w_att_ids: BTreeSet<String> = w_nodes.into_iter().map(|(id, _)| id).collect();
    let mut rescued = 0usize;
    let mut seen_rescue = BTreeSet::new();
    for (aid, node) in l_nodes {
        if !w_att_ids.contains(&aid) && seen_rescue.insert(aid) {
            if let Some(arr) = merged["noteDocument"]["content"].as_array_mut() {
                arr.push(node);
                rescued += 1;
            }
        }
    }
    let asset_guard = if rescued > 0 {
        format!("两端附件引用已取并集保护（补全保留 {rescued} 项，0 项丢失）")
    } else {
        "两端附件引用已取并集保护（0 项丢失）".into()
    };

    // 4. Body & Markdown section comparison (C1 disjoint sections vs C3 overlap).
    let w_note = winner["note"].as_str().unwrap_or("");
    let l_note = loser["note"].as_str().unwrap_or("");
    let w_doc = &winner["noteDocument"];
    let l_doc = &loser["noteDocument"];
    if w_note == l_note && w_doc == l_doc {
        return MergedNote {
            item: merged,
            has_overlap: false,
            conflict_section: String::new(),
            auto_merged,
            asset_guard,
        };
    }

    let w_secs = split_md_sections(w_note);
    let l_secs = split_md_sections(l_note);
    let b_secs = base
        .and_then(|v| v["note"].as_str())
        .map(split_md_sections)
        .unwrap_or_default();
    let w_map: BTreeMap<&str, &str> = w_secs
        .iter()
        .map(|(h, b)| (h.as_str(), b.as_str()))
        .collect();
    let l_map: BTreeMap<&str, &str> = l_secs
        .iter()
        .map(|(h, b)| (h.as_str(), b.as_str()))
        .collect();
    let b_map: BTreeMap<&str, &str> = b_secs
        .iter()
        .map(|(h, b)| (h.as_str(), b.as_str()))
        .collect();

    let has_headings =
        w_secs.iter().any(|(h, _)| !h.is_empty()) || l_secs.iter().any(|(h, _)| !h.is_empty());

    if has_headings {
        let mut order: Vec<&str> = Vec::new();
        for (h, _) in &w_secs {
            if !order.contains(&h.as_str()) {
                order.push(h.as_str());
            }
        }
        for (h, _) in &l_secs {
            if !order.contains(&h.as_str()) {
                order.push(h.as_str());
            }
        }
        let mut merged_sections: Vec<(String, String)> = Vec::new();
        let mut merged_count = 0usize;
        let mut overlap: Option<String> = None;
        for h in &order {
            let w_val = w_map.get(*h).copied();
            let l_val = l_map.get(*h).copied();
            let b_val = b_map.get(*h).copied();
            if w_val == l_val {
                if let Some(body) = w_val {
                    merged_sections.push(((*h).to_owned(), body.to_owned()));
                }
            } else if b_val.is_some() && w_val == b_val {
                if let Some(body) = l_val {
                    merged_sections.push(((*h).to_owned(), body.to_owned()));
                    merged_count += 1;
                }
            } else if b_val.is_some() && l_val == b_val {
                if let Some(body) = w_val {
                    merged_sections.push(((*h).to_owned(), body.to_owned()));
                    merged_count += 1;
                }
            } else if b_val.is_none() && w_val.is_none() {
                if let Some(body) = l_val {
                    merged_sections.push(((*h).to_owned(), body.to_owned()));
                    merged_count += 1;
                }
            } else if b_val.is_none() && l_val.is_none() {
                if let Some(body) = w_val {
                    merged_sections.push(((*h).to_owned(), body.to_owned()));
                    merged_count += 1;
                }
            } else {
                overlap = Some(if h.is_empty() {
                    "开头段落".into()
                } else {
                    (*h).to_owned()
                });
                break;
            }
        }
        if overlap.is_none() && merged_count > 0 {
            let mut combined = String::new();
            for (h, b) in &merged_sections {
                if !combined.is_empty() {
                    combined.push_str("\n\n");
                }
                if !h.is_empty() {
                    combined.push_str(h);
                    if !b.trim().is_empty() {
                        combined.push('\n');
                        combined.push_str(b.trim());
                    }
                } else {
                    combined.push_str(b.trim());
                }
            }
            merged["note"] = json!(combined);
            if let Some(arr) = merged["noteDocument"]["content"].as_array_mut() {
                for (h, b) in &l_secs {
                    if !h.is_empty() && !w_map.contains_key(h.as_str()) {
                        let title = h.trim_start_matches('#').trim();
                        arr.push(json!({"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":title}]}));
                        for line in b.lines().filter(|l| !l.trim().is_empty()) {
                            arr.push(
                                json!({"type":"paragraph","content":[{"type":"text","text":line}]}),
                            );
                        }
                    }
                }
            }
            auto_merged.push(format!("非重叠章节自动合并（{merged_count} 处）"));
            return MergedNote {
                item: merged,
                has_overlap: false,
                conflict_section: String::new(),
                auto_merged,
                asset_guard,
            };
        }
        let conflict_section = overlap
            .or_else(|| {
                w_secs
                    .first()
                    .map(|(h, _)| h.clone())
                    .filter(|h| !h.is_empty())
            })
            .unwrap_or_else(|| "正文段落".into());
        return MergedNote {
            item: merged,
            has_overlap: true,
            conflict_section,
            auto_merged,
            asset_guard,
        };
    }

    MergedNote {
        item: merged,
        has_overlap: true,
        conflict_section: "正文段落".into(),
        auto_merged,
        asset_guard,
    }
}
