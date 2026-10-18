use serde_json::{json, Value};
use vault_core::VaultSession;
fn call(s: &VaultSession, v: Value) -> Value {
    serde_json::from_str(&s.command(v.to_string()).unwrap()).unwrap()
}
fn setup(role: &str, device: &str) -> (tempfile::TempDir, VaultSession) {
    let dir = tempfile::tempdir().unwrap();
    let s = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    call(&s, json!({"op":"create","password":"fixture"}));
    call(
        &s,
        json!({"op":"relay-init","role":role,"device":device,"hub":"mac","group":"fixture"}),
    );
    for peer in ["mac", "phone", "tablet"] {
        if peer != device && (role == "hub" || peer == "mac") {
            call(&s, json!({"op":"relay-trust","peer":peer}));
        }
    }
    (dir, s)
}
fn save(s: &VaultSession, title: &str) {
    call(
        s,
        json!({"op":"save","item":{"id":"test","type":"password","title":title,"password":"RELAY-SECRET-CANARY"}}),
    );
}
fn send(a: &VaultSession, b: &VaultSession, from: &str, to: &str) {
    let packet = call(a, json!({"op":"relay-export","peer":to}));
    call(b, json!({"op":"relay-receive","peer":from,"packet":packet}));
}
fn title(s: &VaultSession) -> Value {
    call(s, json!({"op":"list"}))["items"][0]["title"].clone()
}
#[test]
fn bidirectional_retry_and_offline_conflict() {
    let (_d, mac) = setup("hub", "mac");
    let (_p, phone) = setup("mobile", "phone");
    save(&phone, "phone-first");
    send(&phone, &mac, "phone", "mac");
    send(&phone, &mac, "phone", "mac");
    send(&mac, &phone, "mac", "phone");
    assert_eq!(title(&mac), "phone-first");
    assert_eq!(call(&phone, json!({"op":"relay-status"}))["pending"], 0);
    save(&mac, "mac-edit");
    save(&phone, "phone-edit");
    send(&phone, &mac, "phone", "mac");
    send(&mac, &phone, "mac", "phone");
    assert_eq!(title(&phone), "phone-edit");
    assert_eq!(title(&mac), "mac-edit");
    let status = call(&mac, json!({"op":"relay-status"}));
    let id = status["conflicts"]
        .as_object()
        .unwrap()
        .keys()
        .next()
        .unwrap();
    call(
        &mac,
        json!({"op":"relay-resolve","conflict":id,"choice":"remote"}),
    );
    send(&mac, &phone, "mac", "phone");
    assert_eq!(title(&mac), "phone-edit");
    assert_eq!(call(&phone, json!({"op":"relay-status"}))["pending"], 0);
}
#[test]
fn deletion_survives_restart_and_stale_snapshot() {
    let (_d, mac) = setup("hub", "mac");
    let (d, phone) = setup("mobile", "phone");
    save(&mac, "initial");
    send(&mac, &phone, "mac", "phone");
    let old = call(&mac, json!({"op":"relay-export","peer":"phone"}));
    call(&phone, json!({"op":"remove","id":"test","richNotes":true}));
    drop(phone);
    let phone = VaultSession::new(d.path().to_string_lossy().into()).unwrap();
    call(&phone, json!({"op":"unlock","password":"fixture"}));
    send(&phone, &mac, "phone", "mac");
    send(&mac, &phone, "mac", "phone");
    call(
        &phone,
        json!({"op":"relay-receive","peer":"mac","packet":old}),
    );
    assert_eq!(call(&phone, json!({"op":"list"}))["items"], json!([]));
    let bytes = std::fs::read(d.path().join("vault/vault.sqlite")).unwrap();
    assert!(!bytes.windows(19).any(|w| w == b"RELAY-SECRET-CANARY"));
}
#[test]
fn unauthorized_and_mutated_retry_rejected_atomically() {
    let (_d, mac) = setup("hub", "mac");
    let (_p, phone) = setup("mobile", "phone");
    save(&phone, "initial");
    let mut packet = call(&phone, json!({"op":"relay-export","peer":"mac"}));
    assert!(mac
        .command(json!({"op":"relay-receive","peer":"intruder","packet":packet}).to_string())
        .is_err());
    send(&phone, &mac, "phone", "mac");
    packet["changes"][1]["value"]["title"] = json!("tampered");
    assert!(mac
        .command(json!({"op":"relay-receive","peer":"phone","packet":packet}).to_string())
        .is_err());
    assert_eq!(title(&mac), "initial");
    call(&mac, json!({"op":"relay-revoke","peer":"phone"}));
    assert!(mac
        .command(json!({"op":"relay-receive","peer":"phone","packet":packet}).to_string())
        .is_err());
}

