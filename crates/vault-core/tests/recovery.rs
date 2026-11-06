use serde_json::{json, Value};
use vault_core::*;

fn call(s: &VaultSession, request: Value) -> Result<Value> {
    Ok(serde_json::from_str(&s.command(request.to_string())?).unwrap())
}
fn fixture(dir: &tempfile::TempDir) -> VaultSession {
    let s = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    call(&s, json!({"op":"create","password":"original"})).unwrap();
    call(&s, json!({"op":"save","item":{"id":"note","type":"secureNote","title":"RECOVERY_CANARY","note":"private"}})).unwrap();
    s
}
fn enable(s: &VaultSession) -> String {
    let key = call(s, json!({"op":"recovery-generate"})).unwrap()["key"]
        .as_str()
        .unwrap()
        .to_owned();
    call(
        s,
        json!({"op":"recovery-enable","key":key,"currentPassword":"original"}),
    )
    .unwrap();
    key
}

#[test]
fn key_checksum_and_transcription() {
    let key = generate_recovery_key();
    assert_eq!(normalize_recovery_key(&key).unwrap().len(), 72);
    assert_eq!(
        *recovery_wrapping_key(&key).unwrap(),
        *recovery_wrapping_key(&format!(" {}\n", key.to_uppercase())).unwrap()
    );
    let mut damaged = key.clone().into_bytes();
    damaged[0] = if damaged[0] == b'0' { b'1' } else { b'0' };
    assert!(normalize_recovery_key(std::str::from_utf8(&damaged).unwrap()).is_err());
    for invalid in ["", "password", &"f".repeat(72), &"0".repeat(257)] {
        assert!(normalize_recovery_key(invalid).is_err());
    }
}

#[test]
fn recovery_authenticates_before_mutation_and_preserves_data() {
    let dir = tempfile::tempdir().unwrap();
    let s = fixture(&dir);
    let key = enable(&s);
    let before = call(&s, json!({"op":"list"})).unwrap();
    let grant =
        create_background_grant(dir.path().to_string_lossy().into(), "original".into()).unwrap();
    let path = dir.path().join("vault/header.json");
    let header = std::fs::read(&path).unwrap();
    call(&s, json!({"op":"lock"})).unwrap();
    assert!(call(&s, json!({"op":"recovery-generate"})).is_err());
    for bad in ["invalid".to_owned(), generate_recovery_key()] {
        assert!(call(
            &s,
            json!({"op":"recovery-reset-password","key":bad,"newPassword":"replacement"})
        )
        .is_err());
        assert_eq!(std::fs::read(&path).unwrap(), header);
    }
    assert!(call(
        &s,
        json!({"op":"recovery-reset-password","key":key,"newPassword":""})
    )
    .is_err());
    assert_eq!(std::fs::read(&path).unwrap(), header);
    call(
        &s,
        json!({"op":"recovery-reset-password","key":key,"newPassword":"replacement"}),
    )
    .unwrap();
    assert_eq!(call(&s, json!({"op":"list"})).unwrap(), before);
    assert!(!background_grant_valid(dir.path().to_string_lossy().into(), grant).unwrap());
    call(&s, json!({"op":"lock"})).unwrap();
    assert!(call(&s, json!({"op":"unlock","password":"original"})).is_err());
    call(&s, json!({"op":"unlock","password":"replacement"})).unwrap();
    let envelope = std::fs::read_to_string(dir.path().join("vault/recovery.json")).unwrap();
    assert!(!envelope.contains(&key));
    assert!(!envelope.contains("CANARY"));
}

#[test]
fn rotation_revocation_and_password_change() {
    let dir = tempfile::tempdir().unwrap();
    let s = fixture(&dir);
    let old = enable(&s);
    let new = enable(&s);
    assert!(call(&s, json!({"op":"recovery-export","key":old})).is_err());
    call(
        &s,
        json!({"op":"change-password","currentPassword":"original","newPassword":"changed"}),
    )
    .unwrap();
    call(&s, json!({"op":"recovery-export","key":new})).unwrap();
    assert!(call(
        &s,
        json!({"op":"recovery-disable","currentPassword":"original"})
    )
    .is_err());
    call(
        &s,
        json!({"op":"recovery-disable","currentPassword":"changed"}),
    )
    .unwrap();
    assert_eq!(
        call(&s, json!({"op":"recovery-status"})).unwrap()["enabled"],
        false
    );
    call(&s, json!({"op":"lock"})).unwrap();
    assert!(call(
        &s,
        json!({"op":"recovery-reset-password","key":new,"newPassword":"other"})
    )
    .is_err());
}

#[test]
fn emergency_archive_restores_attachments_to_fresh_vault_only() {
    let dir = tempfile::tempdir().unwrap();
    let s = fixture(&dir);
    let meta: Value = serde_json::from_str(
        &s.import_note_attachment(
            "note".into(),
            "fixture.txt".into(),
            "text/plain".into(),
            b"ATTACHMENT_CANARY".to_vec(),
        )
        .unwrap(),
    )
    .unwrap();
    let key = enable(&s);
    let archive = call(&s, json!({"op":"recovery-export","key":key})).unwrap()["content"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(!archive.contains("CANARY"));
    let target = tempfile::tempdir().unwrap();
    let restored = VaultSession::new(target.path().to_string_lossy().into()).unwrap();
    assert!(call(&restored, json!({"op":"recovery-restore-backup","key":generate_recovery_key(),"content":archive,"newPassword":"new"})).is_err());
    assert!(!target.path().join("vault").exists());
    call(
        &restored,
        json!({"op":"recovery-restore-backup","key":key,"content":archive,"newPassword":"new"}),
    )
    .unwrap();
    assert_eq!(
        restored
            .read_note_attachment("note".into(), meta["id"].as_str().unwrap().into())
            .unwrap(),
        b"ATTACHMENT_CANARY"
    );
    let before = call(&restored, json!({"op":"list"})).unwrap();
    assert!(call(&restored, json!({"op":"recovery-restore-backup","key":key,"content":archive,"newPassword":"overwrite"})).is_err());
    assert_eq!(call(&restored, json!({"op":"list"})).unwrap(), before);
    assert_eq!(
        call(&restored, json!({"op":"recovery-status"})).unwrap()["enabled"],
        false
    );
}

#[test]
fn foreign_envelope_does_not_reset_password() {
    let a = tempfile::tempdir().unwrap();
    let b = tempfile::tempdir().unwrap();
    let sa = fixture(&a);
    let sb = fixture(&b);
    let key = enable(&sa);
    enable(&sb);
    let header = std::fs::read(b.path().join("vault/header.json")).unwrap();
    std::fs::copy(
        a.path().join("vault/recovery.json"),
        b.path().join("vault/recovery.json"),
    )
    .unwrap();
    call(&sb, json!({"op":"lock"})).unwrap();
    assert!(call(
        &sb,
        json!({"op":"recovery-reset-password","key":key,"newPassword":"bad"})
    )
    .is_err());
    assert_eq!(
        std::fs::read(b.path().join("vault/header.json")).unwrap(),
        header
    );
}
