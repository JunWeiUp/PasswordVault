use serde_json::{json, Value};
use vault_core::*;

fn call(s: &VaultSession, v: Value) -> Result<Value> {
    Ok(serde_json::from_str(&s.command(v.to_string())?).unwrap())
}

fn fixture(dir: &tempfile::TempDir) -> VaultSession {
    let s = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    call(&s, json!({"op":"create","password":"fixture password"})).unwrap();
    s
}

#[test]
fn note_bodies_split_survives_restart_and_backup_round_trip() {
    let dir = tempfile::tempdir().unwrap();
    let s = fixture(&dir);
    let long_text = "VOO 85 股 · QQQM 120 股 · NVDA 60 股\n".repeat(40);
    let item = json!({
        "id": "n-port",
        "type": "secureNote",
        "title": "当前持仓情况",
        "category": "个人档案/财务与持仓",
        "slug": "finance/portfolio",
        "tags": ["美股", "资产配置"],
        "noteProperties": [{"key": "类型", "value": "持仓状态"}, {"key": "参考总值", "value": "¥1,280,000"}],
        "note": long_text,
        "noteFormat": "rich-v1",
        "noteDocument": {"type": "doc", "content": [{"type": "paragraph", "content": [{"type": "text", "text": long_text}]}]},
        "updatedAt": "2026-11-19T10:00:00Z"
    });
    call(&s, json!({"op":"save","richNotes":true,"item":item})).unwrap();
    assert_eq!(
        call(&s, json!({"op":"note-bodies-status"})).unwrap(),
        json!({"enabled": true, "count": 1})
    );
    // Restart session and verify full hydration from `note_bodies`.
    drop(s);
    let s = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    call(&s, json!({"op":"unlock","password":"fixture password"})).unwrap();
    let list = call(&s, json!({"op":"list","richNotes":true})).unwrap();
    let restored = &list["items"][0];
    assert!(restored.get("_bodySplit").is_none());
    assert_eq!(restored["note"], long_text);
    assert_eq!(restored["slug"], "finance/portfolio");
    assert_eq!(restored["noteProperties"][0]["key"], "类型");
    assert_eq!(
        restored["noteDocument"]["content"][0]["content"][0]["text"],
        long_text
    );

    // Export and restore into a fresh vault; archive stays compatible and full content survives.
    let exported = call(
        &s,
        json!({"op":"export","richNotes":true,"password":"backup password"}),
    )
    .unwrap()["content"]
        .as_str()
        .unwrap()
        .to_owned();
    let dst = tempfile::tempdir().unwrap();
    let s2 = VaultSession::new(dst.path().to_string_lossy().into()).unwrap();
    call(
        &s2,
        json!({"op":"create-from-backup","richNotes":true,"content":exported,"backupPassword":"backup password","password":"new password"}),
    )
    .unwrap();
    let list2 = call(&s2, json!({"op":"list","richNotes":true})).unwrap();
    assert_eq!(list2["items"][0]["note"], long_text);
    assert_eq!(
        call(&s2, json!({"op":"note-bodies-status"})).unwrap()["count"],
        1
    );

    // Raw SQLite file must never contain plaintext note content.
    let bytes = std::fs::read(dir.path().join("vault/vault.sqlite")).unwrap();
    assert!(!bytes.windows(b"QQQM 120".len()).any(|w| w == b"QQQM 120"));
}

