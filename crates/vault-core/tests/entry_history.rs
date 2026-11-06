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
fn save(s: &VaultSession, title: &str) {
    call(s,json!({"op":"save","item":{"id":"one","type":"password","title":title,"password":"HISTORY_SECRET_CANARY"}})).unwrap();
}
fn revisions(s: &VaultSession) -> Vec<Value> {
    call(s, json!({"op":"history-list","id":"one"})).unwrap()["revisions"]
        .as_array()
        .unwrap()
        .clone()
}

#[test]
fn whole_versions_survive_restart_and_restore_without_duplicate_noops() {
    let dir = tempfile::tempdir().unwrap();
    let s = fixture(&dir);
    save(&s, "before");
    call(&s, json!({"op":"history-enable"})).unwrap();
    assert!(dir
        .path()
        .join("vault/before-entry-history/vault.sqlite")
        .exists());
    save(&s, "after");
    save(&s, "after");
    let rows = revisions(&s);
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["item"]["title"], "after");
    assert!(call(&s,json!({"op":"history-restore","id":"other","revisionId":rows[1]["id"],"time":"2026-01-01T00:00:00Z"})).is_err());
    call(&s,json!({"op":"history-restore","id":"one","revisionId":rows[1]["id"],"time":"2026-01-01T00:00:00Z"})).unwrap();
    assert_eq!(revisions(&s).len(), 3);
    assert_eq!(
        call(&s, json!({"op":"list"})).unwrap()["items"][0]["title"],
        "before"
    );
    drop(s);
    let s = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    assert!(call(&s, json!({"op":"history-list","id":"one"})).is_err());
    call(&s, json!({"op":"unlock","password":"fixture password"})).unwrap();
    assert_eq!(revisions(&s).len(), 3);
    let bytes = std::fs::read(dir.path().join("vault/vault.sqlite")).unwrap();
    assert!(!bytes
        .windows(b"HISTORY_SECRET_CANARY".len())
        .any(|w| w == b"HISTORY_SECRET_CANARY"));
}

#[test]
fn backup_preserves_history_and_permanent_delete_erases_it() {
    let dir = tempfile::tempdir().unwrap();
    let s = fixture(&dir);
    call(&s, json!({"op":"history-enable"})).unwrap();
    save(&s, "first");
    save(&s, "second");
    let content = call(
        &s,
        json!({"op":"export","richNotes":true,"password":"backup password"}),
    )
    .unwrap()["content"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        serde_json::from_str::<Value>(&content).unwrap()["version"],
        4
    );
    let dst = tempfile::tempdir().unwrap();
    let restored = VaultSession::new(dst.path().to_string_lossy().into()).unwrap();
    let mut downgraded: Value = serde_json::from_str(&content).unwrap();
    downgraded["version"] = json!(3);
    assert!(call(&restored, json!({"op":"create-from-backup","richNotes":true,"content":downgraded.to_string(),"backupPassword":"backup password","password":"new"})).is_err());
    assert!(!dst.path().join("vault").exists());
    call(&restored,json!({"op":"create-from-backup","richNotes":true,"content":content,"backupPassword":"backup password","password":"new"})).unwrap();
    assert!(revisions(&restored)
        .iter()
        .any(|r| r["item"]["title"] == "first"));
    assert_eq!(
        call(&restored, json!({"op":"list"})).unwrap()["formatVersion"],
        5
    );
    call(
        &restored,
        json!({"op":"remove","id":"one","richNotes":true}),
    )
    .unwrap();
    assert!(revisions(&restored).is_empty());
}

