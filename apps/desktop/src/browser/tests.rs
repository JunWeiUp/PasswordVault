static TEST_SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());
use super::*;
#[path = "grants.rs"]
mod grants;
struct Fixture {
    dir: PathBuf,
    session: crate::session::VaultSession,
}
impl Fixture {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("pv-nsh-browser-{}", uuid::Uuid::new_v4()));
        let session = crate::session::VaultSession::new(dir.to_string_lossy().into()).unwrap();
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
    let revision = || serde_json::from_str::<Value>(&poll_native()).unwrap()["revision"].as_u64().unwrap();
    let start = revision();
    assert_eq!(
        dispatch(&f.session, "test", request.clone()).unwrap()["ok"],
        true
    );
    assert_eq!(revision(), start + 1);
    assert_eq!(
        dispatch(&f.session, "test", request.clone()).unwrap()["ok"],
        true
    );
    assert_eq!(
        dispatch(&f.session, "test", message("status", "")).unwrap()["unlocked"],
        false
    );
    // An idempotent replay also reports saved; at most one extra merge refresh.
    let after = revision();
    assert!(after >= start + 1);
    vault_core::revoke_background_grants(f.dir.to_string_lossy().into()).unwrap();
    assert_eq!(
        dispatch(&f.session, "test", request.clone()).unwrap_err(),
        "sync-authorization"
    );
    assert_eq!(revision(), after);
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
fn extension_save_advances_poll_revision_only_on_write() {
    let _serial = TEST_SERIAL.lock().unwrap();
    let f = Fixture::new();
    command(
        &f.session,
        json!({"op":"settings","settings":{"browserPairings":{"test":"paired"}}}),
    )
    .unwrap();
    let revision = || serde_json::from_str::<Value>(&poll_native()).unwrap()["revision"].as_u64().unwrap();
    let start = revision();
    assert_eq!(serde_json::from_str::<Value>(&poll_native()).unwrap()["pending"], "");
    dispatch(&f.session, "test", message("matches", "paired")).unwrap();
    assert_eq!(revision(), start);
    let mut request = message("save", "paired");
    request["request"]["username"] = "example-user".into();
    request["request"]["password"] = "example-password".into();
    dispatch(&f.session, "test", request.clone()).unwrap();
    assert_eq!(revision(), start + 1);
    // Identical retry is acknowledged without a write, so no UI refresh.
    dispatch(&f.session, "test", request.clone()).unwrap();
    assert_eq!(revision(), start + 1);
    request["request"]["token"] = "unpaired".into();
    request["request"]["password"] = "other-password".into();
    assert!(dispatch(&f.session, "test", request).is_err());
    assert_eq!(revision(), start + 1);
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
        kind: "pair",
        detail: String::new(),
        reply: tx,
    });
    approve_native("expired".into(), true);
    assert!(rx.try_recv().is_err());
    approve_native("current".into(), false);
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
    *STARTUP.lock().unwrap()=Some("one-use".into());cancel_startup_native();
    assert_eq!(dispatch(&f.session,"test",request).unwrap_err(),"sync-authorization");
    assert_eq!(dispatch(&f.session,"test",message("status","")).unwrap()["unlocked"],false);
}

#[test]
fn ego_registration_uses_the_actual_profile_not_a_stale_manifest_directory() {
    let fixture = Fixture::new();
    let home = &fixture.dir;
    let support = home.join("Library/Application Support");
    let legacy = support.join("ego lite");
    std::fs::create_dir_all(legacy.join("NativeMessagingHosts")).unwrap();
    let canonical = support.join("Citro Labs/ego lite");
    let expected = canonical
        .join("NativeMessagingHosts")
        .join(format!("{}.json", wire::HOST));
    assert_eq!(wire::manifest_path(home, "ego lite").unwrap(), expected);
    // An actual old profile may still be used, until the canonical profile
    // exists. Merely retaining an old registration must never win priority.
    std::fs::write(legacy.join("Local State"), b"{}").unwrap();
    assert!(wire::manifest_path(home, "ego lite")
        .unwrap()
        .starts_with(&legacy));
    std::fs::create_dir_all(canonical.join("Default")).unwrap();
    assert_eq!(wire::manifest_path(home, "ego lite").unwrap(), expected);
}

