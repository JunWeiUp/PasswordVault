#![cfg(feature = "native")]
use serde_json::{json, Value};
use vault_core::*;
fn run(s: &VaultSession, v: Value) -> Result<Value> {
    Ok(serde_json::from_str(&s.command(v.to_string())?).unwrap())
}
fn fixture() -> (tempfile::TempDir, VaultSession) {
    let d = tempfile::tempdir().unwrap();
    let s = VaultSession::new(d.path().to_string_lossy().into()).unwrap();
    run(&s, json!({"op":"create","password":"fixture password"})).unwrap();
    (d, s)
}
fn enable(s: &VaultSession) {
    run(
        s,
        json!({"op":"devices-enable","confirm":true,"currentPassword":"fixture password"}),
    )
    .unwrap();
}
fn device() -> Value {
    json!({"id":"dev","type":"device","title":"Lab","device":{
    "version":1,"host":"lab.example.com","port":22,"username":"operator","authMethod":"password",
    "password":"DEVICE_SECRET_CANARY","privateKey":"","aliases":["lab"],"notes":"",
    "services":[],"commands":[],"files":[]}})
}
fn save(s: &VaultSession, item: Value) -> Result<Value> {
    run(s, json!({"op":"save","richNotes":true,"item":item}))
}

#[test]
fn upgrade_is_authenticated_snapshotted_and_explicit() {
    let (d, s) = fixture();
    assert!(matches!(
        save(&s, device()),
        Err(VaultError::DevicesUpgradeRequired)
    ));
    assert!(matches!(
        run(
            &s,
            json!({"op":"devices-enable","confirm":true,"currentPassword":"wrong"})
        ),
        Err(VaultError::Authentication)
    ));
    assert!(!d.path().join("vault/before-devices-format7").exists());
    assert_eq!(
        run(&s, json!({"op":"devices-status"})).unwrap()["enabled"],
        false
    );
    run(
        &s,
        json!({"op":"settings","settings":{"devicesEnabled":true}}),
    )
    .unwrap();
    assert!(matches!(
        save(&s, device()),
        Err(VaultError::DevicesUpgradeRequired)
    ));
    let before = std::fs::read(d.path().join("vault/vault.sqlite")).unwrap();
    enable(&s);
    assert_eq!(
        std::fs::read(d.path().join("vault/before-devices-format7/vault.sqlite")).unwrap(),
        before
    );
    assert_eq!(run(&s, json!({"op":"list"})).unwrap()["formatVersion"], 7);
    save(&s, device()).unwrap();
    save(&s, json!({"id":"other","type":"password","title":"Other"})).unwrap();
    drop(s);
    let s = VaultSession::new(d.path().to_string_lossy().into()).unwrap();
    run(&s, json!({"op":"unlock","password":"fixture password"})).unwrap();
    let list = run(&s, json!({"op":"list"})).unwrap();
    assert_eq!(list["items"][0]["device"], device()["device"]);
    assert_eq!(list["items"].as_array().unwrap().len(), 2);
}

#[test]
fn snapshot_collision_leaves_old_format_unchanged() {
    let (d, s) = fixture();
    std::fs::write(
        d.path().join("vault/before-devices-format7"),
        b"not a snapshot",
    )
    .unwrap();
    assert!(matches!(
        run(
            &s,
            json!({"op":"devices-enable","confirm":true,"currentPassword":"fixture password"})
        ),
        Err(VaultError::Storage)
    ));
    assert_eq!(
        run(&s, json!({"op":"devices-status"})).unwrap()["enabled"],
        false
    );
}

