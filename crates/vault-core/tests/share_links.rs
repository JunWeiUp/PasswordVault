use serde_json::json;
use vault_core::*;

#[test]
fn opens_public_webcrypto_interoperability_vector() {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/share-v1.json")).unwrap();
    assert_eq!(
        open_share(&fixture["envelope"], fixture["key"].as_str().unwrap()).unwrap(),
        fixture["plaintext"]
    );
}

#[test]
fn share_snapshot_only_contains_selected_fields_and_authenticates_identity() {
    let item = json!({"id":"fixture","type":"password","title":"Fixture","username":"fictional","password":"SHARE_SECRET_CANARY","passwordHistory":[{"password":"OLD_SECRET_CANARY"}],"secret":"OTP_CANARY"});
    let fields = vec!["title".into(), "username".into(), "password".into()];
    let envelope = seal_share(&item, &fields, &[]).unwrap();
    assert!(!envelope.to_string().contains("CANARY"));
    let key = envelope["key"].as_str().unwrap();
    let clear = open_share(&envelope, key).unwrap();
    assert_eq!(clear["fields"]["password"], "SHARE_SECRET_CANARY");
    assert!(clear["fields"].get("passwordHistory").is_none());
    assert!(clear["fields"].get("secret").is_none());
    assert!(seal_share(&item, &["passwordHistory".into()], &[]).is_err());
    assert!(seal_share(&item, &["passkeys".into()], &[]).is_err());
    let mut changed = envelope.clone();
    changed["id"] = json!("0".repeat(32));
    assert!(open_share(&changed, key).is_err());
    changed = envelope.clone();
    changed["version"] = json!(2);
    assert!(open_share(&changed, key).is_err());
}

#[test]
fn share_commands_require_unlock_and_bind_attachment_ownership() {
    let dir = tempfile::tempdir().unwrap();
    let session = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    let call = |input: serde_json::Value| session.command(input.to_string());
    assert!(call(json!({"op":"share-options","id":"note"})).is_err());
    call(json!({"op":"create","password":"fixture"})).unwrap();
    call(json!({"op":"save","item":{"id":"note","type":"secureNote","title":"Fixture","note":"body"}})).unwrap();
    assert!(call(
        json!({"op":"share-seal","id":"note","fields":["note"],"attachmentIds":["foreign"]})
    )
    .is_err());
    let response = call(json!({"op":"share-seal","id":"note","fields":["note"]})).unwrap();
    let envelope: serde_json::Value = serde_json::from_str(&response).unwrap();
    assert_eq!(
        open_share(&envelope, envelope["key"].as_str().unwrap()).unwrap()["fields"]["note"],
        "body"
    );
    call(json!({"op":"lock"})).unwrap();
    assert!(call(json!({"op":"share-seal","id":"note","fields":["note"]})).is_err());
}

#[test]
fn structured_share_groups_are_opt_in_and_never_include_import_provenance() {
    let item = json!({"id":"synthetic","type":"creditCard","title":"Synthetic card","card":{"number":"TEST-CARD","securityCode":"TEST-CODE"},"customFields":[{"id":"f","label":"Hidden","kind":"concealed","value":"SYNTHETIC-HIDDEN"}],"importSource":{"raw":"DO_NOT_SHARE"}});
    let envelope = seal_share(&item, &["title".into()], &[]).unwrap();
    let clear = open_share(&envelope, envelope["key"].as_str().unwrap()).unwrap();
    assert!(clear["fields"].get("card").is_none());
    assert!(clear["fields"].get("customFields").is_none());
    let envelope = seal_share(&item, &["card".into(), "customFields".into()], &[]).unwrap();
    let clear = open_share(&envelope, envelope["key"].as_str().unwrap()).unwrap();
    assert_eq!(clear["fields"]["card"]["securityCode"], "TEST-CODE");
    assert!(clear["fields"].get("importSource").is_none());
    assert!(seal_share(&item, &["importSource".into()], &[]).is_err());
}
