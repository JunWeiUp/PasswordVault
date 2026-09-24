use serde_json::{json, Value};
use vault_core::*;

const PASSWORD: &str = "Synthetic category fixture 24!";
fn call(session: &VaultSession, request: Value) -> Result<Value> {
    Ok(serde_json::from_str(&session.command(request.to_string())?).unwrap())
}
fn create(folder: &tempfile::TempDir) -> VaultSession {
    let session = VaultSession::new(folder.path().to_string_lossy().into()).unwrap();
    call(&session, json!({"op":"create","password":PASSWORD})).unwrap();
    session
}
fn remove(session: &VaultSession, name: &str) -> Result<Value> {
    call(
        session,
        json!({"op":"category-remove","name":name,"time":"2020-02-01T00:00:00Z"}),
    )
}

#[test]
fn empty_categories_survive_reopen_and_encrypted_backup_without_plaintext_leaks() {
    let folder = tempfile::tempdir().unwrap();
    let session = create(&folder);
    let category = "PRIVATE-CATEGORY-CANARY";
    call(
        &session,
        json!({"op":"category-add","name":format!(" {category} ")}),
    )
    .unwrap();
    let doc = call(&session, json!({"op":"list"})).unwrap();
    assert_eq!(doc["items"], json!([]));
    assert_eq!(doc["settings"]["noteCategories"], json!([category]));
    let backup = call(&session, json!({"op":"export","password":PASSWORD})).unwrap();
    assert!(!backup.to_string().contains(category));
    let bytes = std::fs::read(folder.path().join("vault/vault.sqlite")).unwrap();
    assert!(!bytes
        .windows(category.len())
        .any(|window| window == category.as_bytes()));
    drop(session);
    let reopened = VaultSession::new(folder.path().to_string_lossy().into()).unwrap();
    call(&reopened, json!({"op":"unlock","password":PASSWORD})).unwrap();
    assert_eq!(call(&reopened, json!({"op":"list"})).unwrap(), doc);
    let restored_folder = tempfile::tempdir().unwrap();
    let restored = create(&restored_folder);
    call(
        &restored,
        json!({"op":"import","content":backup["content"],"password":PASSWORD}),
    )
    .unwrap();
    assert_eq!(
        call(&restored, json!({"op":"list"})).unwrap()["settings"]["noteCategories"],
        json!([category])
    );
}

#[test]
fn deleting_a_legacy_category_keeps_live_and_trashed_notes_and_unrelated_accounts() {
    let folder = tempfile::tempdir().unwrap();
    let session = create(&folder);
    let legacy = json!({"items":[
        {"id":"note","type":"secureNote","title":"Note","category":"家庭","note":"Keep this body","futureField":{"keep":true}},
        {"id":"trash","type":"secureNote","title":"Trash","category":"家庭","isDeleted":true,"note":"Keep trashed body"},
        {"id":"account","type":"password","title":"Account","category":"家庭","password":"Synthetic only"}
    ]});
    call(
        &session,
        json!({"op":"import","content":legacy.to_string()}),
    )
    .unwrap();
    call(&session, json!({"op":"category-add","name":"Empty folder"})).unwrap();
    assert_eq!(remove(&session, "家庭").unwrap()["updated"], 2);
    let doc = call(&session, json!({"op":"list"})).unwrap();
    assert_eq!(doc["items"].as_array().unwrap().len(), 3);
    assert_eq!(doc["items"][0]["category"], "");
    assert_eq!(doc["items"][0]["note"], "Keep this body");
    assert_eq!(doc["items"][0]["futureField"]["keep"], true);
    assert_eq!(doc["items"][1]["category"], "");
    assert_eq!(doc["items"][1]["isDeleted"], true);
    assert_eq!(doc["items"][2]["category"], "家庭");
    assert_eq!(doc["settings"]["noteCategories"], json!(["Empty folder"]));
}

#[test]
fn category_removal_cannot_bypass_shared_note_permissions_or_partially_edit_notes() {
    let folder = tempfile::tempdir().unwrap();
    let session = create(&folder);
    let mut incoming = Document::default();
    let own = sharing_identity(&mut incoming).unwrap();
    incoming
        .shared_members
        .push(json!({"id":"member","vaultId":"shared","userPublicKey":own,"role":"viewer"}));
    incoming.items = vec![
        json!({"id":"personal","type":"secureNote","title":"Personal","category":"家庭","note":"Preserve"}),
        json!({"id":"shared-note","type":"secureNote","title":"Shared","category":"家庭","sharedVaultId":"shared"}),
    ];
    call(
        &session,
        json!({"op":"import","content":serde_json::to_string(&incoming).unwrap()}),
    )
    .unwrap();
    let before = call(&session, json!({"op":"list"})).unwrap();
    assert!(matches!(
        remove(&session, "家庭"),
        Err(VaultError::Authentication)
    ));
    assert_eq!(call(&session, json!({"op":"list"})).unwrap(), before);
}

#[test]
fn category_validation_and_stale_settings_preserve_existing_folders() {
    let folder = tempfile::tempdir().unwrap();
    let session = create(&folder);
    call(&session, json!({"op":"category-add","name":"Travel"})).unwrap();
    for name in ["travel", " Travel "] {
        assert!(matches!(
            call(&session, json!({"op":"category-add","name":name})),
            Err(VaultError::AlreadyExists)
        ));
    }
    for name in [" ".to_owned(), "a\nb".to_owned(), "长".repeat(81)] {
        assert!(call(&session, json!({"op":"category-add","name":name})).is_err());
    }
    call(
        &session,
        json!({"op":"settings","settings":{"noteCategories":[],"theme":"dark"}}),
    )
    .unwrap();
    assert_eq!(
        call(&session, json!({"op":"list"})).unwrap()["settings"]["noteCategories"],
        json!(["Travel"])
    );
    call(&session, json!({"op":"lock"})).unwrap();
    assert!(matches!(
        call(&session, json!({"op":"category-add","name":"Blocked"})),
        Err(VaultError::Locked)
    ));
    assert!(matches!(
        remove(&session, "Travel"),
        Err(VaultError::Locked)
    ));
}
