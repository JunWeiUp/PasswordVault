//! Adds a long rich-v1 note to an existing synthetic vault (memory checks only).
//!   cargo run --example seed_long_note -- /tmp/<copy>/vault <paragraphs>
use serde_json::{json, Value};
use vault_core::VaultSession;
fn main() {
    let dir = std::env::args().nth(1).expect("vault dir");
    assert!(dir.starts_with("/tmp/") || dir.starts_with("/private/tmp/"), "synthetic vaults only");
    let n: usize = std::env::args().nth(2).and_then(|v| v.parse().ok()).unwrap_or(1500);
    let s = VaultSession::new(dir).unwrap();
    s.command(json!({"op":"unlock","password":"synthetic-preview-password"}).to_string()).unwrap();
    let mut content: Vec<Value> = Vec::new();
    let mut text = String::new();
    for i in 0..n {
        let line = format!("第 {i} 段：这是一段用于内存测试的示例文字，包含 **加粗** 与列表。Lorem ipsum dolor sit amet {i}.");
        if i % 10 == 0 {
            content.push(json!({"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":format!("小节 {i}")}]}));
        }
        content.push(json!({"type":"paragraph","content":[{"type":"text","text":line.clone()},{"type":"text","marks":[{"type":"bold"}],"text":" 重点"}]}));
        text.push_str(&line);
        text.push('\n');
    }
    let item = json!({"id":"long-note","type":"secureNote","title":"超长笔记（内存测试）","category":"工作","note":text,
        "noteFormat":"rich-v1","noteDocument":{"type":"doc","content":content},"tags":[],"username":"",
        "isDeleted":false,"isFavorite":false,"isPinned":true,"createdAt":"2026-11-05T09:12:00Z","updatedAt":"2026-11-05T09:13:00Z"});
    s.command(json!({"op":"save","item":item,"richNotes":true}).to_string()).unwrap();
    s.command(json!({"op":"lock"}).to_string()).unwrap();
    println!("added {n} paragraphs");
}
