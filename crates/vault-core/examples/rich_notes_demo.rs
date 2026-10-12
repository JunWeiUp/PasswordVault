//! Creates only a new disposable fixture; never point this at a real vault.
use serde_json::{json, Value};
use vault_core::*;
fn main() -> Result<()> {
    let folder = std::env::args()
        .nth(1)
        .expect("Supply a NEW fixture directory");
    if std::path::Path::new(&folder).exists() {
        return Err(VaultError::AlreadyExists);
    }
    let session = VaultSession::new(folder)?;
    let call = |v: Value| session.command(v.to_string());
    call(json!({"op":"create","password":"Synthetic rich notes preview"}))?;
    call(
        json!({"op":"save","item":{"id":"preview","type":"secureNote","title":"把想法写下来","note":"旧笔记原文","noteFormat":"markdown","category":"日常记录"}}),
    )?;
    let file: Value = serde_json::from_str(&session.import_note_attachment(
        "preview".into(),
        "项目清单.txt".into(),
        "text/plain".into(),
        b"Synthetic attachment: private planning checklist".to_vec(),
    )?)
    .unwrap();
    call(
        json!({"op":"save","richNotes":true,"item":{"id":"preview","type":"secureNote","title":"把想法写下来","noteFormat":"rich-v1","category":"日常记录","note":"让记录保持简单。文字、表格和附件都在这里。\n本周安排\n整理想法\n记录进展","noteDocument":{"type":"doc","content":[
            {"type":"paragraph","content":[{"type":"text","text":"让记录保持简单。","marks":[{"type":"bold"}]},{"type":"text","text":"文字、表格和附件都在这里，写下的内容会自动加密保存。"}]},
            {"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"本周安排"}]},
            {"type":"taskList","content":[{"type":"taskItem","attrs":{"checked":true},"content":[{"type":"paragraph","content":[{"type":"text","text":"整理想法，让每一条记录都有清晰的起点。"}]}]},{"type":"taskItem","attrs":{"checked":false},"content":[{"type":"paragraph","content":[{"type":"text","text":"记录进展，回车继续下一项。"}]}]}]},
            {"type":"blockquote","content":[{"type":"paragraph","content":[{"type":"text","text":"专注内容，保持思路。"}]}]},
            {"type":"table","content":[{"type":"tableRow","content":[{"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"事项"}]}]},{"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"进度"}]}]}]},{"type":"tableRow","content":[{"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"编辑体验"}]}]},{"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"连续输入验证"}]}]}]}]},
            {"type":"vaultAttachment","attrs":{"attachmentId":file["id"],"name":"项目清单.txt","mime":"text/plain","size":file["size"]}},
            {"type":"paragraph","content":[{"type":"text","text":"这是一份虚构的演示笔记，不包含真实资料。"}]}
        ]}}}),
    )?;
    Ok(())
}
