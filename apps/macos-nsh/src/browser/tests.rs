static TEST_SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());
use super::*;
#[path = "grants.rs"]
mod grants;
struct Fixture {
    dir: PathBuf,
    session: vault_core::VaultSession,
}
impl Fixture {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("pv-nsh-browser-{}", uuid::Uuid::new_v4()));
        let session = vault_core::VaultSession::new(dir.to_string_lossy().into()).unwrap();
        command(
            &session,
            json!({"op":"create","password":"synthetic-browser-test"}),
        )
        .unwrap();
        Self { dir, session }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}
fn message(op: &str, token: &str) -> Value {
    json!({"extensionOrigin":"chrome-extension://test/","request":{"version":2,"token":token,"syncToken":"00","op":op,"origin":"https://example.com"}})
}
#[test]
fn replay_status_pairings_and_lock() {
    let _serial = TEST_SERIAL.lock().unwrap();
    let f = Fixture::new();
    command(
        &f.session,
        json!({"op":"settings","settings":{"browserPairings":{"test":["first","second"]}}}),
    )
    .unwrap();
    assert_eq!(
        dispatch(&f.session, "test", message("status", "second")).unwrap()["paired"],
        true
    );
    assert_eq!(
        dispatch(&f.session, "test", message("matches", "wrong")).unwrap_err(),
        "unpaired"
    );
    assert!(dispatch(&f.session, "test", message("matches", "first")).unwrap()["data"].is_array());
    assert_eq!(
        dispatch(&f.session, "test", message("export", "first")).unwrap_err(),
        "unsupported"
    );
    dispatch(&f.session, "test", message("lock", "first")).unwrap();
    for _ in 0..3 {
        assert_eq!(
            dispatch(&f.session, "test", message("status", "first")).unwrap()["unlocked"],
            false
        );
    }
    assert_eq!(
        dispatch(&f.session, "test", message("fill", "first")).unwrap_err(),
        "locked"
    );
}
#[test]
fn legacy_tokens_and_scope_are_preserved() {
    let _serial = TEST_SERIAL.lock().unwrap();
    assert!(wire::paired(
        &json!({"browserPairings":{"test":"legacy"}}),
        "test",
        "legacy"
    ));
    assert!(!wire::paired(
        &json!({"browserPairings":{"test":[""]}}),
        "test",
        ""
    ));
    let auth = grants::decode(&[7; 64]).unwrap();
    assert!(!auth.read);
    assert!(!auth.startup);
    assert!(grants::decode(b"garbage").is_err());
}
#[test]
fn reject_privileged_browser_inputs_and_frames() {
    let _serial = TEST_SERIAL.lock().unwrap();
    for op in [
        "authorized-fill",
        "authorized-matches",
        "desktop-auto-unlock",
    ] {
        assert_eq!(
            wire::browser_request(&mut json!({"version":2,"op":op})).unwrap_err(),
            "unsupported"
        );
    }
    let mut value = json!({"version":2,"op":"fill","_backgroundGrant":"injected"});
    wire::browser_request(&mut value).unwrap();
    assert!(value.get("_backgroundGrant").is_none());
    for prefix in [0u32, 65537, u32::MAX] {
        assert!(wire::read(&mut &prefix.to_le_bytes()[..], 65536).is_err());
    }
    assert!(wire::read(&mut &[3, 0, 0, 0, b'{'][..], 65536).is_err());
}
#[test]
fn registration_only_uses_explicit_temporary_home() {
    let _serial = TEST_SERIAL.lock().unwrap();
    let f = Fixture::new();
    let helper = f.dir.join("Preview.app/Contents/MacOS/pv-browser-host");
    for browser in wire::BROWSERS {
        wire::registration(&f.dir, browser, &helper, "test", true).unwrap();
        let path = wire::manifest_path(&f.dir, browser).unwrap();
        let value: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(value["name"], wire::HOST);
        assert_eq!(value["allowed_origins"][0], "chrome-extension://test/");
        assert!(
            wire::registration(&f.dir, browser, Path::new("/another/helper"), "test", false)
                .is_err()
        );
        wire::registration(&f.dir, browser, &helper, "test", false).unwrap();
        assert!(!path.exists());
    }
    assert!(wire::manifest_path(&f.dir, "../../escape").is_err());
}
#[test]
fn revoked_background_grant_cannot_save_or_read() {
    let _serial = TEST_SERIAL.lock().unwrap();
    use base64::Engine;
    let f = Fixture::new();
    let grant = vault_core::create_background_grant(
        f.dir.to_string_lossy().into(),
        "synthetic-browser-test".into(),
    )
    .unwrap();
    command(&f.session, json!({"op":"lock"})).unwrap();
    let mut request = message("sync-save", "");
    request["request"]["id"] = uuid::Uuid::new_v4().to_string().into();
    request["request"]["username"] = "synthetic".into();
    request["request"]["password"] = "synthetic-only".into();
    request["request"]["_backgroundGrant"] = base64::engine::general_purpose::STANDARD
        .encode(&grant)
        .into();
    assert_eq!(
        dispatch(&f.session, "test", request.clone()).unwrap()["ok"],
        true
    );
    assert_eq!(
        dispatch(&f.session, "test", request.clone()).unwrap()["ok"],
        true
    );
    assert_eq!(
        dispatch(&f.session, "test", message("status", "")).unwrap()["unlocked"],
        false
    );
    vault_core::revoke_background_grants(f.dir.to_string_lossy().into()).unwrap();
    assert_eq!(
        dispatch(&f.session, "test", request.clone()).unwrap_err(),
        "sync-authorization"
    );
    request["request"]["op"] = "authorized-matches".into();
    assert_eq!(
        dispatch(&f.session, "test", request).unwrap_err(),
        "sync-authorization"
    );
}
#[test]
fn replay_save_fill_deduplicates_without_overwriting() {
    let _serial = TEST_SERIAL.lock().unwrap();
    let f = Fixture::new();
    command(
        &f.session,
        json!({"op":"settings","settings":{"browserPairings":{"test":"paired"}}}),
    )
    .unwrap();
    let mut request = message("save", "paired");
    request["request"]["username"] = "example-user".into();
    request["request"]["password"] = "example-password".into();
    assert_eq!(
        dispatch(&f.session, "test", request.clone()).unwrap()["ok"],
        true
    );
    assert_eq!(
        dispatch(&f.session, "test", request.clone()).unwrap()["ok"],
        true
    );
    let accounts = dispatch(&f.session, "test", message("matches", "paired")).unwrap();
    assert_eq!(accounts["data"].as_array().unwrap().len(), 1);
    request["request"]["password"] = "changed-example-password".into();
    dispatch(&f.session, "test", request).unwrap();
    let accounts = dispatch(&f.session, "test", message("matches", "paired")).unwrap();
    assert_eq!(accounts["data"].as_array().unwrap().len(), 2);
    let mut fill = message("fill", "paired");
    fill["request"]["id"] = accounts["data"][0]["id"].clone();
    fill["request"]["accountId"] = accounts["data"][0]["accountId"].clone();
    assert!(dispatch(&f.session, "test", fill.clone()).unwrap()["data"]["password"].is_string());
    fill["request"]["origin"] = "https://unrelated.example.org".into();
    assert!(dispatch(&f.session, "test", fill).is_err());
}
#[test]
fn startup_without_nonce_and_wrong_peer_fail_closed() {
    let _serial = TEST_SERIAL.lock().unwrap();
    let f = Fixture::new();
    let mut request = message("desktop-auto-unlock", "");
    request["request"]["nonce"] = "never-issued".into();
    assert_eq!(
        dispatch(&f.session, "test", request).unwrap_err(),
        "sync-authorization"
    );
    let (left, _right) = std::os::unix::net::UnixStream::pair().unwrap();
    assert!(!security::peer(
        left.as_raw_fd(),
        &f.dir.join("missing-helper")
    ));
}
#[test]
fn approval_is_bound_to_its_request() {
    let _serial = TEST_SERIAL.lock().unwrap();
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    *PENDING.lock().unwrap() = Some(Pending {
        id: "test".into(),
        challenge: "current".into(),
        reply: tx,
    });
    Browser::approve("expired".into(), true);
    assert!(rx.try_recv().is_err());
    Browser::approve("current".into(), false);
    assert_eq!(rx.recv().unwrap(), false);
    PENDING.lock().unwrap().take();
}
#[test]
fn startup_challenge_is_consumed_once_and_manual_lock_cancels_it() {
    let _serial = TEST_SERIAL.lock().unwrap();
    use base64::Engine;
    let f=Fixture::new();let grant=vault_core::create_background_grant(f.dir.to_string_lossy().into(),"synthetic-browser-test".into()).unwrap();
    command(&f.session,json!({"op":"lock"})).unwrap();
    let mut request=message("desktop-auto-unlock","");request["request"]["nonce"]="one-use".into();request["request"]["_backgroundGrant"]=base64::engine::general_purpose::STANDARD.encode(grant).into();
    *STARTUP.lock().unwrap()=Some("one-use".into());
    assert_eq!(dispatch(&f.session,"test",request.clone()).unwrap()["ok"],true);
    command(&f.session,json!({"op":"lock"})).unwrap();
    assert_eq!(dispatch(&f.session,"test",request.clone()).unwrap_err(),"sync-authorization");
    *STARTUP.lock().unwrap()=Some("one-use".into());Browser::cancel_startup();
    assert_eq!(dispatch(&f.session,"test",request).unwrap_err(),"sync-authorization");
    assert_eq!(dispatch(&f.session,"test",message("status","")).unwrap()["unlocked"],false);
}