#[test]
fn historical_attachment_survives_collection_export_and_restore() {
    let dir = tempfile::tempdir().unwrap();
    let s = fixture(&dir);
    call(
        &s,
        json!({"op":"save","item":{"id":"note","type":"secureNote","title":"note"}}),
    )
    .unwrap();
    call(&s, json!({"op":"history-enable"})).unwrap();
    let meta: Value = serde_json::from_str(
        &s.import_note_attachment(
            "note".into(),
            "old.txt".into(),
            "text/plain".into(),
            b"history attachment".to_vec(),
        )
        .unwrap(),
    )
    .unwrap();
    let item = json!({"id":"note","type":"secureNote","title":"note","noteFormat":"rich-v1","noteDocument":{"type":"doc","content":[{"type":"vaultAttachment","attrs":{"attachmentId":meta["id"]}}]}});
    call(&s, json!({"op":"save","richNotes":true,"item":item})).unwrap();
    let old =
        call(&s, json!({"op":"history-list","id":"note"})).unwrap()["revisions"][0]["id"].clone();
    let mut changed = item.clone();
    changed["noteDocument"]["content"] = json!([]);
    call(&s, json!({"op":"save","richNotes":true,"item":changed})).unwrap();
    call(
        &s,
        json!({"op":"collect-note-attachments","richNotes":true}),
    )
    .unwrap();
    assert!(s
        .discard_note_attachment("note".into(), meta["id"].as_str().unwrap().into())
        .is_err());
    let content = call(
        &s,
        json!({"op":"export","richNotes":true,"password":"backup password"}),
    )
    .unwrap()["content"]
        .clone();
    let dst = tempfile::tempdir().unwrap();
    let restored = VaultSession::new(dst.path().to_string_lossy().into()).unwrap();
    call(&restored,json!({"op":"create-from-backup","richNotes":true,"content":content,"backupPassword":"backup password","password":"new"})).unwrap();
    call(
        &restored,
        json!({"op":"history-restore","id":"note","revisionId":old,"time":"2026-01-01T00:00:00Z"}),
    )
    .unwrap();
    assert_eq!(
        restored
            .read_note_attachment("note".into(), meta["id"].as_str().unwrap().into())
            .unwrap(),
        b"history attachment"
    );
    call(&s, json!({"op":"history-prune","id":"note"})).unwrap();
    assert!(s
        .read_note_attachment("note".into(), meta["id"].as_str().unwrap().into())
        .is_err());
}

#[test]
fn clearing_history_keeps_current_version_and_pagination_is_bounded() {
    let dir = tempfile::tempdir().unwrap();
    let s = fixture(&dir);
    call(&s, json!({"op":"history-enable"})).unwrap();
    for title in ["a", "b", "c"] {
        save(&s, title);
    }
    let page = call(
        &s,
        json!({"op":"history-list","id":"one","offset":1,"limit":1}),
    )
    .unwrap();
    assert_eq!(page["total"], 3);
    assert_eq!(page["revisions"].as_array().unwrap().len(), 1);
    assert_eq!(page["revisions"][0]["item"]["title"], "b");
    let stale = revisions(&s)[2]["id"].clone();
    call(&s, json!({"op":"history-prune","id":"one"})).unwrap();
    assert_eq!(revisions(&s).len(), 1);
    assert_eq!(revisions(&s)[0]["item"]["title"], "c");
    assert!(call(
        &s,
        json!({"op":"history-restore","id":"one","revisionId":stale,"time":"2026-01-01T00:00:00Z"})
    )
    .is_err());
}

#[test]
fn interrupted_write_keeps_document_and_history_together() {
    let dir = tempfile::tempdir().unwrap();
    let s = fixture(&dir);
    call(&s, json!({"op":"history-enable"})).unwrap();
    save(&s, "before");
    let before = call(&s, json!({"op":"list"})).unwrap();
    let history = revisions(&s);
    let journal = dir.path().join("vault/vault.sqlite-journal");
    std::fs::create_dir(&journal).unwrap();
    assert!(call(
        &s,
        json!({"op":"save","item":{"id":"one","type":"password","title":"must not commit"}})
    )
    .is_err());
    std::fs::remove_dir(journal).unwrap();
    assert_eq!(call(&s, json!({"op":"list"})).unwrap(), before);
    assert_eq!(revisions(&s), history);
    save(&s, "after retry");
    assert_eq!(revisions(&s).len(), 2);
}
