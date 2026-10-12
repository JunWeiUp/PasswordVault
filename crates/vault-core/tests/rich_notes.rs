use serde_json::{json, Value};
use vault_core::*;
const PASSWORD: &str = "Synthetic rich note fixture password";
fn call(s: &VaultSession, v: Value) -> Result<Value> {
    Ok(serde_json::from_str(&s.command(v.to_string())?).unwrap())
}
fn create(dir: &tempfile::TempDir) -> VaultSession {
    let s = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    call(&s, json!({"op":"create","password":PASSWORD})).unwrap();
    call(&s,json!({"op":"save","item":{"id":"note","type":"secureNote","title":"Synthetic","note":"legacy original","noteFormat":"markdown"}})).unwrap();
    s
}
fn rich(id: &str) -> Value {
    json!({"id":"note","type":"secureNote","title":"Synthetic","note":"RICH_TEXT_CANARY","noteFormat":"rich-v1","noteDocument":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"RICH_TEXT_CANARY"}]},{"type":"vaultAttachment","attrs":{"attachmentId":id,"name":"PRIVATE_NAME_CANARY"}}]}})
}
#[test]
fn attachments_are_encrypted_bound_to_owner_and_survive_full_backup() {
    let dir = tempfile::tempdir().unwrap();
    let s = create(&dir);
    let bytes = b"ATTACHMENT_PLAINTEXT_CANARY";
    let meta: Value = serde_json::from_str(
        &s.import_note_attachment(
            "note".into(),
            "PRIVATE_NAME_CANARY".into(),
            "application/octet-stream".into(),
            bytes.to_vec(),
        )
        .unwrap(),
    )
    .unwrap();
    let id = meta["id"].as_str().unwrap();
    call(&s, json!({"op":"save","richNotes":true,"item":rich(id)})).unwrap();
    assert!(s.read_note_attachment("other".into(), id.into()).is_err());
    assert_eq!(
        s.read_note_attachment("note".into(), id.into()).unwrap(),
        bytes
    );
    assert!(s.discard_note_attachment("note".into(), id.into()).is_err());
    assert_eq!(call(&s, json!({"op":"list"})).unwrap()["formatVersion"], 3);
    assert!(dir
        .path()
        .join("vault/before-rich-notes/vault.sqlite")
        .exists());
    let sql = std::fs::read(dir.path().join("vault/vault.sqlite")).unwrap();
    for canary in [
        "ATTACHMENT_PLAINTEXT_CANARY",
        "PRIVATE_NAME_CANARY",
        "RICH_TEXT_CANARY",
    ] {
        assert!(!sql.windows(canary.len()).any(|w| w == canary.as_bytes()));
    }
    let backup = call(
        &s,
        json!({"op":"export","richNotes":true,"password":PASSWORD}),
    )
    .unwrap()["content"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(!backup.contains("CANARY"));
    let dst = tempfile::tempdir().unwrap();
    let restored = create(&dst);
    call(
        &restored,
        json!({"op":"import","richNotes":true,"content":backup,"password":PASSWORD}),
    )
    .unwrap();
    assert_eq!(
        restored
            .read_note_attachment("note".into(), id.into())
            .unwrap(),
        bytes
    );
    call(&s, json!({"op":"lock"})).unwrap();
    assert!(s.read_note_attachment("note".into(), id.into()).is_err());
    call(&s, json!({"op":"unlock","password":PASSWORD})).unwrap();
    assert_eq!(
        s.read_note_attachment("note".into(), id.into()).unwrap(),
        bytes
    );
    let fresh = tempfile::tempdir().unwrap();
    let fresh_s = VaultSession::new(fresh.path().to_string_lossy().into()).unwrap();
    call(&fresh_s,json!({"op":"create-from-backup","richNotes":true,"content":backup,"backupPassword":PASSWORD,"password":"new password"})).unwrap();
    assert_eq!(
        fresh_s
            .read_note_attachment("note".into(), id.into())
            .unwrap(),
        bytes
    );
}
#[test]
fn incomplete_or_tampered_archives_and_wrong_password_leave_local_data_intact() {
    let dir = tempfile::tempdir().unwrap();
    let s = create(&dir);
    let meta: Value = serde_json::from_str(
        &s.import_note_attachment("note".into(), "a".into(), "text/plain".into(), vec![42])
            .unwrap(),
    )
    .unwrap();
    call(
        &s,
        json!({"op":"save","richNotes":true,"item":rich(meta["id"].as_str().unwrap())}),
    )
    .unwrap();
    let backup = call(
        &s,
        json!({"op":"export","richNotes":true,"password":PASSWORD}),
    )
    .unwrap()["content"]
        .as_str()
        .unwrap()
        .to_string();
    let target_dir = tempfile::tempdir().unwrap();
    let target = create(&target_dir);
    let before = call(&target, json!({"op":"list"})).unwrap();
    let mut damaged: Value = serde_json::from_str(&backup).unwrap();
    damaged["files"] = json!({});
    for (content, password) in [(damaged.to_string(), PASSWORD), (backup.clone(), "wrong")] {
        assert!(call(
            &target,
            json!({"op":"import","richNotes":true,"content":content,"password":password})
        )
        .is_err());
        assert_eq!(call(&target, json!({"op":"list"})).unwrap(), before);
    }
    let mut damaged: Value = serde_json::from_str(&backup).unwrap();
    damaged["files"][meta["id"].as_str().unwrap()]["ciphertext"] = json!("AAAA");
    assert!(call(
        &target,
        json!({"op":"import","richNotes":true,"content":damaged.to_string(),"password":PASSWORD})
    )
    .is_err());
    assert_eq!(call(&target, json!({"op":"list"})).unwrap(), before);
}
#[test]
fn old_clients_cannot_downgrade_rich_notes_or_export_incomplete_backups() {
    let dir = tempfile::tempdir().unwrap();
    let s = create(&dir);
    let meta: Value = serde_json::from_str(
        &s.import_note_attachment("note".into(), "a".into(), "text/plain".into(), vec![42])
            .unwrap(),
    )
    .unwrap();
    call(
        &s,
        json!({"op":"save","richNotes":true,"item":rich(meta["id"].as_str().unwrap())}),
    )
    .unwrap();
    for op in ["export", "export-plain", "export-csv-backup"] {
        assert!(call(&s, json!({"op":op,"password":PASSWORD})).is_err());
    }
    assert!(call(&s,json!({"op":"save","item":{"id":"note","type":"secureNote","title":"overwrite","note":"lost"}})).is_err());
    assert!(call(&s, json!({"op":"sync-request","vaultId":"x","peerKey":"x"})).is_err());
    assert!(call(
        &s,
        json!({"op":"save","richNotes":true,"item":rich("missing-file")})
    )
    .is_err());
    assert!(s
        .import_note_attachment(
            "note".into(),
            "oversize".into(),
            "text/plain".into(),
            vec![0; 25 * 1024 * 1024 + 1]
        )
        .is_err());
    call(&s, json!({"op":"remove","id":"note","richNotes":true})).unwrap();
    assert!(s
        .read_note_attachment("note".into(), meta["id"].as_str().unwrap().into())
        .is_err());
}

#[test]
fn failed_attachment_write_preserves_document_and_existing_files() {
    let dir = tempfile::tempdir().unwrap();
    let s = create(&dir);
    let old: Value = serde_json::from_str(
        &s.import_note_attachment(
            "note".into(),
            "keep".into(),
            "text/plain".into(),
            b"keep".to_vec(),
        )
        .unwrap(),
    )
    .unwrap();
    call(
        &s,
        json!({"op":"save","richNotes":true,"item":rich(old["id"].as_str().unwrap())}),
    )
    .unwrap();
    let before = call(&s, json!({"op":"list"})).unwrap();
    // SQLite can still read its open file, but cannot create its rollback journal.
    std::fs::rename(dir.path().join("vault"), dir.path().join("offline-vault")).unwrap();
    let failed = s.import_note_attachment(
        "note".into(),
        "must not commit".into(),
        "text/plain".into(),
        b"failed-write".to_vec(),
    );
    std::fs::rename(dir.path().join("offline-vault"), dir.path().join("vault")).unwrap();
    assert!(failed.is_err());
    assert_eq!(call(&s, json!({"op":"list"})).unwrap(), before);
    assert_eq!(
        s.read_note_attachment("note".into(), old["id"].as_str().unwrap().into())
            .unwrap(),
        b"keep"
    );
    assert!(call(
        &s,
        json!({"op":"export","richNotes":true,"password":PASSWORD})
    )
    .is_ok());
}

#[test]
fn attachment_metadata_is_authenticated_and_collection_preserves_trash() {
    let dir = tempfile::tempdir().unwrap();
    let s = create(&dir);
    let old: Value = serde_json::from_str(
        &s.import_note_attachment(
            "note".into(),
            "keep".into(),
            "text/plain".into(),
            b"keep".to_vec(),
        )
        .unwrap(),
    )
    .unwrap();
    let unused: Value = serde_json::from_str(
        &s.import_note_attachment(
            "note".into(),
            "cancelled".into(),
            "text/plain".into(),
            b"unused".to_vec(),
        )
        .unwrap(),
    )
    .unwrap();
    let mut item = rich(old["id"].as_str().unwrap());
    item["isDeleted"] = json!(true);
    call(&s, json!({"op":"save","richNotes":true,"item":item})).unwrap();
    call(
        &s,
        json!({"op":"collect-note-attachments","richNotes":true}),
    )
    .unwrap();
    assert!(s
        .read_note_attachment("note".into(), unused["id"].as_str().unwrap().into())
        .is_err());
    assert_eq!(
        s.read_note_attachment("note".into(), old["id"].as_str().unwrap().into())
            .unwrap(),
        b"keep"
    );
    let root: [u8; 32] = s.biometric_key().unwrap().try_into().unwrap();
    let conn = rusqlite::Connection::open(dir.path().join("vault/vault.sqlite")).unwrap();
    let key = format!(
        "x'{}'",
        hex::encode(subkey(&root, b"native-database").as_ref())
    );
    conn.pragma_update(None, "key", key).unwrap();
    let id = old["id"].as_str().unwrap();
    let mut meta: Value = serde_json::from_str(
        &conn
            .query_row(
                "SELECT metadata FROM note_attachments WHERE id=?1",
                [id],
                |r| r.get::<_, String>(0),
            )
            .unwrap(),
    )
    .unwrap();
    meta["name"] = json!("forged name");
    conn.execute(
        "UPDATE note_attachments SET metadata=?1 WHERE id=?2",
        rusqlite::params![meta.to_string(), id],
    )
    .unwrap();
    assert!(matches!(
        s.read_note_attachment("note".into(), id.into()),
        Err(VaultError::Authentication)
    ));
    assert!(call(
        &s,
        json!({"op":"export","richNotes":true,"password":PASSWORD})
    )
    .is_err());
}
