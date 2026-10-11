use serde_json::{json, Value};
use vault_core::*;
const PASSWORD: &str = "Synthetic sync fixture password";
const ID: &str = "11111111-1111-4111-a111-111111111111";
fn call(s: &VaultSession, v: Value) -> Value {
    serde_json::from_str(&s.command(v.to_string()).unwrap()).unwrap()
}
fn login() -> Value {
    json!({"id":ID,"origin":"https://example.test","username":"fixture","password":"SYNC-SECRET-CANARY"})
}
fn setup() -> (tempfile::TempDir, VaultSession, Vec<u8>) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_string_lossy().to_string();
    let session = VaultSession::new(path.clone()).unwrap();
    call(&session, json!({"op":"create","password":PASSWORD}));
    let grant = create_background_grant(path, PASSWORD.into()).unwrap();
    (dir, session, grant)
}
#[test]
fn quit_reopen_encrypted_write_and_retry_without_unlocking() {
    let (dir, s, g) = setup();
    drop(s);
    let path = dir.path().to_string_lossy().to_string();
    let s = VaultSession::new(path.clone()).unwrap();
    s.background_save(g.clone(), login().to_string()).unwrap();
    s.background_save(g.clone(), login().to_string()).unwrap();
    assert_eq!(call(&s, json!({"op":"status"}))["unlocked"], false);
    assert!(s.command(json!({"op":"list"}).to_string()).is_err());
    drop(s);
    let bytes = std::fs::read(dir.path().join("vault/vault.sqlite")).unwrap();
    assert!(!bytes.windows(18).any(|b| b == b"SYNC-SECRET-CANARY"));
    let s = VaultSession::new(path).unwrap();
    call(&s, json!({"op":"unlock","password":PASSWORD}));
    assert_eq!(
        call(&s, json!({"op":"list"}))["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    call(&s, json!({"op":"remove","id":format!("browser-sync-{ID}")}));
    s.background_save(g, login().to_string()).unwrap();
    assert_eq!(
        call(&s, json!({"op":"list"}))["items"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
}
#[test]
fn wrong_password_tamper_rotation_and_revocation_fail_closed() {
    let (dir, s, g) = setup();
    let path = dir.path().to_string_lossy().to_string();
    assert!(create_background_grant(path.clone(), "wrong".into()).is_err());
    let mut bad = g.clone();
    bad[32] ^= 1;
    assert!(s.background_save(bad, login().to_string()).is_err());
    revoke_background_grants(path.clone()).unwrap();
    assert!(!background_grant_valid(path.clone(), g.clone()).unwrap());
    assert!(s.background_save(g, login().to_string()).is_err());
    let g = create_background_grant(path.clone(), PASSWORD.into()).unwrap();
    call(
        &s,
        json!({"op":"change-password","currentPassword":PASSWORD,"newPassword":"replacement synthetic"}),
    );
    assert!(!background_grant_valid(path, g.clone()).unwrap());
    assert!(s.background_save(g, login().to_string()).is_err());
}
#[test]
fn invalid_requests_and_failed_writes_preserve_lock_state_and_data() {
    let (dir, s, g) = setup();
    call(&s, json!({"op":"lock"}));
    for origin in [
        "file:///tmp/a",
        "https://user:pass@example.test",
        "https://example.test/path",
        "https://example.test/?a=1",
    ] {
        let mut req = login();
        req["origin"] = json!(origin);
        assert!(s.background_save(g.clone(), req.to_string()).is_err());
    }
    assert!(s
        .background_save(g.clone(), json!({"op":"list"}).to_string())
        .is_err());
    assert_eq!(call(&s, json!({"op":"status"}))["unlocked"], false);
    // Force an actual SQLite write failure without changing the original database.
    let db = dir.path().join("vault/vault.sqlite");
    let held = dir.path().join("vault/held.sqlite");
    std::fs::rename(&db, &held).unwrap();
    assert!(s.background_save(g.clone(), login().to_string()).is_err());
    assert_eq!(call(&s, json!({"op":"status"}))["unlocked"], false);
    std::fs::rename(held, db).unwrap();
    s.background_save(g, login().to_string()).unwrap();
}
#[test]
fn live_edits_dedup_and_conflicts_preserve_single_owner() {
    let (dir, s, g) = setup();
    assert!(VaultSession::new(dir.path().to_string_lossy().to_string()).is_err());
    call(
        &s,
        json!({"op":"save","item":{"id":"note","type":"secureNote","title":"keep","note":"live edit"}}),
    );
    s.background_save(g.clone(), login().to_string()).unwrap();
    let mut second = login();
    second["id"] = json!("22222222-2222-4222-a222-222222222222");
    s.background_save(g.clone(), second.to_string()).unwrap();
    second["password"] = json!("changed");
    second["id"] = json!("33333333-3333-4333-a333-333333333333");
    s.background_save(g, second.to_string()).unwrap();
    let doc = call(&s, json!({"op":"list"}));
    assert_eq!(doc["items"].as_array().unwrap().len(), 3);
    assert_eq!(doc["items"][0]["note"], "live edit");
    assert_eq!(call(&s, json!({"op":"status"}))["unlocked"], true);
}

#[test]
fn authorized_reads_remain_scoped_and_do_not_unlock_the_desktop() {
    let (dir, s, g) = setup();
    s.background_save(g.clone(), login().to_string()).unwrap();
    call(&s, json!({"op":"lock"}));
    let matches: Value = serde_json::from_str(
        &s.authorized_browser_command(
            g.clone(),
            json!({"op":"matches","origin":"https://example.test"}).to_string(),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(matches.as_array().unwrap().len(), 1);
    let fill =
        json!({"op":"fill","origin":"https://example.test","id":format!("browser-sync-{ID}")});
    let secret: Value = serde_json::from_str(
        &s.authorized_browser_command(g.clone(), fill.to_string())
            .unwrap(),
    )
    .unwrap();
    assert_eq!(secret["password"], login()["password"]);
    assert_eq!(call(&s, json!({"op":"status"}))["unlocked"], false);
    for op in ["list", "export", "save", "unlock", "change-password"] {
        assert!(s
            .authorized_browser_command(g.clone(), json!({"op":op}).to_string())
            .is_err());
    }
    assert!(s
        .authorized_browser_command(
            g.clone(),
            json!({"op":"fill","origin":"https://other.test","id":format!("browser-sync-{ID}")})
                .to_string()
        )
        .is_err());
    assert_eq!(call(&s, json!({"op":"status"}))["unlocked"], false);
    s.unlock_desktop_grant(g.clone()).unwrap();
    assert_eq!(call(&s, json!({"op":"status"}))["unlocked"], true);
    call(
        &s,
        json!({"op":"change-password","currentPassword":PASSWORD,"newPassword":"New fictional password"}),
    );
    call(&s, json!({"op":"lock"}));
    assert!(s.unlock_desktop_grant(g.clone()).is_err());
    assert!(s.authorized_browser_command(g, fill.to_string()).is_err());
    let fresh = create_background_grant(
        dir.path().to_string_lossy().into(),
        "New fictional password".into(),
    )
    .unwrap();
    revoke_background_grants(dir.path().to_string_lossy().into()).unwrap();
    assert!(s.unlock_desktop_grant(fresh).is_err());
}