/// Answer the next consent prompt from a separate thread, as the window would.
fn answer(allow: bool) -> std::thread::JoinHandle<Value> {
    std::thread::spawn(move || {
        for _ in 0..500 {
            let shown = pending_native();
            if !shown.is_empty() {
                let prompt: Value = serde_json::from_str(&shown).unwrap();
                approve_native(prompt["challenge"].as_str().unwrap().into(), allow);
                return prompt;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("no consent prompt");
    })
}
fn paired_with_account(f: &Fixture) -> Value {
    command(
        &f.session,
        json!({"op":"settings","settings":{"browserPairings":{"test":"paired"}}}),
    )
    .unwrap();
    let mut save = message("save", "paired");
    save["request"]["username"] = "example-user".into();
    save["request"]["password"] = "old-example-password".into();
    dispatch(&f.session, "test", save).unwrap();
    dispatch(&f.session, "test", message("matches", "paired")).unwrap()["data"][0].clone()
}
fn stored_password(f: &Fixture, account: &Value) -> Value {
    let mut fill = message("fill", "paired");
    fill["request"]["id"] = account["id"].clone();
    fill["request"]["accountId"] = account["accountId"].clone();
    dispatch(&f.session, "test", fill).unwrap()["data"]["password"].clone()
}
#[test]
fn update_login_requires_window_consent_and_ownership() {
    let _serial = TEST_SERIAL.lock().unwrap();
    let f = Fixture::new();
    let account = paired_with_account(&f);
    let mut update = message("update-login", "paired");
    update["request"]["id"] = account["id"].clone();
    update["request"]["username"] = "example-user".into();
    update["request"]["password"] = "new-example-password".into();
    let prompt = answer(false);
    assert_eq!(dispatch(&f.session, "test", update.clone()).unwrap_err(), "cancelled");
    let prompt = prompt.join().unwrap();
    assert_eq!(prompt["kind"], "update-login");
    assert_eq!(prompt["detail"], "https://example.com\nexample-user");
    assert!(!prompt.to_string().contains("new-example-password"));
    assert_eq!(stored_password(&f, &account), "old-example-password");
    let start = serde_json::from_str::<Value>(&poll_native()).unwrap()["revision"].as_u64().unwrap();
    let prompt = answer(true);
    assert_eq!(dispatch(&f.session, "test", update.clone()).unwrap()["ok"], true);
    prompt.join().unwrap();
    assert_eq!(stored_password(&f, &account), "new-example-password");
    assert_eq!(
        serde_json::from_str::<Value>(&poll_native()).unwrap()["revision"].as_u64().unwrap(),
        start + 1
    );
    // Another website's record is rejected before any prompt is shown.
    update["request"]["origin"] = "https://unrelated.example.org".into();
    assert_eq!(dispatch(&f.session, "test", update.clone()).unwrap_err(), "invalid-entry");
    assert_eq!(pending_native(), "");
    update["request"]["origin"] = "https://example.com".into();
    update["request"]["token"] = "unpaired".into();
    assert_eq!(dispatch(&f.session, "test", update).unwrap_err(), "unpaired");
}
#[test]
fn open_entry_queues_one_navigation_for_owned_records_only() {
    let _serial = TEST_SERIAL.lock().unwrap();
    let f = Fixture::new();
    let account = paired_with_account(&f);
    let mut open = message("open-entry", "paired");
    open["request"]["id"] = "missing-record".into();
    assert_eq!(dispatch(&f.session, "test", open.clone()).unwrap_err(), "invalid-entry");
    open["request"]["id"] = account["id"].clone();
    assert_eq!(dispatch(&f.session, "test", open).unwrap()["data"]["opened"], true);
    let state: Value = serde_json::from_str(&poll_native()).unwrap();
    assert_eq!(state["open"]["id"], account["id"]);
    assert!(state["open"]["nonce"].is_string());
    NAVIGATE.lock().unwrap().take();
}
#[test]
fn otp_and_structured_secrets_need_consent() {
    let _serial = TEST_SERIAL.lock().unwrap();
    let f = Fixture::new();
    paired_with_account(&f);
    assert!(dispatch(&f.session, "test", message("otp-matches", "paired")).unwrap()["data"].is_array());
    assert_eq!(pending_native(), "");
    let mut otp = message("otp-fill", "paired");
    otp["request"]["id"] = "any".into();
    let prompt = answer(false);
    assert_eq!(dispatch(&f.session, "test", otp).unwrap_err(), "cancelled");
    assert_eq!(prompt.join().unwrap()["kind"], "otp-fill");
    let prompt = answer(true);
    assert!(dispatch(&f.session, "test", message("structured-list", "paired")).unwrap()["data"].is_array());
    assert_eq!(prompt.join().unwrap()["kind"], "structured-list");
    let mut fill = message("structured-fill", "paired");
    fill["request"]["id"] = "any".into();
    fill["request"]["origin"] = "http://example.com".into();
    assert_eq!(dispatch(&f.session, "test", fill).unwrap_err(), "invalid-request");
    assert_eq!(pending_native(), "");
}
#[test]
fn startup_owner_key_isolates_adhoc_spoofing_and_tampered_binaries_while_preserving_signed_identity() {
    let _serial = TEST_SERIAL.lock().unwrap();
    let f = Fixture::new();
    let compile = |name: &str, marker: &str| {
        let src = f.dir.join(format!("{name}.c"));
        let bin = f.dir.join(name);
        std::fs::write(
            &src,
            format!("const char marker[64] = \"{marker}\";\nint main(void){{return marker[0];}}\n"),
        )
        .unwrap();
        assert!(
            std::process::Command::new("/usr/bin/clang")
                .args([src.to_str().unwrap(), "-o", bin.to_str().unwrap()])
                .status()
                .unwrap()
                .success()
        );
        bin
    };
    let sign = |bin: &Path, identity: &str, extra: &[&str]| {
        let mut cmd = std::process::Command::new("/usr/bin/codesign");
        cmd.args(["-f", "--identifier", "pv-browser-host-test", "-s", identity]);
        cmd.args(extra);
        cmd.arg(bin);
        cmd.output().unwrap().status.success()
    };
    let b1 = compile("helper-v1", "MARKER_BUILD_ONE");
    let b2 = compile("helper-v2", "MARKER_BUILD_TWO");
    // Ad-hoc builds isolate per binary CDHash even if given an identical custom requirement.
    let custom = ["-r=designated => identifier \"pv-browser-host-test\""];
    assert!(sign(&b1, "-", &custom));
    assert!(sign(&b2, "-", &custom));
    let adhoc1 = security::signing_identity(&b1).unwrap();
    let adhoc2 = security::signing_identity(&b2).unwrap();
    assert_eq!(Some(adhoc1.clone()), security::code_hash(&b1));
    assert_ne!(adhoc1, adhoc2);
    assert_ne!(
        grants::desktop_key(&f.dir, &adhoc1),
        grants::desktop_key(&f.dir, &adhoc2)
    );
    // Certificate-signed macOS system binaries carry a certificate chain, so their
    // signing_identity uses the designated requirement rather than raw CDHash.
    let sys_req = security::signing_identity(Path::new("/bin/ls")).unwrap();
    assert_ne!(Some(sys_req.clone()), security::code_hash(Path::new("/bin/ls")));
    assert_eq!(
        grants::desktop_key(&f.dir, &sys_req),
        grants::desktop_key(&f.dir, &sys_req)
    );
    assert_ne!(
        grants::desktop_key(&f.dir, &sys_req),
        grants::desktop_key(&f.dir.join("other-vault"), &sys_req)
    );
    // If a local Apple Development certificate is available, verify two distinct
    // compiled binaries produce different CDHashes yet identical signing_identity.
    let found = std::process::Command::new("/usr/bin/security")
        .args(["find-identity", "-v", "-p", "codesigning"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| {
            s.lines().find_map(|line| {
                let start = line.find("\"Apple Development:")? + 1;
                let end = start + line[start..].find('"')?;
                Some(line[start..end].to_string())
            })
        });
    if let Some(cert) = found {
        assert!(sign(&b1, &cert, &["--options", "runtime", "--timestamp=none"]));
        assert!(sign(&b2, &cert, &["--options", "runtime", "--timestamp=none"]));
        assert_ne!(security::code_hash(&b1), security::code_hash(&b2));
        let cert1 = security::signing_identity(&b1).unwrap();
        let cert2 = security::signing_identity(&b2).unwrap();
        assert_eq!(cert1, cert2);
        assert_eq!(
            grants::desktop_key(&f.dir, &cert1),
            grants::desktop_key(&f.dir, &cert2)
        );
    }
    // Post-signing code tampering must fail closed.
    assert!(sign(&b1, "-", &[]));
    let mut bytes = std::fs::read(&b1).unwrap();
    let pos = bytes
        .windows(b"MARKER_BUILD_ONE".len())
        .position(|w| w == b"MARKER_BUILD_ONE")
        .unwrap();
    bytes[pos] ^= 0xff;
    std::fs::write(&b1, bytes).unwrap();
    assert!(security::signing_identity(&b1).is_none());
}
