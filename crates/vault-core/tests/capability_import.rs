use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use vault_core::*;
fn call(session: &VaultSession, value: Value) -> Result<Value> {
    Ok(serde_json::from_str(&session.command(value.to_string())?).unwrap())
}
#[test]
fn reviewed_import_is_atomic_snapshotted_and_survives_reopen_without_history_table() {
    let dir = tempfile::tempdir().unwrap();
    let session = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    call(
        &session,
        json!({"op":"create","password":"synthetic-capability-test"}),
    )
    .unwrap();
    let csv = STANDARD.encode(
        b"name,url,username,password\nFixture,https://example.test,fixture,IMPORT_SECRET_CANARY",
    );
    let source = json!({"op":"import-preview","format":"csv","data":csv});
    let preview = call(&session, source.clone()).unwrap();
    assert_eq!(preview["rows"].as_array().unwrap().len(), 1);
    let before = std::fs::read(dir.path().join("vault/vault.sqlite")).unwrap();
    let mut invalid = source.clone();
    invalid["op"] = json!("import-commit");
    invalid["choices"] = json!({"0":"replace"});
    assert!(call(&session, invalid).is_err());
    assert_eq!(
        std::fs::read(dir.path().join("vault/vault.sqlite")).unwrap(),
        before
    );
    let mut commit = source;
    commit["op"] = json!("import-commit");
    assert_eq!(call(&session, commit.clone()).unwrap()["added"], 1);
    assert_eq!(
        std::fs::read(
            dir.path()
                .join("vault/before-capability-format6/vault.sqlite")
        )
        .unwrap(),
        before
    );
    assert_eq!(call(&session, commit).unwrap()["skipped"], 1);
    let bytes = std::fs::read(dir.path().join("vault/vault.sqlite")).unwrap();
    assert!(!bytes
        .windows(b"IMPORT_SECRET_CANARY".len())
        .any(|v| v == b"IMPORT_SECRET_CANARY"));
    drop(session);
    let session = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    call(
        &session,
        json!({"op":"unlock","password":"synthetic-capability-test"}),
    )
    .unwrap();
    assert_eq!(
        call(&session, json!({"op":"list"})).unwrap()["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}
#[test]
fn structured_save_and_security_controls_are_guarded_and_persistent() {
    let dir = tempfile::tempdir().unwrap();
    let session = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    assert!(call(&session, json!({"op":"security-audit"})).is_err());
    call(
        &session,
        json!({"op":"create","password":"synthetic-capability-test"}),
    )
    .unwrap();
    let card = json!({"id":"card","type":"creditCard","title":"Fixture card","card":{"number":"synthetic-card","securityCode":"test"}});
    call(&session, json!({"op":"save","item":card})).unwrap();
    assert!(dir
        .path()
        .join("vault/before-capability-format6/header.json")
        .exists());
    assert!(call(
        &session,
        json!({"op":"security-catalog","catalog":{"version":1}})
    )
    .is_err());
    call(
        &session,
        json!({"op":"security-ignore","key":"sample:kind","ignored":true}),
    )
    .unwrap();
    assert_eq!(
        call(&session, json!({"op":"security-audit"})).unwrap()["networkBreachStatus"],
        "notChecked"
    );
    assert!(call(&session, json!({"op":"export-plain","kind":"csv"})).is_err());
    let request = call(
        &session,
        json!({"op":"breach-request","password":"synthetic"}),
    )
    .unwrap();
    assert_eq!(request["prefix"].as_str().unwrap().len(), 5);
    assert!(call(
        &session,
        json!({"op":"breach-response","suffix":request["suffix"],"response":"upstream unavailable"})
    )
    .is_err());
}

#[test]
fn format6_snapshot_contains_encrypted_attachment_storage() {
    let directory = tempfile::tempdir().unwrap();
    let session = VaultSession::new(directory.path().to_string_lossy().into()).unwrap();
    call(
        &session,
        json!({"op":"create","password":"snapshot fixture"}),
    )
    .unwrap();
    call(
        &session,
        json!({"op":"save","item":{"id":"note","type":"secureNote","title":"Attachment owner"}}),
    )
    .unwrap();
    let meta: Value = serde_json::from_str(
        &session
            .import_note_attachment(
                "note".into(),
                "fixture.txt".into(),
                "text/plain".into(),
                b"SNAPSHOT_ATTACHMENT_CANARY".to_vec(),
            )
            .unwrap(),
    )
    .unwrap();
    call(&session,json!({"op":"save","item":{"id":"identity","type":"identity","title":"Fixture","identity":{}}})).unwrap();
    let restored = tempfile::tempdir().unwrap();
    std::fs::create_dir(restored.path().join("vault")).unwrap();
    for name in ["header.json", "vault.sqlite"] {
        std::fs::copy(
            directory
                .path()
                .join("vault/before-capability-format6")
                .join(name),
            restored.path().join("vault").join(name),
        )
        .unwrap();
    }
    let restored_session = VaultSession::new(restored.path().to_string_lossy().into()).unwrap();
    call(
        &restored_session,
        json!({"op":"unlock","password":"snapshot fixture"}),
    )
    .unwrap();
    assert_eq!(
        restored_session
            .read_note_attachment("note".into(), meta["id"].as_str().unwrap().into())
            .unwrap(),
        b"SNAPSHOT_ATTACHMENT_CANARY"
    );
}