#[test]
fn hierarchical_categories_cascade_rename_and_remove_safely() {
    let dir = tempfile::tempdir().unwrap();
    let s = fixture(&dir);
    call(
        &s,
        json!({"op":"category-add","name":"个人档案/财务与持仓"}),
    )
    .unwrap();
    let cats = call(&s, json!({"op":"list"})).unwrap()["settings"]["noteCategories"].clone();
    let cats = cats.as_array().unwrap();
    assert!(cats.contains(&json!("个人档案")));
    assert!(cats.contains(&json!("个人档案/财务与持仓")));

    call(
        &s,
        json!({"op":"save","item":{"id":"n1","type":"secureNote","title":"持仓","category":"个人档案/财务与持仓","note":"ok"}}),
    )
    .unwrap();
    // Cannot rename parent into its own child.
    assert!(call(
        &s,
        json!({"op":"category-rename","name":"个人档案","to":"个人档案/子目录","time":"2026-11-19T10:00:00Z"})
    )
    .is_err());

    call(
        &s,
        json!({"op":"category-rename","name":"个人档案","to":"知识库","time":"2026-11-19T10:01:00Z"}),
    )
    .unwrap();
    let doc = call(&s, json!({"op":"list"})).unwrap();
    assert_eq!(doc["items"][0]["category"], "知识库/财务与持仓");

    call(
        &s,
        json!({"op":"category-remove","name":"知识库","time":"2026-11-19T10:02:00Z"}),
    )
    .unwrap();
    let doc = call(&s, json!({"op":"list"})).unwrap();
    assert_eq!(doc["items"][0]["category"], "");
    assert!(doc["settings"]["noteCategories"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn ai_writes_milestones_and_manual_coalescing_preserve_history_semantics() {
    let dir = tempfile::tempdir().unwrap();
    let s = fixture(&dir);
    // Initial note before history is enabled.
    call(
        &s,
        json!({"op":"save","richNotes":true,"item":{"id":"n1","type":"secureNote","title":"持仓","note":"v1","updatedAt":"2026-11-19T08:00:00Z"}}),
    )
    .unwrap();
    assert_eq!(
        call(&s, json!({"op":"history-status"})).unwrap()["enabled"],
        false
    );

    // AI write auto-enables history and records metadata.
    call(
        &s,
        json!({
            "op":"save","richNotes":true,
            "item":{"id":"n1","type":"secureNote","title":"持仓","note":"v2","lastActor":"AI · Claude Code","lastSummary":"AI 更新持仓","updatedAt":"2026-11-19T09:00:00Z"},
            "historyMeta":{"actorType":"ai","actor":"AI · Claude Code","summary":"AI 更新持仓"}
        }),
    )
    .unwrap();
    assert_eq!(
        call(&s, json!({"op":"history-status"})).unwrap()["enabled"],
        true
    );
    let revs = call(&s, json!({"op":"history-list","id":"n1"})).unwrap();
    assert_eq!(revs["total"], 2);
    assert_eq!(revs["revisions"][0]["actorType"], "ai");
    assert_eq!(revs["revisions"][0]["summary"], "AI 更新持仓");

    // Manual milestone creates an independent snapshot even when content is unchanged.
    let ms = call(
        &s,
        json!({"op":"history-milestone","id":"n1","summary":"Q4 归档"}),
    )
    .unwrap();
    assert_eq!(ms["revision"]["milestone"], true);
    assert_eq!(
        call(&s, json!({"op":"history-list","id":"n1"})).unwrap()["total"],
        3
    );

    // Two consecutive manual coalesced edits produce 1 new manual revision (not 2),
    // without touching the preceding milestone!
    for body in ["v3-draft-1", "v3-draft-2"] {
        call(
            &s,
            json!({
                "op":"save","richNotes":true,
                "item":{"id":"n1","type":"secureNote","title":"持仓","note":body,"updatedAt":"2026-11-19T09:05:00Z"},
                "historyMeta":{"actorType":"user","actor":"手动编辑 · 我","coalesce":true}
            }),
        )
        .unwrap();
    }
    let revs = call(&s, json!({"op":"history-list","id":"n1"})).unwrap();
    assert_eq!(revs["total"], 4);
    assert_eq!(revs["revisions"][0]["item"]["note"], "v3-draft-2");
    assert_eq!(revs["revisions"][1]["milestone"], true);

    // Prune with keepMilestones=true retains milestone + current version.
    call(
        &s,
        json!({"op":"history-prune","id":"n1","keepMilestones":true}),
    )
    .unwrap();
    let after_prune = call(&s, json!({"op":"history-list","id":"n1"})).unwrap();
    assert_eq!(after_prune["total"], 2);
    assert!(after_prune["revisions"]
        .as_array()
        .unwrap()
        .iter()
        .any(|r| r["milestone"] == true));
}
