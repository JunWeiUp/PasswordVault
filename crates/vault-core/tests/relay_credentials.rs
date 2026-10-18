use serde_json::{json, Value};
use vault_core::VaultSession;
fn call(s: &VaultSession, v: Value) -> Value {
    serde_json::from_str(&s.command(v.to_string()).unwrap()).unwrap()
}
fn fixture() -> (tempfile::TempDir, VaultSession) {
    let d = tempfile::tempdir().unwrap();
    let s = VaultSession::new(d.path().to_string_lossy().into()).unwrap();
    call(&s, json!({"op":"create","password":"fixture"}));
    (d, s)
}
#[test]
fn credentials_require_unlock_survive_password_change_and_never_enter_exports() {
    let (d, s) = fixture();
    let data =
        json!({"device":"original-device","token":"LOCAL-RELAY-CANARY-ONLY","secret":"fictional"})
            .to_string();
    assert_eq!(
        call(&s, json!({"op":"relay-credentials-read"}))["data"],
        Value::Null
    );
    call(&s, json!({"op":"relay-credentials-write","data":data}));
    assert_eq!(
        call(&s, json!({"op":"relay-credentials-read"}))["data"],
        data
    );
    let bytes = std::fs::read(d.path().join("vault/relay-private/credentials.v1.enc")).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("LOCAL-RELAY-CANARY-ONLY"));
    assert!(!call(&s, json!({"op":"list"}))
        .to_string()
        .contains("LOCAL-RELAY-CANARY-ONLY"));
    assert!(!call(&s, json!({"op":"export-plain","kind":"json"}))
        .to_string()
        .contains("LOCAL-RELAY-CANARY-ONLY"));
    assert_eq!(call(&s, json!({"op":"relay-status"}))["enabled"], false);
    call(
        &s,
        json!({"op":"change-password","currentPassword":"fixture","newPassword":"replacement"}),
    );
    call(&s, json!({"op":"lock"}));
    for op in ["relay-credentials-read", "relay-credentials-write"] {
        assert!(s.command(json!({"op":op,"data":data}).to_string()).is_err());
    }
    assert!(s
        .command(json!({"op":"unlock","password":"fixture"}).to_string())
        .is_err());
    call(&s, json!({"op":"unlock","password":"replacement"}));
    assert_eq!(
        call(&s, json!({"op":"relay-credentials-read"}))["data"],
        data
    );
    drop(s);
    let s = VaultSession::new(d.path().to_string_lossy().into()).unwrap();
    call(&s, json!({"op":"unlock","password":"replacement"}));
    assert_eq!(
        call(&s, json!({"op":"relay-credentials-read"}))["data"],
        data
    );
}
#[test]
fn tampering_wrong_vault_and_failed_updates_preserve_existing_ciphertext() {
    let (d, s) = fixture();
    call(
        &s,
        json!({"op":"relay-credentials-write","data":"{\"device\":\"original\"}"}),
    );
    let path = d.path().join("vault/relay-private/credentials.v1.enc");
    let original = std::fs::read(&path).unwrap();
    assert!(s
        .command(json!({"op":"relay-credentials-write","data":"[]"}).to_string())
        .is_err());
    assert_eq!(std::fs::read(&path).unwrap(), original);
    let (other, foreign) = fixture();
    std::fs::create_dir(other.path().join("vault/relay-private")).unwrap();
    std::fs::write(
        other.path().join("vault/relay-private/credentials.v1.enc"),
        &original,
    )
    .unwrap();
    assert!(foreign
        .command(json!({"op":"relay-credentials-read"}).to_string())
        .is_err());
    let mut envelope: Value = serde_json::from_slice(&original).unwrap();
    let ciphertext = envelope["sealed"]["ciphertext"]
        .as_str()
        .unwrap()
        .to_string();
    let mut corrupt = ciphertext.into_bytes();
    corrupt[0] = if corrupt[0] == b'A' { b'B' } else { b'A' };
    envelope["sealed"]["ciphertext"] = String::from_utf8(corrupt).unwrap().into();
    std::fs::write(&path, envelope.to_string()).unwrap();
    assert!(s
        .command(json!({"op":"relay-credentials-read"}).to_string())
        .is_err());
    std::fs::write(&path, &original).unwrap();
    assert_eq!(
        call(&s, json!({"op":"relay-credentials-read"}))["data"],
        "{\"device\":\"original\"}"
    );
}
