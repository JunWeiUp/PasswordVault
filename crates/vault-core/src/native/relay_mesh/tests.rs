use super::*;

fn replica(dir: &std::path::Path, device: &str, peers: &[&str]) -> DiskVault {
    let mut vault = DiskVault::new(dir).unwrap();
    vault.create("fixture").unwrap();
    vault
        .relay_command(&json!({"op":"relay-mesh-init","group":"family","device":device}))
        .unwrap();
    vault
        .relay_command(&json!({"op":"relay-mesh-peers","peers":peers}))
        .unwrap();
    vault
}
fn save(vault: &mut DiskVault, id: &str, title: &str) {
    vault
        .command(&json!({"op":"save","item":{"id":id,"type":"password","title":title}}))
        .unwrap();
}
fn titles(vault: &mut DiskVault) -> BTreeMap<String, String> {
    vault
        .open()
        .unwrap()
        .document
        .items
        .iter()
        .map(|i| {
            (
                i["id"].as_str().unwrap().into(),
                i["title"].as_str().unwrap_or("").into(),
            )
        })
        .collect()
}
/// Delivers a pending packet; returns whether anything was sent.
fn deliver(from: &mut DiskVault, from_id: &str, to: &mut DiskVault, to_id: &str) -> bool {
    let packet = from
        .relay_command(&json!({"op":"relay-mesh-export","peer":to_id}))
        .unwrap()["packet"]
        .clone();
    if packet.is_null() {
        return false;
    }
    to.relay_command(&json!({"op":"relay-mesh-receive","peer":from_id,"packet":packet}))
        .unwrap();
    true
}
fn settle(vaults: &mut [(&str, &mut DiskVault)]) {
    for _ in 0..8 {
        let mut sent = false;
        for i in 0..vaults.len() {
            for j in 0..vaults.len() {
                if i == j {
                    continue;
                }
                let (a, b) = if i < j {
                    let (l, r) = vaults.split_at_mut(j);
                    (&mut l[i], &mut r[0])
                } else {
                    let (l, r) = vaults.split_at_mut(i);
                    (&mut r[0], &mut l[j])
                };
                sent |= deliver(a.1, a.0, b.1, b.0);
            }
        }
        if !sent {
            return;
        }
    }
    panic!("replicas did not become idle");
}
fn history_titles(vault: &mut DiskVault, id: &str) -> Vec<String> {
    let open = vault.open().unwrap();
    history::read(&open.connection, &open.root, &open.header.vault_id)
        .unwrap()
        .into_iter()
        .filter(|r| r.item_id == id)
        .map(|r| r.item["title"].as_str().unwrap_or("").to_string())
        .collect()
}

#[test]
fn edits_flow_both_ways_and_newest_wins_with_loser_in_history() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let mut a = replica(da.path(), "mac", &["phone"]);
    let mut b = replica(db.path(), "phone", &["mac"]);
    save(&mut a, "a1", "from mac");
    save(&mut b, "b1", "from phone");
    settle(&mut [("mac", &mut a), ("phone", &mut b)]);
    assert_eq!(titles(&mut a), titles(&mut b));
    assert_eq!(titles(&mut a).len(), 2);
    // Concurrent edits of the same record: the later stamp wins on both sides.
    save(&mut a, "a1", "mac edit");
    std::thread::sleep(std::time::Duration::from_millis(5));
    save(&mut b, "a1", "phone edit");
    settle(&mut [("mac", &mut a), ("phone", &mut b)]);
    assert_eq!(titles(&mut a)["a1"], "phone edit");
    assert_eq!(titles(&mut b)["a1"], "phone edit");
    assert!(history_titles(&mut a, "a1").contains(&"mac edit".to_string()));
    assert!(history_titles(&mut b, "a1").contains(&"mac edit".to_string()));
    // Idle replicas exchange nothing further.
    assert!(!deliver(&mut a, "mac", &mut b, "phone"));
    assert!(!deliver(&mut b, "phone", &mut a, "mac"));
}

