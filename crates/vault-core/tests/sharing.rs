use serde_json::{json, Value};
use vault_core::*;
fn session(dir: &tempfile::TempDir) -> VaultSession {
    let s = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    call(
        &s,
        json!({"op":"create","password":"Synthetic sharing fixture 24"}),
    )
    .unwrap();
    s
}
fn call(s: &VaultSession, v: Value) -> Result<Value> {
    Ok(serde_json::from_str(&s.command(v.to_string())?).unwrap())
}
fn identity(s: &VaultSession) -> String {
    call(s, json!({"op":"identity"})).unwrap()["publicKey"]
        .as_str()
        .unwrap()
        .into()
}
fn roundtrip(owner: &VaultSession, member: &VaultSession, owner_key: &str, vault: &str) -> Value {
    let packet = call(
        member,
        json!({"op":"sync-request","peerKey":owner_key,"vaultId":vault}),
    )
    .unwrap();
    call(owner, json!({"op":"sync-respond","packet":packet})).unwrap()
}
#[test]
fn sharing_enforces_roles_replay_binding_and_revocation() {
    let da = tempfile::tempdir().unwrap();
    let db = tempfile::tempdir().unwrap();
    let dc = tempfile::tempdir().unwrap();
    let a = session(&da);
    let b = session(&db);
    let c = session(&dc);
    let ak = identity(&a);
    let bk = identity(&b);
    let ck = identity(&c);
    let vault = call(
        &a,
        json!({"op":"create-shared","name":"Synthetic family","time":"2020-01-01T00:00:00Z"}),
    )
    .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    call(
        &a,
        json!({"op":"add-member","vaultId":vault,"publicKey":bk,"role":"viewer"}),
    )
    .unwrap();
    call(
        &a,
        json!({"op":"add-member","vaultId":vault,"publicKey":ck,"role":"editor"}),
    )
    .unwrap();
    let item = json!({"id":"shared-record","type":"secureNote","title":"Synthetic","note":"PRIVATE-SYNC-CANARY","sharedVaultId":vault,"updatedAt":"2020-01-01T00:00:00Z"});
    call(&a, json!({"op":"save","item":item})).unwrap();
    let response = roundtrip(&a, &b, &ak, &vault);
    assert!(!response.to_string().contains("PRIVATE-SYNC-CANARY"));
    let before = call(&b, json!({"op":"list"})).unwrap();
    assert!(call(
        &b,
        json!({"op":"sync-apply","packet":response,"peerKey":ck,"vaultId":vault})
    )
    .is_err());
    assert_eq!(before, call(&b, json!({"op":"list"})).unwrap());
    call(
        &b,
        json!({"op":"sync-apply","packet":response,"peerKey":ak,"vaultId":vault}),
    )
    .unwrap();
    assert!(call(
        &b,
        json!({"op":"sync-apply","packet":response,"peerKey":ak,"vaultId":vault})
    )
    .is_err());
    assert!(call(&b, json!({"op":"save","item":item})).is_err());
    assert!(call(&b, json!({"op":"remove","id":"shared-record"})).is_err());
    assert!(call(
        &b,
        json!({"op":"add-member","vaultId":vault,"publicKey":ck,"role":"editor"})
    )
    .is_err());
    let response = roundtrip(&a, &c, &ak, &vault);
    call(
        &c,
        json!({"op":"sync-apply","packet":response,"peerKey":ak,"vaultId":vault}),
    )
    .unwrap();
    let mut edited = item.clone();
    edited["note"] = json!("Updated fixture");
    edited["updatedAt"] = json!("2020-01-02T00:00:00Z");
    call(&c, json!({"op":"save","item":edited})).unwrap();
    let response = roundtrip(&a, &c, &ak, &vault);
    call(
        &c,
        json!({"op":"sync-apply","packet":response,"peerKey":ak,"vaultId":vault}),
    )
    .unwrap();
    assert_eq!(
        call(&a, json!({"op":"list"})).unwrap()["items"][0]["note"],
        "Updated fixture"
    );
    call(
        &a,
        json!({"op":"remove-member","vaultId":vault,"publicKey":bk}),
    )
    .unwrap();
    let request = call(
        &b,
        json!({"op":"sync-request","peerKey":ak,"vaultId":vault}),
    )
    .unwrap();
    assert!(call(&a, json!({"op":"sync-respond","packet":request})).is_err());
    let response = roundtrip(&a, &c, &ak, &vault);
    call(
        &c,
        json!({"op":"sync-apply","packet":response,"peerKey":ak,"vaultId":vault}),
    )
    .unwrap();
    assert!(!call(&c, json!({"op":"list"})).unwrap()["sharedMembers"]
        .as_array()
        .unwrap()
        .iter()
        .any(|m| m["userPublicKey"] == bk));
}
#[test]
fn encrypted_restore_preserves_identity_and_stale_settings_cannot_replace_it() {
    let da = tempfile::tempdir().unwrap();
    let db = tempfile::tempdir().unwrap();
    let a = session(&da);
    let b = session(&db);
    let ak = identity(&a);
    call(
        &a,
        json!({"op":"create-shared","name":"Fixture","time":"2020-01-01T00:00:00Z"}),
    )
    .unwrap();
    let content = call(
        &a,
        json!({"op":"export","password":"Backup fixture passphrase"}),
    )
    .unwrap()["content"]
        .clone();
    call(
        &b,
        json!({"op":"import","content":content,"password":"Backup fixture passphrase"}),
    )
    .unwrap();
    assert_eq!(identity(&b), ak);
    call(&b,json!({"op":"settings","settings":{"sharingIdentity":{"publicKey":"attacker"},"syncSeen":[],"autoLockMinutes":5}})).unwrap();
    assert_eq!(identity(&b), ak);
    call(&b, json!({"op":"lock"})).unwrap();
    assert!(b.unlock_biometric(vec![0; 32]).is_err());
    assert!(call(&b, json!({"op":"list"})).is_err());
}
