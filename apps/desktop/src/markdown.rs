//! Stateless Markdown conversion; only a verified round trip permits rich-note edits.
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use comrak::{
    Arena, Options,
    nodes::{AstNode, ListType, NodeValue},
    parse_document,
};
use nsh_core::prelude::*;
use serde_json::{Value, json};

const LIMIT: usize = 8 * 1024 * 1024;
fn options() -> Options<'static> {
    let mut o = Options::default();
    o.extension.table = true;
    o.extension.tasklist = true;
    o.extension.strikethrough = true;
    o.extension.autolink = true;
    o
}
fn text(s: impl Into<String>) -> Value {
    json!({"type":"text","text":s.into()})
}
fn node(t: &str, content: Vec<Value>) -> Value {
    json!({"type":t,"content":content})
}
fn children<'a>(n: &'a AstNode<'a>) -> Vec<Value> {
    n.children().flat_map(convert).collect()
}
fn marked(mut content: Vec<Value>, mark: Value) -> Vec<Value> {
    for n in &mut content {
        if n["type"] == "text" {
            let obj = n.as_object_mut().unwrap();
            obj.entry("marks")
                .or_insert(json!([]))
                .as_array_mut()
                .unwrap()
                .push(mark.clone());
        }
    }
    content
}
fn attachment(url: &str, title: &str, label: &str, is_image: bool) -> Option<Value> {
    if let Some(id) = url.strip_prefix("pv-attachment://") {
        let bytes = URL_SAFE_NO_PAD
            .decode(title.strip_prefix("pv-meta:")?)
            .ok()?;
        let n: Value = serde_json::from_slice(&bytes).ok()?;
        if !matches!(n["type"].as_str(), Some("vaultImage" | "vaultAttachment"))
            || n["attrs"]["attachmentId"].as_str() != Some(id)
        {
            return None;
        }
        return Some(n);
    }
    if let Some(id) = url.strip_prefix("pv-asset://") {
        let id = id.trim();
        if id.is_empty() || id.len() > 128 || id.chars().any(char::is_control) {
            return None;
        }
        let name = if label.trim().is_empty() {
            "attachment"
        } else {
            label.trim()
        };
        return Some(if is_image {
            json!({
                "type": "vaultImage",
                "attrs": { "attachmentId": id, "name": name, "mime": "image/png", "width": 600, "caption": "" }
            })
        } else {
            json!({
                "type": "vaultAttachment",
                "attrs": { "attachmentId": id, "name": name, "mime": "application/octet-stream", "size": 0 }
            })
        });
    }
    None
}
fn convert<'a>(n: &'a AstNode<'a>) -> Vec<Value> {
    let data = n.data.borrow();
    let value = match &data.value {
        NodeValue::Document => node("doc", children(n)),
        NodeValue::Paragraph => {
            let c = children(n);
            // Vault attachments are block atoms in Tiptap, even though Markdown uses inline syntax.
            let mut out = vec![];
            let mut inline = vec![];
            for child in c {
                if matches!(
                    child["type"].as_str(),
                    Some("vaultImage" | "vaultAttachment")
                ) {
                    if !inline.is_empty() {
                        out.push(node("paragraph", std::mem::take(&mut inline)));
                    }
                    out.push(child);
                } else {
                    inline.push(child);
                }
            }
            if !inline.is_empty() || out.is_empty() {
                out.push(node("paragraph", inline));
            }
            return out;
        }
        NodeValue::Heading(h) => {
            let mut v = node("heading", children(n));
            v["attrs"] = json!({"level":h.level});
            v
        }
        NodeValue::BlockQuote => node("blockquote", children(n)),
        NodeValue::List(l) => {
            let mut c = children(n);
            let task = c.iter().any(|v| v["type"] == "taskItem");
            if task {
                for item in &mut c {
                    if item["type"] == "listItem" {
                        item["type"] = json!("taskItem");
                        item["attrs"] = json!({"checked":false});
                    }
                }
            }
            let mut v = node(
                if task {
                    "taskList"
                } else if l.list_type == ListType::Ordered {
                    "orderedList"
                } else {
                    "bulletList"
                },
                c,
            );
            if l.list_type == ListType::Ordered && !task {
                v["attrs"] = json!({"start":l.start});
            }
            v
        }
        NodeValue::Item(_) => node("listItem", children(n)),
        NodeValue::TaskItem(check) => {
            let mut v = node("taskItem", children(n));
            v["attrs"] = json!({"checked":check.is_some()});
            v
        }
        NodeValue::CodeBlock(c) => {
            let literal = c.literal.strip_suffix('\n').unwrap_or(&c.literal);
            let mut v = node(
                "codeBlock",
                if literal.is_empty() {
                    vec![]
                } else {
                    vec![text(literal)]
                },
            );
            v["attrs"] =
                json!({"language":if c.info.is_empty() { Value::Null } else { json!(c.info) }});
            v
        }
        NodeValue::ThematicBreak => json!({"type":"horizontalRule"}),
        NodeValue::Table(table) => {
            let mut rows = children(n);
            for row in &mut rows {
                for (i, cell) in row["content"]
                    .as_array_mut()
                    .unwrap()
                    .iter_mut()
                    .enumerate()
                {
                    if let Some(alignment) = table.alignments.get(i).and_then(|a| match a {
                        comrak::nodes::TableAlignment::Left => Some("left"),
                        comrak::nodes::TableAlignment::Right => Some("right"),
                        comrak::nodes::TableAlignment::Center => Some("center"),
                        _ => None,
                    }) {
                        cell["content"][0]["attrs"] = json!({"textAlign":alignment});
                    }
                }
            }
            node("table", rows)
        }
        NodeValue::TableRow(header) => node(
            "tableRow",
            n.children()
                .map(|cell| {
                    let mut v = node(
                        if *header { "tableHeader" } else { "tableCell" },
                        vec![node("paragraph", children(cell))],
                    );
                    v["attrs"] = json!({"colspan":1,"rowspan":1,"colwidth":null});
                    v
                })
                .collect(),
        ),
        NodeValue::Text(t) => text(t.to_string()),
        NodeValue::SoftBreak => text("\n"),
        NodeValue::LineBreak => json!({"type":"hardBreak"}),
        NodeValue::Code(c) => return marked(vec![text(c.literal.clone())], json!({"type":"code"})),
        NodeValue::Strong => return marked(children(n), json!({"type":"bold"})),
        NodeValue::Emph => return marked(children(n), json!({"type":"italic"})),
        NodeValue::Strikethrough => return marked(children(n), json!({"type":"strike"})),
        NodeValue::Link(l) | NodeValue::Image(l) => {
            let is_image = matches!(&data.value, NodeValue::Image(_));
            let label = children(n).iter().map(plain).collect::<String>();
            if let Some(a) = attachment(&l.url, &l.title, &label, is_image) {
                a
            } else if is_image {
                text(format!("![{label}]({})", l.url))
            } else {
                if !l.title.is_empty() {
                    return vec![text(format!("[{label}]({} \"{}\")", l.url, l.title))];
                }
                let attrs = json!({"href":l.url});
                return marked(children(n), json!({"type":"link", "attrs":attrs}));
            }
        }
        NodeValue::HtmlBlock(h) => node("paragraph", vec![text(h.literal.clone())]),
        NodeValue::HtmlInline(h) => text(h.clone()),
        _ => return children(n),
    };
    vec![value]
}
fn try_parse(source: &str) -> Result<Value, String> {
    let arena = Arena::new();
    let o = options();
    let root = parse_document(&arena, source, &o);
    let mut stack = vec![(root, 0usize)];
    let mut count = 0;
    while let Some((n, depth)) = stack.pop() {
        count += 1;
        if depth > 128 || count > 200_000 {
            return Err("NoteTooComplex".into());
        }
        stack.extend(n.children().map(|c| (c, depth + 1)));
    }
    let mut doc = convert(root).remove(0);
    if doc["content"].as_array().is_some_and(Vec::is_empty) {
        doc["content"] = json!([{"type":"paragraph"}]);
    }
    Ok(doc)
}
#[cfg(test)]
fn parse(source: &str) -> Value {
    try_parse(source).unwrap()
}
fn content(n: &Value) -> &[Value] {
    n["content"].as_array().map(Vec::as_slice).unwrap_or(&[])
}
fn plain(n: &Value) -> String {
    match n["type"].as_str().unwrap_or("") {
        "text" => n["text"].as_str().unwrap_or("").into(),
        "hardBreak" => "\n".into(),
        "vaultImage" | "vaultAttachment" => n["attrs"]["caption"]
            .as_str()
            .filter(|s| !s.is_empty())
            .or(n["attrs"]["name"].as_str())
            .unwrap_or("")
            .into(),
        "paragraph" | "heading" | "codeBlock" => content(n).iter().map(plain).collect(),
        _ => content(n).iter().map(plain).collect::<Vec<_>>().join("\n"),
    }
}
fn escape(s: &str) -> String {
    s.chars()
        .flat_map(|c| {
            if c.is_ascii_punctuation() {
                vec!['\\', c]
            } else {
                vec![c]
            }
        })
        .collect()
}
fn code(s: &str) -> String {
    let fence = "`".repeat(s.split(|c| c != '`').map(str::len).max().unwrap_or(0) + 1);
    format!("{fence} {s} {fence}")
}
fn url(s: &str) -> String {
    s.replace('<', "%3C")
        .replace('>', "%3E")
        .replace('\n', "%0A")
}
/// Markdown strips line-edge whitespace; encode it as entities so it survives a round trip.
fn protect_edges(s: &str) -> String {
    let ent = |c: char| {
        if c == '\t' {
            "&#9;".to_string()
        } else {
            "&#32;".to_string()
        }
    };
    s.split('\n')
        .map(|line| {
            let body = line.trim_matches([' ', '\t']);
            if body.is_empty() {
                return line.chars().map(ent).collect::<String>();
            }
            let start = line.len() - line.trim_start_matches([' ', '\t']).len();
            let end = line.trim_end_matches([' ', '\t']).len();
            format!(
                "{}{}{}",
                line[..start].chars().map(ent).collect::<String>(),
                &line[start..end],
                line[end..].chars().map(ent).collect::<String>()
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}
/// Hard breaks at a paragraph edge have no Markdown form; they are not significant.
fn trimmed(n: &Value) -> &[Value] {
    let mut c = content(n);
    while c.first().is_some_and(|v| v["type"] == "hardBreak") {
        c = &c[1..];
    }
    while c.last().is_some_and(|v| v["type"] == "hardBreak") {
        c = &c[..c.len() - 1];
    }
    c
}
fn inline(n: &Value) -> String {
    if n["type"] == "hardBreak" {
        return "\\\n".into();
    }
    if n["type"] != "text" {
        return escape(&plain(n));
    }
    let raw = n["text"].as_str().unwrap_or("");
    let mut out = escape(raw);
    let marks = n["marks"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    if marks.iter().any(|m| m["type"] == "code") {
        out = code(raw);
    }
    for mark in marks {
        out = match mark["type"].as_str().unwrap_or("") {
            "bold" => format!("**{out}**"),
            "italic" => format!("*{out}*"),
            "strike" => format!("~~{out}~~"),
            "link" => {
                let title = mark["attrs"]["title"]
                    .as_str()
                    .filter(|t| !t.is_empty())
                    .map(|t| format!(" \"{}\"", t.replace('\\', "\\\\").replace('"', "\\\"")))
                    .unwrap_or_default();
                format!(
                    "[{out}](<{}>{title})",
                    url(mark["attrs"]["href"].as_str().unwrap_or(""))
                )
            }
            _ => out,
        };
    }
    out
}
fn render(n: &Value) -> String {
    let children = || {
        content(n)
            .iter()
            .map(render)
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("\n\n")
    };
    let inlines = || protect_edges(&trimmed(n).iter().map(inline).collect::<String>());
    match n["type"].as_str().unwrap_or("") {
        "doc" | "listItem" | "taskItem" => children(),
        "paragraph" => inlines(),
        "heading" => format!(
            "{} {}",
            "#".repeat(n["attrs"]["level"].as_u64().unwrap_or(1).clamp(1, 6) as usize),
            inlines()
        ),
        "blockquote" => children()
            .lines()
            .map(|l| format!("> {l}"))
            .collect::<Vec<_>>()
            .join("\n"),
        "bulletList" | "orderedList" | "taskList" => content(n)
            .iter()
            .enumerate()
            .map(|(i, item)| {
                let prefix = if n["type"] == "orderedList" {
                    format!("{}. ", n["attrs"]["start"].as_u64().unwrap_or(1) + i as u64)
                } else if n["type"] == "taskList" {
                    format!(
                        "- [{}] ",
                        if item["attrs"]["checked"] == true {
                            "x"
                        } else {
                            " "
                        }
                    )
                } else {
                    "- ".into()
                };
                let body = render(item);
                let mut lines = body.split('\n');
                format!(
                    "{prefix}{}{}",
                    lines.next().unwrap_or(""),
                    lines
                        .map(|l| format!(
                            "\n{}{}",
                            " ".repeat(if n["type"] == "taskList" {
                                2
                            } else {
                                prefix.len()
                            }),
                            l
                        ))
                        .collect::<String>()
                )
            })
            .collect::<Vec<_>>()
            .join("\n\n"),
        "codeBlock" => {
            let body = plain(n);
            let fence =
                "`".repeat(3.max(body.split(|c| c != '`').map(str::len).max().unwrap_or(0) + 1));
            format!(
                "{fence}{}\n{body}\n{fence}",
                n["attrs"]["language"].as_str().unwrap_or("")
            )
        }
        "horizontalRule" => "---".into(),
        "table" => {
            let mut rows = vec![];
            for (i, row) in content(n).iter().enumerate() {
                rows.push(format!(
                    "| {} |",
                    content(row)
                        .iter()
                        .map(|cell| content(cell)
                            .iter()
                            .map(|p| protect_edges(
                                &trimmed(p).iter().map(inline).collect::<String>()
                            ))
                            .collect::<Vec<_>>()
                            .join(" ")
                            .replace('\n', " "))
                        .collect::<Vec<_>>()
                        .join(" | ")
                ));
                if i == 0 {
                    rows.push(format!(
                        "| {} |",
                        vec!["---"; content(row).len()].join(" | ")
                    ));
                }
            }
            rows.join("\n")
        }
        "vaultImage" | "vaultAttachment" => {
            let meta = URL_SAFE_NO_PAD.encode(n.to_string());
            format!(
                "{}[{}](pv-attachment://{} \"pv-meta:{meta}\")",
                if n["type"] == "vaultImage" { "!" } else { "" },
                escape(n["attrs"]["name"].as_str().unwrap_or("")),
                n["attrs"]["attachmentId"].as_str().unwrap_or("")
            )
        }
        _ => escape(&plain(n)),
    }
}
/// Normalize only schema defaults, mark ordering and equivalent adjacent text spans.
fn normalize(n: &Value) -> Value {
    let mut v = n.clone();
    let kind = n["type"].as_str().unwrap_or("");
    if let Some(attrs) = v.get_mut("attrs").and_then(Value::as_object_mut) {
        let defaults: &[(&str, Value)] = match kind {
            "paragraph" | "heading" => &[("textAlign", Value::Null)],
            "orderedList" => &[("start", json!(1)), ("type", Value::Null)],
            "codeBlock" => &[("language", Value::Null)],
            "tableCell" | "tableHeader" => &[
                ("colspan", json!(1)),
                ("rowspan", json!(1)),
                ("colwidth", Value::Null),
            ],
            "link" => &[
                ("target", json!("_blank")),
                ("rel", json!("noopener noreferrer nofollow")),
                ("class", Value::Null),
                ("title", Value::Null),
            ],
            "textStyle" => &[("color", Value::Null)],
            _ => &[],
        };
        for (k, default) in defaults {
            if attrs.get(*k) == Some(default) {
                attrs.remove(*k);
            }
        }
        if attrs.is_empty() {
            v.as_object_mut().unwrap().remove("attrs");
        }
    }
    if let Some(marks) = n["marks"].as_array() {
        // An empty textStyle (all attributes null) carries no formatting.
        let blank_style = |m: &Value| m["type"] == "textStyle" && m.get("attrs").is_none();
        let mut m: Vec<_> = marks
            .iter()
            .map(normalize)
            .filter(|m| !blank_style(m))
            .collect();
        m.sort_by_key(Value::to_string);
        if m.is_empty() {
            v.as_object_mut().unwrap().remove("marks");
        } else {
            v["marks"] = json!(m);
        }
    }
    if let Some(children) = n["content"].as_array() {
        let mut out: Vec<Value> = vec![];
        let children: &[Value] = if matches!(kind, "paragraph" | "heading") {
            trimmed(n)
        } else {
            children
        };
        // Blank paragraphs are spacing only; Markdown collapses them.
        let empty = |c: &Value| {
            c["type"] == "paragraph" && c.get("content").is_none() && c.get("attrs").is_none()
        };
        for child in children.iter().map(normalize).filter(|c| !empty(c)) {
            if let Some(last) = out.last_mut() {
                let mut a = last.clone();
                let mut b = child.clone();
                if child["type"] == "text" && last["type"] == "text" {
                    a.as_object_mut().unwrap().remove("text");
                    b.as_object_mut().unwrap().remove("text");
                    if a == b {
                        last["text"] = json!(format!(
                            "{}{}",
                            last["text"].as_str().unwrap_or(""),
                            child["text"].as_str().unwrap_or("")
                        ));
                        continue;
                    }
                }
            }
            out.push(child);
        }
        if out.is_empty() && kind == "doc" {
            v["content"] = json!([{"type":"paragraph"}]);
        } else if out.is_empty() {
            v.as_object_mut().unwrap().remove("content");
        } else {
            v["content"] = json!(out);
        }
    }
    v
}
// Atom metadata is retained, but unknown schema fields still close the edit gate.
fn supported_atoms(n: &Value) -> bool {
    if matches!(n["type"].as_str(), Some("vaultImage" | "vaultAttachment")) {
        let keys: &[&str] = if n["type"] == "vaultImage" {
            &["attachmentId", "name", "mime", "width", "caption"]
        } else {
            &["attachmentId", "name", "mime", "size"]
        };
        if n.as_object()
            .is_none_or(|o| o.keys().any(|k| k != "type" && k != "attrs"))
            || n["attrs"]
                .as_object()
                .is_none_or(|o| o.keys().any(|k| !keys.contains(&k.as_str())))
        {
            return false;
        }
    }
    content(n).iter().all(supported_atoms)
}
fn to_markdown(source: &str) -> Result<Value, String> {
    if source.len() > LIMIT {
        return Err("NoteTooLarge".into());
    }
    let doc: Value = serde_json::from_str(source).map_err(|_| "InvalidData")?;
    if doc["type"] != "doc" {
        return Err("InvalidData".into());
    }
    let markdown = render(&doc);
    let restored = try_parse(&markdown)?;
    Ok(
        json!({"markdown":markdown,"lossless":supported_atoms(&doc) && normalize(&doc) == normalize(&restored)}),
    )
}
fn html_page(markdown: &str, title: &str) -> String {
    let body = comrak::markdown_to_html(markdown, &options());
    let title = title
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;");
    format!(
        "<!doctype html>\n<html lang=\"zh-CN\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n<title>{title}</title>\n<style>body{{max-width:760px;margin:40px auto;padding:0 20px;font:16px/1.7 -apple-system,\"PingFang SC\",\"Segoe UI\",sans-serif;color:#242a35}}pre,code{{font-family:\"SF Mono\",Menlo,Consolas,monospace}}pre{{background:#f3f5f8;padding:12px;border-radius:8px;overflow:auto}}table{{border-collapse:collapse}}td,th{{border:1px solid #e4e8ef;padding:6px 10px}}</style>\n</head>\n<body>\n<h1>{title}</h1>\n{body}</body>\n</html>\n"
    )
}

fn readable_inline(n: &Value, in_table: bool) -> String {
    if n["type"] == "hardBreak" {
        return if in_table { " ".into() } else { "  \n".into() };
    }
    if n["type"] != "text" {
        return readable_block(n);
    }
    let raw = n["text"].as_str().unwrap_or("");
    let marks = n["marks"].as_array();
    if marks.is_some_and(|m| m.iter().any(|x| x["type"] == "code")) {
        return code(raw);
    }
    let mut out = if in_table {
        raw.replace('|', "\\|")
    } else {
        raw.to_owned()
    };
    for mark in marks.into_iter().flatten() {
        match mark["type"].as_str().unwrap_or("") {
            "bold" => out = format!("**{out}**"),
            "italic" => out = format!("*{out}*"),
            "strike" => out = format!("~~{out}~~"),
            "link" => {
                let href = mark["attrs"]["href"].as_str().unwrap_or("");
                if !href.is_empty() {
                    out = format!("[{out}]({href})");
                }
            }
            _ => {}
        }
    }
    out
}

fn readable_inlines(n: &Value, in_table: bool) -> String {
    content(n)
        .iter()
        .map(|c| readable_inline(c, in_table))
        .collect()
}

fn prefix_item(prefix: &str, body: &str) -> String {
    let indent = if prefix.starts_with("- [") {
        "  ".to_owned()
    } else {
        " ".repeat(prefix.len())
    };
    let mut lines = body.split('\n');
    format!(
        "{prefix}{}{}",
        lines.next().unwrap_or(""),
        lines
            .map(|l| if l.is_empty() {
                "\n".to_owned()
            } else {
                format!("\n{indent}{l}")
            })
            .collect::<String>()
    )
}

fn readable_block(n: &Value) -> String {
    let join_children = || {
        content(n)
            .iter()
            .map(readable_block)
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("\n\n")
    };
    match n["type"].as_str().unwrap_or("") {
        "doc" | "listItem" | "taskItem" => join_children(),
        "paragraph" => readable_inlines(n, false),
        "heading" => format!(
            "{} {}",
            "#".repeat(n["attrs"]["level"].as_u64().unwrap_or(1).clamp(1, 6) as usize),
            readable_inlines(n, false)
        ),
        "blockquote" => join_children()
            .lines()
            .map(|l| {
                if l.is_empty() {
                    ">".into()
                } else {
                    format!("> {l}")
                }
            })
            .collect::<Vec<_>>()
            .join("\n"),
        "bulletList" => content(n)
            .iter()
            .map(|it| prefix_item("- ", &readable_block(it)))
            .collect::<Vec<_>>()
            .join("\n"),
        "orderedList" => {
            let start = n["attrs"]["start"].as_u64().unwrap_or(1);
            content(n)
                .iter()
                .enumerate()
                .map(|(i, it)| prefix_item(&format!("{}. ", start + i as u64), &readable_block(it)))
                .collect::<Vec<_>>()
                .join("\n")
        }
        "taskList" => content(n)
            .iter()
            .map(|it| {
                let mark = if it["attrs"]["checked"] == true {
                    "- [x] "
                } else {
                    "- [ ] "
                };
                prefix_item(mark, &readable_block(it))
            })
            .collect::<Vec<_>>()
            .join("\n"),
        "codeBlock" => {
            let lang = n["attrs"]["language"].as_str().unwrap_or("");
            let body: String = content(n)
                .iter()
                .map(|c| c["text"].as_str().unwrap_or(""))
                .collect();
            let fence = "`".repeat(
                body.split(|c| c != '`')
                    .map(str::len)
                    .max()
                    .unwrap_or(0)
                    .max(2)
                    + 1,
            );
            format!("{fence}{lang}\n{body}\n{fence}")
        }
        "horizontalRule" => "---".into(),
        "table" => {
            let rows: Vec<Vec<String>> = content(n)
                .iter()
                .map(|row| {
                    content(row)
                        .iter()
                        .map(|cell| {
                            content(cell)
                                .iter()
                                .map(|c| readable_inlines(c, true))
                                .collect::<Vec<_>>()
                                .join(" ")
                                .replace('\n', " ")
                        })
                        .collect()
                })
                .collect();
            let Some(head) = rows.first() else {
                return String::new();
            };
            let line = |r: &[String]| format!("| {} |", r.join(" | "));
            let sep = format!("| {} |", vec!["---"; head.len()].join(" | "));
            let mut out = vec![line(head), sep];
            for row in rows.iter().skip(1) {
                out.push(line(row));
            }
            out.join("\n")
        }
        "vaultImage" | "vaultAttachment" => {
            let id = n["attrs"]["attachmentId"].as_str().unwrap_or("");
            let name = n["attrs"]["name"].as_str().unwrap_or("attachment");
            let bang = if n["type"] == "vaultImage" { "!" } else { "" };
            format!("{bang}[{name}](pv-asset://{id})")
        }
        _ => plain(n),
    }
}

fn collect_attachment_nodes(node: &Value, map: &mut std::collections::HashMap<String, Value>) {
    if matches!(
        node["type"].as_str(),
        Some("vaultImage" | "vaultAttachment")
    ) {
        if let Some(id) = node["attrs"]["attachmentId"].as_str() {
            map.insert(id.to_owned(), node.clone());
        }
    }
    if let Some(arr) = node["content"].as_array() {
        for c in arr {
            collect_attachment_nodes(c, map);
        }
    }
}

fn apply_attachment_attrs(
    node: &mut Value,
    known: &std::collections::HashMap<String, Value>,
    metas: &std::collections::HashMap<String, Value>,
) {
    if matches!(
        node["type"].as_str(),
        Some("vaultImage" | "vaultAttachment")
    ) {
        if let Some(id) = node["attrs"]["attachmentId"].as_str().map(str::to_owned) {
            if let Some(prev) = known.get(&id) {
                *node = prev.clone();
                return;
            }
            if let Some(meta) = metas.get(&id) {
                let mime = meta["mime"].as_str().unwrap_or("application/octet-stream");
                let name = meta["name"]
                    .as_str()
                    .or_else(|| node["attrs"]["name"].as_str())
                    .unwrap_or("attachment");
                let size = meta["size"].as_u64().unwrap_or(0);
                if mime.starts_with("image/") {
                    *node = json!({
                        "type": "vaultImage",
                        "attrs": { "attachmentId": id, "name": name, "mime": mime, "width": 600, "caption": "" }
                    });
                } else {
                    *node = json!({
                        "type": "vaultAttachment",
                        "attrs": { "attachmentId": id, "name": name, "mime": mime, "size": size }
                    });
                }
                return;
            }
        }
    }
    if let Some(arr) = node["content"].as_array_mut() {
        for c in arr {
            apply_attachment_attrs(c, known, metas);
        }
    }
}

pub(crate) fn hydrate_attachment_nodes(
    doc: &mut Value,
    previous_doc: Option<&Value>,
    attachment_metas: &[Value],
) {
    let mut known = std::collections::HashMap::new();
    if let Some(prev) = previous_doc {
        collect_attachment_nodes(prev, &mut known);
    }
    let mut metas = std::collections::HashMap::new();
    for m in attachment_metas {
        if let Some(id) = m["id"].as_str() {
            metas.insert(id.to_owned(), m.clone());
        }
    }
    if !known.is_empty() || !metas.is_empty() {
        apply_attachment_attrs(doc, &known, &metas);
    }
}

pub(crate) fn item_to_markdown(item: &Value) -> String {
    if item["noteFormat"] == "rich-v1" && item["noteDocument"]["type"] == "doc" {
        return readable_block(&item["noteDocument"]);
    }
    item["note"].as_str().unwrap_or("").to_owned()
}

pub(crate) fn parse_markdown_patch(markdown: &str) -> Result<(String, Value), String> {
    if markdown.len() > LIMIT {
        return Err("NoteTooLarge".into());
    }
    let doc = try_parse(markdown)?;
    Ok((plain(&doc), doc))
}

fn parse_heading_line(line: &str) -> Option<(usize, &str)> {
    let trimmed = line.trim_start();
    let hashes = trimmed.bytes().take_while(|b| *b == b'#').count();
    if !(1..=6).contains(&hashes) {
        return None;
    }
    let rest = trimmed.get(hashes..)?;
    if !rest.starts_with(' ') && !rest.starts_with('\t') {
        return None;
    }
    Some((hashes, rest.trim().trim_end_matches('#').trim()))
}

fn find_section_bounds(lines: &[&str], heading: &str) -> Option<(usize, usize, usize)> {
    let target = heading.trim().trim_start_matches('#').trim().to_lowercase();
    if target.is_empty() {
        return None;
    }
    let mut in_fence = false;
    let mut start = None;
    let mut level = 0;
    for (idx, line) in lines.iter().enumerate() {
        let trimmed = line.trim_start();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            in_fence = !in_fence;
            continue;
        }
        if in_fence {
            continue;
        }
        if let Some((lvl, text)) = parse_heading_line(line) {
            if let Some(s) = start {
                if lvl <= level {
                    return Some((s, idx, level));
                }
            } else if text.to_lowercase() == target {
                start = Some(idx);
                level = lvl;
            }
        }
    }
    start.map(|s| (s, lines.len(), level))
}

pub(crate) fn extract_section(markdown: &str, heading: &str) -> Option<String> {
    let lines: Vec<&str> = markdown.lines().collect();
    let (start, end, _) = find_section_bounds(&lines, heading)?;
    Some(lines[start..end].join("\n").trim_end().to_owned())
}

pub(crate) fn replace_section(
    markdown: &str,
    heading: &str,
    replacement: &str,
) -> Result<String, String> {
    let lines: Vec<&str> = markdown.lines().collect();
    let (start, end, level) =
        find_section_bounds(&lines, heading).ok_or_else(|| "SectionNotFound".to_string())?;
    let body = replacement.trim();
    let has_own_heading = body
        .lines()
        .next()
        .and_then(parse_heading_line)
        .is_some_and(|(_, t)| {
            t.eq_ignore_ascii_case(heading.trim().trim_start_matches('#').trim())
        });
    let mut out = Vec::new();
    out.extend(lines[..start].iter().copied().map(str::to_owned));
    if has_own_heading {
        out.push(body.to_owned());
    } else {
        out.push(format!(
            "{} {}",
            "#".repeat(level),
            heading.trim().trim_start_matches('#').trim()
        ));
        if !body.is_empty() {
            out.push(String::new());
            out.push(body.to_owned());
        }
    }
    if end < lines.len() {
        out.push(String::new());
        out.extend(lines[end..].iter().copied().map(str::to_owned));
    }
    Ok(out.join("\n").trim_end().to_owned())
}

pub(crate) fn append_markdown(
    markdown: &str,
    section: Option<&str>,
    addition: &str,
) -> Result<String, String> {
    let add = addition.trim();
    if add.is_empty() {
        return Err("EmptyContent".into());
    }
    let Some(heading) = section.map(str::trim).filter(|s| !s.is_empty()) else {
        let base = markdown.trim_end();
        if base.is_empty() {
            return Ok(add.to_owned());
        }
        let table_join = base
            .lines()
            .last()
            .is_some_and(|l| l.trim_start().starts_with('|'))
            && add.starts_with('|');
        return Ok(format!(
            "{base}{}{add}",
            if table_join { "\n" } else { "\n\n" }
        ));
    };
    let lines: Vec<&str> = markdown.lines().collect();
    let Some((_, end, _)) = find_section_bounds(&lines, heading) else {
        let clean_heading = heading.trim_start_matches('#').trim();
        let base = markdown.trim_end();
        return Ok(if base.is_empty() {
            format!("## {clean_heading}\n\n{add}")
        } else {
            format!("{base}\n\n## {clean_heading}\n\n{add}")
        });
    };
    let mut insert_at = end;
    while insert_at > 0 && lines[insert_at - 1].trim().is_empty() {
        insert_at -= 1;
    }
    let prev_line = if insert_at > 0 {
        lines[insert_at - 1]
    } else {
        ""
    };
    let tight_join = (prev_line.trim_start().starts_with('|') && add.starts_with('|'))
        || (prev_line.trim_start().starts_with("- ") && add.starts_with("- "));
    let mut out = Vec::new();
    out.extend(lines[..insert_at].iter().copied().map(str::to_owned));
    if !tight_join {
        out.push(String::new());
    }
    out.push(add.to_owned());
    if end < lines.len() {
        out.push(String::new());
        out.extend(lines[end..].iter().copied().map(str::to_owned));
    }
    Ok(out.join("\n").trim_end().to_owned())
}

/// Markdown conversion for the lightweight native note editor. No network or file access.
#[module]
pub struct NoteMarkdown;
#[module]
impl NoteMarkdown {
    /// Returns JSON {markdown,lossless}. A false gate must never be edited/saved.
    pub fn to_markdown(note_document_json: String) -> Result<String, String> {
        to_markdown(&note_document_json).map(|v| v.to_string())
    }
    /// Returns human- and Agent-readable GFM Markdown without punctuation backslash escapes.
    pub fn to_readable_markdown(note_document_json: String) -> Result<String, String> {
        if note_document_json.len() > LIMIT {
            return Err("NoteTooLarge".into());
        }
        let doc: Value = serde_json::from_str(&note_document_json).map_err(|_| "InvalidData")?;
        if doc["type"] != "doc" {
            return Err("InvalidData".into());
        }
        Ok(readable_block(&doc))
    }
    /// A standalone HTML page for "save as HTML". Raw HTML in the source is omitted
    /// (comrak's safe default), so an export cannot carry scripts or embedded markup.
    pub fn to_html(markdown: String, title: String) -> Result<String, String> {
        if markdown.len() > LIMIT {
            return Err("NoteTooLarge".into());
        }
        Ok(html_page(&markdown, &title))
    }
    /// Parses GFM locally, returning JSON {noteDocument,text} for rich-v1 storage.
    pub fn from_markdown(markdown: String) -> Result<String, String> {
        if markdown.len() > LIMIT {
            return Err("NoteTooLarge".into());
        }
        let doc = try_parse(&markdown)?;
        Ok(json!({"text":plain(&doc),"noteDocument":doc}).to_string())
    }
    /// Parses GFM locally while preserving existing attachment attrs for clean `pv-asset://` links.
    pub fn from_markdown_preserving(
        markdown: String,
        previous_note_document_json: String,
    ) -> Result<String, String> {
        if markdown.len() > LIMIT {
            return Err("NoteTooLarge".into());
        }
        let mut doc = try_parse(&markdown)?;
        if let Ok(prev) = serde_json::from_str::<Value>(&previous_note_document_json) {
            hydrate_attachment_nodes(&mut doc, Some(&prev), &[]);
        }
        Ok(json!({"text":plain(&doc),"noteDocument":doc}).to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn html_export_escapes_the_title_and_drops_raw_html() {
        let page = html_page(
            "# 标题\n\n<script>alert(1)</script>\n\n**粗体**",
            "a<b>&\"c",
        );
        assert!(page.contains("<title>a&lt;b&gt;&amp;&quot;c</title>"));
        assert!(page.contains("<strong>粗体</strong>"));
        assert!(!page.contains("<script>"));
    }
    #[test]
    fn gfm_round_trip_corpus() {
        let cases = [
            "# 中文标题\n\n第一段 **粗体** 与 *斜体*、~~删除线~~。",
            "- parent\n  - nested\n    - deeper\n- sibling",
            "3. third\n4. fourth",
            "- [x] 完成\n- [ ] 未完成\n  - [ ] nested",
            "> quote\n>\n> - child\n> - child two",
            "```rust\nfn main() { println!(\"中文\"); }\n```",
            "| Header | Two |\n| --- | --- |\n| **one** | two |",
            "[link](https://example.test/path?q=1) and https://example.test",
            "line one\\\nline two\nsoft break",
            "**bold** *italic* ***both*** ~~strike~~ `code * literal`",
            "punctuation \\* \\_ \\[ \\] and 中文 😊",
            "---\n\nlast",
            "",
            "`` `inside` ``",
        ];
        for source in cases {
            let doc = parse(source);
            let encoded = to_markdown(&doc.to_string()).unwrap();
            assert_eq!(
                encoded["lossless"],
                true,
                "{source}\n{encoded}\n{doc}\n{}",
                parse(encoded["markdown"].as_str().unwrap())
            );
        }
    }
    #[test]
    fn attachment_attributes_round_trip_without_shared_state() {
        for kind in ["vaultImage", "vaultAttachment"] {
            let mut atom = json!({"type":kind,"attrs":{"attachmentId":"uuid-test","name":"中文 [image].png","mime":"image/png"}});
            if kind == "vaultImage" {
                atom["attrs"]["width"] = json!(480);
                atom["attrs"]["caption"] = json!("caption");
            } else {
                atom["attrs"]["size"] = json!(5);
            }
            let doc = node("doc", vec![atom]);
            let encoded = to_markdown(&doc.to_string()).unwrap();
            assert_eq!(encoded["lossless"], true);
            assert!(
                encoded["markdown"]
                    .as_str()
                    .unwrap()
                    .contains("pv-attachment://uuid-test")
            );
            assert_eq!(parse(encoded["markdown"].as_str().unwrap()), doc);
        }
    }
    #[test]
    fn lossy_features_are_never_authorized() {
        let base = parse("text");
        for mark in [
            json!({"type":"underline"}),
            json!({"type":"highlight","attrs":{"color":"#ff0000"}}),
            json!({"type":"textStyle","attrs":{"color":"#ff0000"}}),
            json!({"type":"future"}),
        ] {
            let mut doc = base.clone();
            doc["content"][0]["content"][0]["marks"] = json!([mark]);
            assert_eq!(to_markdown(&doc.to_string()).unwrap()["lossless"], false);
        }
        for attrs in [json!({"textAlign":"center"}), json!({"future":7})] {
            let mut doc = base.clone();
            doc["content"][0]["attrs"] = attrs;
            assert_eq!(to_markdown(&doc.to_string()).unwrap()["lossless"], false);
        }
        let mut doc = base.clone();
        doc["content"][0]["type"] = json!("futureNode");
        assert_eq!(to_markdown(&doc.to_string()).unwrap()["lossless"], false);
        let mut table = parse("| h |\n| - |\n| c |");
        table["content"][0]["content"][0]["content"][0]["attrs"]["colspan"] = json!(2);
        assert_eq!(to_markdown(&table.to_string()).unwrap()["lossless"], false);
    }
    #[test]
    fn unknown_attachment_attributes_close_gate() {
        let doc = json!({"type":"doc","content":[{"type":"vaultImage","attrs":{"attachmentId":"id","name":"image","future":"value"}}]});
        assert_eq!(to_markdown(&doc.to_string()).unwrap()["lossless"], false);
    }
    #[test]
    fn known_defaults_and_adjacent_spans_are_equivalent() {
        let a = json!({"type":"doc","content":[{"type":"paragraph","attrs":{"textAlign":null},"content":[{"type":"text","text":"a"},{"type":"text","text":"b","marks":[]}]}]});
        assert_eq!(to_markdown(&a.to_string()).unwrap()["lossless"], true);
        assert_eq!(
            plain(&parse("- [x] 中文\n\n```rs\ncode\n```")),
            "中文\ncode"
        );
    }
    #[test]
    fn malformed_and_remote_resources_do_not_become_vault_images() {
        assert!(to_markdown("{}").is_err());
        let doc = parse(
            "![remote](https://example.test/a.png)\n\n![bad](pv-attachment://id \"pv-meta:garbage\")\n\n<script>alert(1)</script>",
        );
        assert!(!doc.to_string().contains("vaultImage"));
        assert!(plain(&doc).contains("https://example.test/a.png"));
        assert!(plain(&doc).contains("<script>"));
    }
    #[test]
    fn legacy_editor_shapes_stay_editable() {
        let p = |t: &str| json!({"type":"paragraph","content":[{"type":"text","text":t}]});
        let cases = [
            json!({"type":"doc","content":[p("a"),{"type":"paragraph"},{"type":"paragraph","attrs":{"textAlign":null}},p("b"),{"type":"paragraph"}]}),
            json!({"type":"doc","content":[p("  indented"),p("trailing  "),p("\tTab"),p("a\n    b")]}),
            json!({"type":"doc","content":[{"type":"paragraph","content":[{"type":"hardBreak"},{"type":"text","text":"a"},{"type":"hardBreak"}]}]}),
            json!({"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"l","marks":[{"type":"link","attrs":{"href":"https://x.test","target":"_blank","rel":"noopener noreferrer nofollow","class":null,"title":null}}]}]}]}),
            json!({"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"s","marks":[{"type":"textStyle","attrs":{"color":null}}]}]}]}),
            json!({"type":"doc","content":[{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph"}]}]}]}),
        ];
        for doc in cases {
            let encoded = to_markdown(&doc.to_string()).unwrap();
            assert_eq!(encoded["lossless"], true, "{doc}\n{encoded}");
        }
        // Edge whitespace survives as text, not as an indented code block.
        let md = to_markdown(&json!({"type":"doc","content":[p("    four")]}).to_string()).unwrap();
        assert_eq!(plain(&parse(md["markdown"].as_str().unwrap())), "    four");
    }
    #[test]
    fn readable_markdown_and_section_patching_preserve_clean_syntax() {
        let src = "## 持仓明细\n\n| 日期 | 标的 |\n| --- | --- |\n| 2026-10-01 | [[年度复盘]] |\n\n## 调仓日志\n\n- 2026-10-01: 初始建仓";
        let (_, doc) = parse_markdown_patch(src).unwrap();
        let readable = readable_block(&doc);
        assert!(readable.contains("2026-10-01"));
        assert!(readable.contains("[[年度复盘]]"));
        assert!(!readable.contains("\\-"));
        assert!(!readable.contains("\\[\\["));

        let extracted = extract_section(&readable, "持仓明细").unwrap();
        assert!(extracted.contains("[[年度复盘]]"));
        assert!(!extracted.contains("调仓日志"));

        let appended = append_markdown(&readable, Some("调仓日志"), "- 2026-10-05: 增持").unwrap();
        assert!(appended.contains("- 2026-10-01: 初始建仓\n- 2026-10-05: 增持"));

        let replaced = replace_section(
            &appended,
            "持仓明细",
            "| 日期 | 标的 |\n| --- | --- |\n| 2026-10-05 | NVDA |",
        )
        .unwrap();
        assert!(replaced.contains("## 持仓明细"));
        assert!(replaced.contains("| 2026-10-05 | NVDA |"));
        assert!(replaced.contains("## 调仓日志"));
    }
}