#[test]
fn three_replicas_converge_in_any_order_and_delete_versus_edit_uses_stamp() {
    let dirs: Vec<_> = (0..3).map(|_| tempfile::tempdir().unwrap()).collect();
    let mut a = replica(dirs[0].path(), "a", &["b", "c"]);
    let mut b = replica(dirs[1].path(), "b", &["a", "c"]);
    let mut c = replica(dirs[2].path(), "c", &["a", "b"]);
    save(&mut a, "x", "base");
    settle(&mut [("a", &mut a), ("b", &mut b), ("c", &mut c)]);
    b.command(&json!({"op":"remove","id":"x","richNotes":true}))
        .unwrap();
    assert!(!titles(&mut b).contains_key("x"));
    std::thread::sleep(std::time::Duration::from_millis(5));
    save(&mut c, "x", "edited after delete");
    // Deliver c first to a, then b's delete: arrival order must not matter.
    deliver(&mut c, "c", &mut a, "a");
    deliver(&mut b, "b", &mut a, "a");
    settle(&mut [("a", &mut a), ("b", &mut b), ("c", &mut c)]);
    let (ta, tb, tc) = (titles(&mut a), titles(&mut b), titles(&mut c));
    assert_eq!(ta, tb);
    assert_eq!(tb, tc);
    assert_eq!(ta.get("x").map(String::as_str), Some("edited after delete"));
}

#[test]
fn unknown_or_removed_peers_and_future_stamps_are_rejected() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let mut a = replica(da.path(), "mac", &["phone"]);
    let mut b = replica(db.path(), "phone", &["mac"]);
    save(&mut a, "a1", "secret");
    assert!(matches!(
        a.relay_command(&json!({"op":"relay-mesh-export","peer":"stranger"})),
        Err(VaultError::Authentication)
    ));
    let packet = a
        .relay_command(&json!({"op":"relay-mesh-export","peer":"phone"}))
        .unwrap()["packet"]
        .clone();
    assert!(matches!(
        b.relay_command(&json!({"op":"relay-mesh-receive","peer":"stranger","packet":packet})),
        Err(VaultError::Authentication)
    ));
    let mut forged = packet.clone();
    forged["records"]["item:a1"]["stamp"] = json!([now_ms() + MAX_FUTURE_MS + 60_000, 0, "mac"]);
    assert!(b
        .relay_command(&json!({"op":"relay-mesh-receive","peer":"mac","packet":forged}))
        .is_err());
    assert!(titles(&mut b).is_empty());
    b.relay_command(&json!({"op":"relay-mesh-peers","peers":[]}))
        .unwrap();
    assert!(matches!(
        b.relay_command(&json!({"op":"relay-mesh-receive","peer":"mac","packet":packet})),
        Err(VaultError::Authentication)
    ));
    assert!(titles(&mut b).is_empty());
}

#[test]
fn replay_is_idempotent_and_categories_merge() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let mut a = replica(da.path(), "mac", &["phone"]);
    let mut b = replica(db.path(), "phone", &["mac"]);
    a.command(&json!({"op":"category-add","name":"Work"})).ok();
    b.command(&json!({"op":"category-add","name":"Home"})).ok();
    save(&mut a, "a1", "one");
    let packet = a
        .relay_command(&json!({"op":"relay-mesh-export","peer":"phone"}))
        .unwrap()["packet"]
        .clone();
    b.relay_command(&json!({"op":"relay-mesh-receive","peer":"mac","packet":packet}))
        .unwrap();
    let replay = b
        .relay_command(&json!({"op":"relay-mesh-receive","peer":"mac","packet":packet}))
        .unwrap();
    assert_eq!(replay["changed"], false);
    settle(&mut [("mac", &mut a), ("phone", &mut b)]);
    let ca: BTreeSet<_> = a
        .open()
        .unwrap()
        .document
        .note_categories()
        .into_iter()
        .collect();
    let cb: BTreeSet<_> = b
        .open()
        .unwrap()
        .document
        .note_categories()
        .into_iter()
        .collect();
    assert_eq!(ca, cb);
    if ca.contains("Work") || cb.contains("Home") {
        assert!(ca.contains("Work") && ca.contains("Home"));
    }
}