#[test]
fn multi_phone_and_incremental_cursors_preserve_local_settings() {
    let (_d, mac) = setup("hub", "mac");
    let (_p, phone) = setup("mobile", "phone");
    let (_t, tablet) = setup("mobile", "tablet");
    save(&mac, "first");
    send(&mac, &phone, "mac", "phone");
    send(&phone, &mac, "phone", "mac");
    let delta = call(&mac, json!({"op":"relay-export","peer":"phone"}));
    assert!(delta["baseCursor"].as_u64().unwrap() > 0);
    assert_eq!(delta["records"], json!({}));
    save(&phone, "phone");
    send(&phone, &mac, "phone", "mac");
    send(&mac, &tablet, "mac", "tablet");
    assert_eq!(title(&tablet), "phone");
    assert_eq!(
        call(&tablet, json!({"op":"list"}))["settings"]["theme"],
        "system"
    );
}
#[test]
fn rich_attachment_missing_and_tampered_packets_are_atomic() {
    let (_d, mac) = setup("hub", "mac");
    let (_p, phone) = setup("mobile", "phone");
    call(
        &mac,
        json!({"op":"save","item":{"id":"note","type":"secureNote","title":"Rich"}}),
    );
    let meta: Value = serde_json::from_str(
        &mac.import_note_attachment(
            "note".into(),
            "fixture.txt".into(),
            "text/plain".into(),
            b"ATTACHMENT-CANARY".to_vec(),
        )
        .unwrap(),
    )
    .unwrap();
    let id = meta["id"].as_str().unwrap();
    call(
        &mac,
        json!({"op":"save","richNotes":true,"item":{"id":"note","type":"secureNote","title":"Rich","noteFormat":"rich-v1","noteDocument":{"type":"doc","content":[{"type":"vaultAttachment","attrs":{"attachmentId":id}}]}}}),
    );
    let packet = call(&mac, json!({"op":"relay-export","peer":"phone"}));
    let mut missing = packet.clone();
    missing["files"] = json!([]);
    assert!(phone
        .command(json!({"op":"relay-receive","peer":"mac","packet":missing}).to_string())
        .is_err());
    assert_eq!(call(&phone, json!({"op":"relay-status"}))["cursor"], 0);
    let mut bad = packet.clone();
    bad["files"][0]["data"] = json!("dGFtcGVy");
    assert!(phone
        .command(json!({"op":"relay-receive","peer":"mac","packet":bad}).to_string())
        .is_err());
    send(&mac, &phone, "mac", "phone");
    assert_eq!(
        phone
            .read_note_attachment("note".into(), id.into())
            .unwrap(),
        b"ATTACHMENT-CANARY"
    );
    call(&mac, json!({"op":"remove","richNotes":true,"id":"note"}));
    send(&mac, &phone, "mac", "phone");
    assert_eq!(call(&phone, json!({"op":"list"}))["items"], json!([]));
}
#[test]
fn initial_backup_and_plugin_write_are_captured() {
    let (dir, mac) = setup("hub", "mac");
    let (_p, phone) = setup("mobile", "phone");
    assert!(dir
        .path()
        .join("vault/before-personal-relay/vault.sqlite")
        .exists());
    let grant =
        vault_core::create_background_grant(dir.path().to_string_lossy().into(), "fixture".into())
            .unwrap();
    mac.background_save(grant,json!({"id":"11111111-1111-4111-a111-111111111111","origin":"https://example.test","username":"fixture","password":"PLUGIN-RELAY-CANARY"}).to_string()).unwrap();
    send(&mac, &phone, "mac", "phone");
    assert_eq!(
        call(&phone, json!({"op":"list"}))["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn conflict_keep_both_and_delete_edit_preserve_versions() {
    let (_d, mac) = setup("hub", "mac");
    let (_p, phone) = setup("mobile", "phone");
    save(&mac, "base");
    send(&mac, &phone, "mac", "phone");
    send(&phone, &mac, "phone", "mac");
    save(&mac, "local");
    save(&phone, "remote");
    send(&phone, &mac, "phone", "mac");
    let status = call(&mac, json!({"op":"relay-status"}));
    let id = status["conflicts"]
        .as_object()
        .unwrap()
        .keys()
        .next()
        .unwrap();
    assert_eq!(status["conflicts"][id]["local"]["title"], "local");
    call(
        &mac,
        json!({"op":"relay-resolve","conflict":id,"choice":"both"}),
    );
    send(&mac, &phone, "mac", "phone");
    assert_eq!(
        call(&phone, json!({"op":"list"}))["items"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    save(&mac, "new-local");
    call(&phone, json!({"op":"remove","richNotes":true,"id":"test"}));
    send(&phone, &mac, "phone", "mac");
    let status = call(&mac, json!({"op":"relay-status"}));
    let id = status["conflicts"]
        .as_object()
        .unwrap()
        .keys()
        .next()
        .unwrap();
    call(
        &mac,
        json!({"op":"relay-resolve","conflict":id,"choice":"both"}),
    );
    let items = call(&mac, json!({"op":"list"}))["items"]
        .as_array()
        .unwrap()
        .clone();
    assert!(items.iter().all(|i| i["id"] != "test"));
    assert!(items.iter().any(|i| i["title"] == "new-local"));
}

#[test]
fn detach_preserves_offline_edits_and_rejects_stale_scope() {
    let (dir, phone) = setup("mobile", "phone");
    save(&phone, "unsent local edit");
    assert!(phone
        .command(json!({"op":"relay-detach","group":"other","device":"phone"}).to_string())
        .is_err());
    assert_eq!(call(&phone, json!({"op":"relay-status"}))["enabled"], true);
    call(
        &phone,
        json!({"op":"relay-detach","group":"fixture","device":"phone"}),
    );
    assert_eq!(call(&phone, json!({"op":"relay-status"}))["enabled"], false);
    assert_eq!(title(&phone), "unsent local edit");
    assert!(phone
        .command(json!({"op":"relay-export","peer":"mac"}).to_string())
        .is_err());
    call(
        &phone,
        json!({"op":"relay-init","role":"mobile","group":"new","device":"new-phone","hub":"new-mac"}),
    );
    call(&phone, json!({"op":"relay-trust","peer":"new-mac"}));
    let packet = call(&phone, json!({"op":"relay-export","peer":"new-mac"}));
    assert_eq!(packet["group"], "new");
    assert!(packet["changes"]
        .as_array()
        .unwrap()
        .iter()
        .any(|c| c["value"]["title"] == "unsent local edit"));
    drop(phone);
    let phone = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    call(&phone, json!({"op":"unlock","password":"fixture"}));
    assert_eq!(title(&phone), "unsent local edit");
}

#[test]
fn batch_conflicts_are_atomic_scoped_and_clear_mobile_reminders() {
    for choice in ["local", "remote"] {
        let (_d, mac) = setup("hub", "mac");
        let (phone_dir, phone) = setup("mobile", "phone");
        let (_t, tablet) = setup("mobile", "tablet");
        for id in ["one", "two"] {
            for (session, title) in [(&mac, "Mac version"), (&phone, "Phone version")] {
                call(
                    session,
                    json!({"op":"save","item":{"id":id,"type":"secureNote","title":title}}),
                );
            }
        }
        send(&phone, &mac, "phone", "mac");
        send(&mac, &phone, "mac", "phone");
        send(&mac, &tablet, "mac", "tablet");
        assert_eq!(
            call(&phone, json!({"op":"relay-status"}))["conflictCount"],
            2
        );
        assert_eq!(
            call(&tablet, json!({"op":"relay-status"}))["conflictCount"],
            0
        );
        assert!(
            call(&mac, json!({"op":"relay-export","peer":"tablet"}))["conflicts"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        call(&phone, json!({"op":"lock"}));
        drop(phone);
        let phone = VaultSession::new(phone_dir.path().to_string_lossy().into()).unwrap();
        call(&phone, json!({"op":"unlock","password":"fixture"}));
        assert_eq!(
            call(&phone, json!({"op":"relay-status"}))["conflictCount"],
            2
        );
        let before = call(&mac, json!({"op":"relay-status"}));
        let ids: Vec<_> = before["conflicts"]
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect();
        for bad in [
            json!([ids[0], "missing"]),
            json!([ids[0], ids[0]]),
            json!([]),
        ] {
            assert!(mac
                .command(
                    json!({"op":"relay-resolve-batch","choice":choice,"conflicts":bad}).to_string()
                )
                .is_err());
            assert_eq!(call(&mac, json!({"op":"relay-status"})), before);
        }
        assert!(phone
            .command(
                json!({"op":"relay-resolve-batch","choice":choice,"conflicts":ids}).to_string()
            )
            .is_err());
        assert!(mac
            .command(
                json!({"op":"relay-resolve-batch","choice":"invalid","conflicts":ids}).to_string()
            )
            .is_err());
        // A new conflict arriving after the confirmation list was captured stays unresolved.
        for (s, title) in [(&mac, "Later Mac"), (&phone, "Later phone")] {
            call(
                s,
                json!({"op":"save","item":{"id":"later","type":"secureNote","title":title}}),
            );
        }
        send(&phone, &mac, "phone", "mac");
        call(
            &mac,
            json!({"op":"relay-resolve-batch","choice":choice,"conflicts":ids}),
        );
        send(&mac, &phone, "mac", "phone");
        let status = call(&phone, json!({"op":"relay-status"}));
        assert_eq!(status["pending"], 1);
        assert_eq!(status["conflictCount"], 1);
        let items = call(&phone, json!({"op":"list"}));
        for id in ["one", "two"] {
            let item = items["items"]
                .as_array()
                .unwrap()
                .iter()
                .find(|v| v["id"] == id)
                .unwrap();
            assert_eq!(
                item["title"],
                if choice == "local" {
                    "Mac version"
                } else {
                    "Phone version"
                }
            );
        }
        let rest: Vec<_> = call(&mac, json!({"op":"relay-status"}))["conflicts"]
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect();
        call(
            &mac,
            json!({"op":"relay-resolve-batch","choice":choice,"conflicts":rest}),
        );
        send(&mac, &phone, "mac", "phone");
        assert_eq!(
            call(&phone, json!({"op":"relay-status"}))["conflictCount"],
            0
        );
        assert_eq!(call(&phone, json!({"op":"relay-status"}))["pending"], 0);
    }
}

#[test]
fn older_snapshots_and_changed_pending_edits_do_not_show_false_conflicts() {
    let (_d, mac) = setup("hub", "mac");
    let (_p, phone) = setup("mobile", "phone");
    save(&mac, "Mac");
    save(&phone, "Phone");
    send(&phone, &mac, "phone", "mac");
    send(&mac, &phone, "mac", "phone");
    assert_eq!(
        call(&phone, json!({"op":"relay-status"}))["conflictCount"],
        1
    );
    save(&phone, "New edit");
    assert_eq!(
        call(&phone, json!({"op":"relay-status"}))["conflictCount"],
        0
    );
    let mut old = call(&mac, json!({"op":"relay-export","peer":"phone"}));
    old.as_object_mut().unwrap().remove("conflicts");
    call(
        &phone,
        json!({"op":"relay-receive","peer":"mac","packet":old}),
    );
    assert_eq!(
        call(&phone, json!({"op":"relay-status"}))["conflictCount"],
        0
    );
}

#[test]
fn batch_mobile_choice_rejects_ambiguous_multiple_phone_versions() {
    let (_d, mac) = setup("hub", "mac");
    let (_p, phone) = setup("mobile", "phone");
    let (_t, tablet) = setup("mobile", "tablet");
    save(&mac, "Mac");
    save(&phone, "Phone");
    save(&tablet, "Tablet");
    send(&phone, &mac, "phone", "mac");
    send(&tablet, &mac, "tablet", "mac");
    let before = call(&mac, json!({"op":"relay-status"}));
    let ids: Vec<_> = before["conflicts"]
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect();
    assert_eq!(ids.len(), 2);
    assert!(mac
        .command(json!({"op":"relay-resolve-batch","choice":"remote","conflicts":ids}).to_string())
        .is_err());
    assert_eq!(call(&mac, json!({"op":"relay-status"})), before);
    assert_eq!(title(&mac), "Mac");
    call(
        &mac,
        json!({"op":"relay-resolve-batch","choice":"local","conflicts":ids}),
    );
    send(&mac, &phone, "mac", "phone");
    send(&mac, &tablet, "mac", "tablet");
    assert_eq!(title(&phone), "Mac");
    assert_eq!(title(&tablet), "Mac");
}