#[test]
fn archives_and_history_preserve_owned_inert_files() {
    for history in [false, true] {
        let (_d, s) = fixture();
        if history {
            run(&s, json!({"op":"history-enable"})).unwrap();
        }
        enable(&s);
        save(&s, device()).unwrap();
        let meta: Value = serde_json::from_str(
            &s.import_note_attachment(
                "dev".into(),
                "connect.command".into(),
                "application/octet-stream".into(),
                b"INERT_SCRIPT_CANARY".to_vec(),
            )
            .unwrap(),
        )
        .unwrap();
        let id = meta["id"].as_str().unwrap();
        let mut item = device();
        item["device"]["files"] = json!([{"attachmentId":id,"name":"connect.command","mime":"application/octet-stream","size":18}]);
        save(&s, item.clone()).unwrap();
        assert_eq!(
            run(
                &s,
                json!({"op":"devices-file-read","id":"dev","attachmentId":id})
            )
            .unwrap()["text"],
            "INERT_SCRIPT_CANARY"
        );
        assert!(run(
            &s,
            json!({"op":"devices-file-read","id":"wrong","attachmentId":id})
        )
        .is_err());
        run(
            &s,
            json!({"op":"collect-note-attachments","richNotes":true}),
        )
        .unwrap();
        assert_eq!(
            s.read_note_attachment("dev".into(), id.into()).unwrap(),
            b"INERT_SCRIPT_CANARY"
        );
        assert!(s.read_note_attachment("wrong".into(), id.into()).is_err());
        assert!(s.discard_note_attachment("dev".into(), id.into()).is_err());
        let content = run(
            &s,
            json!({"op":"export","richNotes":true,"password":"backup password"}),
        )
        .unwrap()["content"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(
            serde_json::from_str::<Value>(&content).unwrap()["version"],
            if history { 4 } else { 3 }
        );
        assert!(!content.contains("DEVICE_SECRET_CANARY"));
        let d = tempfile::tempdir().unwrap();
        let restored = VaultSession::new(d.path().to_string_lossy().into()).unwrap();
        run(&restored,json!({"op":"create-from-backup","richNotes":true,"content":content,"backupPassword":"backup password","password":"restored"})).unwrap();
        assert_eq!(
            run(&restored, json!({"op":"list"})).unwrap()["items"][0]["device"],
            item["device"]
        );
        assert_eq!(
            restored
                .read_note_attachment("dev".into(), id.into())
                .unwrap(),
            b"INERT_SCRIPT_CANARY"
        );
        let mut forged = device();
        forged["id"] = json!("other-device");
        forged["device"]["files"] = item["device"]["files"].clone();
        assert!(save(&s, forged).is_err());
        if history {
            save(&s, device()).unwrap();
            run(
                &s,
                json!({"op":"collect-note-attachments","richNotes":true}),
            )
            .unwrap();
            assert_eq!(
                s.read_note_attachment("dev".into(), id.into()).unwrap(),
                b"INERT_SCRIPT_CANARY"
            );
        }
    }
}

#[test]
fn sync_gate_cannot_be_bypassed_by_claimed_peer_capabilities() {
    let (_d, s) = fixture();
    enable(&s);
    for op in [
        "relay-peer-export",
        "relay-request",
        "relay-apply",
        "sync-request",
        "relay-peer-receive",
    ] {
        assert!(
            matches!(
                run(&s, json!({"op":op,"peerFormat":7})),
                Err(VaultError::DevicesSyncBlocked)
            ),
            "{op}"
        );
    }
    assert!(guard_device_sync(7, "relay-status").is_ok());
    assert!(guard_device_sync(7, "relay-credentials-read").is_ok());
    assert!(guard_device_sync(6, "relay-peer-export").is_ok());
}

#[test]
fn validation_exports_search_and_format_guards() {
    let mut doc = Document {
        format_version: 7,
        ..Document::default()
    };
    doc.upsert(device()).unwrap();
    assert!(!export_csv(&doc).unwrap().contains("Lab"));
    assert!(seal_share(&device(), &["title".into()], &[]).is_err());
    assert!(!device_search_text(&device()).contains("device_secret_canary"));
    assert!(device_search_text(&device()).contains("lab.example.com"));
    let mut bad = device();
    bad["device"]["port"] = json!(0);
    assert!(doc.upsert(bad).is_err());
    let mut old = Document::default();
    assert!(matches!(
        old.merge(doc),
        Err(VaultError::DevicesUpgradeRequired)
    ));
    assert!(matches!(
        Document::parse(br#"{"formatVersion":8,"items":[]}"#),
        Err(VaultError::UpdateRequired)
    ));
}

fn relay_pair() -> (
    tempfile::TempDir,
    VaultSession,
    tempfile::TempDir,
    VaultSession,
) {
    use base64::Engine;
    let (a, mac) = fixture();
    let (b, phone) = fixture();
    let mac_key = crypto_box::SecretKey::from([11u8; 32]);
    let phone_key = crypto_box::SecretKey::from([22u8; 32]);
    for (session, id, role, key, peer, public, nsh) in [
        (
            &mac,
            "mac",
            "hub",
            &mac_key,
            "phone",
            phone_key.public_key(),
            true,
        ),
        (
            &phone,
            "phone",
            "mobile",
            &phone_key,
            "mac",
            mac_key.public_key(),
            false,
        ),
    ] {
        run(
            session,
            json!({"op":"relay-init","role":role,"group":"synthetic","device":id,"hub":"mac"}),
        )
        .unwrap();
        let roster = json!({"trusted_peers":{peer:hex::encode(public.as_bytes())}});
        let mut config = json!({"group":"synthetic","device":id,"secret":hex::encode(key.to_bytes()),"peers":{}});
        if nsh {
            config["secret"] =
                json!(base64::engine::general_purpose::STANDARD.encode(key.to_bytes()));
            config["groupState"] = json!(base64::engine::general_purpose::STANDARD
                .encode(serde_json::to_vec(&roster).unwrap()));
        } else {
            config["groups"] = roster;
        }
        run(
            session,
            json!({"op":"relay-credentials-write","data":config.to_string()}),
        )
        .unwrap();
    }
    (a, mac, b, phone)
}
fn negotiate(a: &VaultSession, aid: &str, b: &VaultSession, bid: &str) -> Value {
    let challenge = run(a, json!({"op":"relay-capabilities-challenge","peer":bid})).unwrap();
    assert_eq!(
        challenge,
        run(a, json!({"op":"relay-capabilities-challenge","peer":bid})).unwrap()
    );
    let proof = run(
        b,
        json!({"op":"relay-capabilities-prove","peer":aid,"challenge":challenge["challenge"]}),
    )
    .unwrap();
    let accept = json!({"op":"relay-capabilities-accept","peer":bid,"proof":proof["proof"]});
    run(a, accept.clone()).unwrap();
    assert!(matches!(
        run(a, accept.clone()),
        Err(VaultError::Authentication)
    ));
    accept
}
fn transfer(a: &VaultSession, aid: &str, b: &VaultSession, bid: &str) {
    let packet = run(a, json!({"op":"relay-export","peer":bid})).unwrap();
    assert_eq!(packet["version"], 2);
    run(b, json!({"op":"relay-receive","peer":aid,"packet":packet})).unwrap();
}
#[test]
fn authenticated_format7_relay_preserves_devices_files_conflicts_and_deletion() {
    let (_a, mac, _b, phone) = relay_pair();
    enable(&mac);
    save(&mac, device()).unwrap();
    let meta: Value = serde_json::from_str(
        &mac.import_note_attachment(
            "dev".into(),
            "data".into(),
            "text/plain".into(),
            b"inert".to_vec(),
        )
        .unwrap(),
    )
    .unwrap();
    let mut item = device();
    item["device"]["files"] =
        json!([{"attachmentId":meta["id"],"name":"data","mime":"text/plain","size":5}]);
    save(&mac, item).unwrap();
    // Group membership allows negotiation before any account-data grant.
    negotiate(&mac, "mac", &phone, "phone");
    negotiate(&phone, "phone", &mac, "mac");
    assert!(matches!(
        run(&mac, json!({"op":"relay-export","peer":"phone"})),
        Err(VaultError::Authentication)
    ));
    run(&mac, json!({"op":"relay-trust","peer":"phone"})).unwrap();
    run(&phone, json!({"op":"relay-trust","peer":"mac"})).unwrap();
    transfer(&mac, "mac", &phone, "phone");
    let phone_list = run(&phone, json!({"op":"list"})).unwrap();
    assert_eq!(phone_list["formatVersion"], 7);
    assert_eq!(
        phone_list["items"][0]["device"],
        run(&mac, json!({"op":"list"})).unwrap()["items"][0]["device"]
    );
    assert_eq!(
        phone
            .read_note_attachment("dev".into(), meta["id"].as_str().unwrap().into())
            .unwrap(),
        b"inert"
    );
    transfer(&phone, "phone", &mac, "mac");
    let mut local = phone_list["items"][0].clone();
    local["title"] = json!("mac edit");
    save(&mac, local.clone()).unwrap();
    local["title"] = json!("phone edit");
    save(&phone, local).unwrap();
    transfer(&phone, "phone", &mac, "mac");
    let status = run(&mac, json!({"op":"relay-status"})).unwrap();
    let conflict = status["conflicts"]
        .as_object()
        .unwrap()
        .keys()
        .next()
        .unwrap();
    run(
        &mac,
        json!({"op":"relay-resolve","conflict":conflict,"choice":"both"}),
    )
    .unwrap();
    transfer(&mac, "mac", &phone, "phone");
    let list = run(&phone, json!({"op":"list"})).unwrap();
    assert_eq!(list["items"].as_array().unwrap().len(), 2);
    for item in list["items"].as_array().unwrap() {
        let id = item["id"].as_str().unwrap();
        let attachment = item["device"]["files"][0]["attachmentId"].as_str().unwrap();
        assert_eq!(
            phone
                .read_note_attachment(id.into(), attachment.into())
                .unwrap(),
            b"inert"
        );
    }
    let mut deleted = list["items"][0].clone();
    deleted["isDeleted"] = json!(true);
    save(&mac, deleted.clone()).unwrap();
    transfer(&mac, "mac", &phone, "phone");
    assert!(run(&phone, json!({"op":"list"})).unwrap()["items"]
        .as_array()
        .unwrap()
        .iter()
        .any(|i| i["id"] == deleted["id"] && i["isDeleted"] == true));
}
#[test]
fn format7_relay_rejects_forged_replayed_and_rotated_capabilities_and_legacy_packets() {
    let (_a, mac, _b, phone) = relay_pair();
    enable(&mac);
    run(&mac, json!({"op":"relay-trust","peer":"phone"})).unwrap();
    run(&phone, json!({"op":"relay-trust","peer":"mac"})).unwrap();
    assert!(matches!(
        run(
            &mac,
            json!({"op":"relay-export","peer":"phone","supportsFormat7":true})
        ),
        Err(VaultError::DevicesSyncBlocked)
    ));
    let challenge = run(
        &mac,
        json!({"op":"relay-capabilities-challenge","peer":"phone"}),
    )
    .unwrap();
    let wrong = run(
        &phone,
        json!({"op":"relay-capabilities-prove","peer":"mac","challenge":"wrong-challenge"}),
    )
    .unwrap();
    assert!(matches!(
        run(
            &mac,
            json!({"op":"relay-capabilities-accept","peer":"phone","proof":wrong["proof"]})
        ),
        Err(VaultError::Authentication)
    ));
    let proof = run(
        &phone,
        json!({"op":"relay-capabilities-prove","peer":"mac","challenge":challenge["challenge"]}),
    )
    .unwrap();
    run(
        &mac,
        json!({"op":"relay-capabilities-accept","peer":"phone","proof":proof["proof"]}),
    )
    .unwrap();
    let packet = run(&phone, json!({"op":"relay-export","peer":"mac"})).unwrap();
    assert_eq!(packet["version"], 1);
    let before = run(&mac, json!({"op":"list"})).unwrap();
    assert!(matches!(
        run(
            &mac,
            json!({"op":"relay-receive","peer":"phone","packet":packet})
        ),
        Err(VaultError::DevicesSyncBlocked)
    ));
    assert_eq!(before, run(&mac, json!({"op":"list"})).unwrap());
    let old = run(&mac, json!({"op":"relay-credentials-read"})).unwrap()["data"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut changed: Value = serde_json::from_str(&old).unwrap();
    changed["secret"] = json!(hex::encode([33u8; 32]));
    run(
        &mac,
        json!({"op":"relay-credentials-write","data":changed.to_string()}),
    )
    .unwrap();
    run(&mac, json!({"op":"relay-credentials-write","data":old})).unwrap();
    assert!(
        run(&mac, json!({"op":"relay-status"})).unwrap()["capabilities"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(matches!(
        run(&mac, json!({"op":"relay-export","peer":"phone"})),
        Err(VaultError::DevicesSyncBlocked)
    ));
    negotiate(&mac, "mac", &phone, "phone");
    run(&mac, json!({"op":"relay-revoke","peer":"phone"})).unwrap();
    run(&mac, json!({"op":"relay-trust","peer":"phone"})).unwrap();
    assert!(matches!(
        run(&mac, json!({"op":"relay-export","peer":"phone"})),
        Err(VaultError::DevicesSyncBlocked)
    ));
}