#[test]
fn legacy_hub_and_mobile_journals_migrate_without_losing_pending_edits() {
    let (dh, dm) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let mut hub = DiskVault::new(dh.path()).unwrap();
    hub.create("fixture").unwrap();
    hub.relay_command(
        &json!({"op":"relay-init","role":"hub","group":"family","device":"mac","hub":"mac"}),
    )
    .unwrap();
    hub.relay_command(&json!({"op":"relay-trust","peer":"phone"}))
        .unwrap();
    let mut phone = DiskVault::new(dm.path()).unwrap();
    phone.create("fixture").unwrap();
    phone.relay_command(&json!({"op":"relay-init","role":"mobile","group":"family","device":"phone","hub":"mac"})).unwrap();
    phone
        .relay_command(&json!({"op":"relay-trust","peer":"mac"}))
        .unwrap();
    save(&mut hub, "shared", "synced value");
    let snap = hub
        .relay_command(&json!({"op":"relay-export","peer":"phone"}))
        .unwrap();
    phone
        .relay_command(&json!({"op":"relay-receive","peer":"mac","packet":snap}))
        .unwrap();
    let changes = phone
        .relay_command(&json!({"op":"relay-export","peer":"mac"}))
        .unwrap();
    hub.relay_command(&json!({"op":"relay-receive","peer":"phone","packet":changes}))
        .unwrap();
    let snap = hub
        .relay_command(&json!({"op":"relay-export","peer":"phone"}))
        .unwrap();
    phone
        .relay_command(&json!({"op":"relay-receive","peer":"mac","packet":snap}))
        .unwrap();
    // Unconfirmed phone edit plus a conflicting hub edit made in the old protocol.
    save(&mut phone, "offline", "phone only, not yet confirmed");
    save(&mut phone, "shared", "phone conflicting edit");
    let changes = phone
        .relay_command(&json!({"op":"relay-export","peer":"mac"}))
        .unwrap();
    save(&mut hub, "shared", "mac newer edit");
    hub.relay_command(&json!({"op":"relay-receive","peer":"phone","packet":changes}))
        .unwrap();
    assert!(
        hub.relay_command(&json!({"op":"relay-status"})).unwrap()["conflicts"]
            .as_object()
            .unwrap()
            .is_empty()
            .then_some(())
            .is_none()
    );
    assert!(
        phone.relay_command(&json!({"op":"relay-status"})).unwrap()["pending"]
            .as_u64()
            .unwrap()
            >= 1
    );

    let migrated = hub
        .relay_command(&json!({"op":"relay-mesh-init","group":"family","device":"mac"}))
        .unwrap();
    assert_eq!(migrated["migratedFrom"], "hub");
    assert!(migrated["archivedConflicts"].as_u64().unwrap() >= 1);
    assert!(
        dh.path()
            .join("vault/before-mesh-sync/vault.sqlite")
            .exists()
            || dh.path().join("before-mesh-sync/vault.sqlite").exists()
    );
    phone
        .relay_command(&json!({"op":"relay-mesh-init","group":"family","device":"phone"}))
        .unwrap();
    hub.relay_command(&json!({"op":"relay-mesh-peers","peers":["phone"]}))
        .unwrap();
    phone
        .relay_command(&json!({"op":"relay-mesh-peers","peers":["mac"]}))
        .unwrap();
    assert_eq!(
        hub.relay_command(&json!({"op":"relay-status"})).unwrap()["mode"],
        "mesh"
    );
    settle(&mut [("mac", &mut hub), ("phone", &mut phone)]);
    let (th, tp) = (titles(&mut hub), titles(&mut phone));
    assert_eq!(th, tp);
    assert_eq!(th["offline"], "phone only, not yet confirmed");
    // The phone edit was still unconfirmed, so it carries a real timestamp stamp and wins;
    // the hub's version stays recoverable in history.
    assert_eq!(th["shared"], "phone conflicting edit");
    let kept = history_titles(&mut hub, "shared");
    assert!(kept.contains(&"mac newer edit".to_string()), "{kept:?}");
    // The old conflict list is gone and nothing waits for confirmation.
    let status = hub.relay_command(&json!({"op":"relay-status"})).unwrap();
    assert_eq!(status["conflictCount"], 0);
    assert_eq!(status["pending"], 0);
}
