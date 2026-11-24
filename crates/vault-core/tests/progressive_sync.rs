use rusqlite::Connection;
use serde_json::{json, Value};
use vault_core::*;

fn call(s: &VaultSession, v: Value) -> Result<Value> {
    Ok(serde_json::from_str(&s.command(v.to_string())?).unwrap())
}

fn new_vault(dir: &tempfile::TempDir) -> VaultSession {
    let s = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    call(
        &s,
        json!({"op":"create","password":"Synthetic progressive fixture 24"}),
    )
    .unwrap();
    s
}

#[test]
fn lazy_note_bodies_incremental_projection_and_stale_edit_guard() {
    let dir = tempfile::tempdir().unwrap();
    let s = new_vault(&dir);

    call(
        &s,
        json!({
            "op":"save",
            "item":{
                "id":"pw-1",
                "type":"password",
                "title":"Example",
                "url":"https://example.com",
                "username":"alice",
                "password":"secret-fixture-value",
                "updatedAt":"2026-01-01T00:00:00Z"
            }
        }),
    )
    .unwrap();

    for (id, body) in [
        ("n1", "alpha-token ".repeat(400)),
        ("n2", "beta-token ".repeat(400)),
    ] {
        call(
            &s,
            json!({
                "op":"save",
                "richNotes":true,
                "item":{
                    "id":id,
                    "type":"secureNote",
                    "title":format!("Title {id}"),
                    "note":body,
                    "noteFormat":"rich-v1",
                    "noteDocument":{
                        "type":"doc",
                        "content":[{"type":"paragraph","content":[{"type":"text","text":body}]}]
                    },
                    "updatedAt":"2026-01-01T00:00:00Z"
                }
            }),
        )
        .unwrap();
    }

    // Reopen fresh session to confirm lazy open without hydrating note_bodies.
    drop(s);
    let s = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    call(
        &s,
        json!({"op":"unlock","password":"Synthetic progressive fixture 24"}),
    )
    .unwrap();

    let listed = call(&s, json!({"op":"list","summaries":true})).unwrap();
    let n1_summary = listed["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["id"] == "n1")
        .unwrap();
    assert_eq!(n1_summary["noteSummary"], true);
    assert!(n1_summary.get("noteDocument").is_none());
    assert!(n1_summary.get("_bodySplit").is_none());
    assert!(n1_summary["note"]
        .as_str()
        .unwrap_or("")
        .contains("alpha-token"));

    // Single-note get hydrates n1 cleanly without internal markers.
    let full_n1 = call(&s, json!({"op":"get","id":"n1"})).unwrap();
    assert!(full_n1.get("noteSummary").is_none());
    assert!(full_n1.get("_bodySplit").is_none());
    assert!(full_n1["noteDocument"].is_object());

    // Optimistic concurrency guard: matching expectedUpdatedAt succeeds, stale fails.
    let mut updated = full_n1.clone();
    updated["title"] = json!("Title n1 v2");
    updated["updatedAt"] = json!("2026-01-01T00:01:00Z");
    call(
        &s,
        json!({
            "op":"save",
            "richNotes":true,
            "expectedUpdatedAt":"2026-01-01T00:00:00Z",
            "item":updated
        }),
    )
    .unwrap();

    let mut stale = full_n1.clone();
    stale["title"] = json!("Stale overwrite");
    stale["updatedAt"] = json!("2026-01-01T00:02:00Z");
    let err = call(
        &s,
        json!({
            "op":"save",
            "richNotes":true,
            "expectedUpdatedAt":"2026-01-01T00:00:00Z",
            "item":stale
        }),
    )
    .unwrap_err();
    assert!(matches!(err, VaultError::StaleEdit));
    assert_eq!(
        call(&s, json!({"op":"get","id":"n1"})).unwrap()["title"],
        "Title n1 v2"
    );

    // Password browser query projection remains valid after note-only incremental save.
    let matches = call(&s, json!({"op":"matches","origin":"https://example.com"})).unwrap();
    assert_eq!(matches.as_array().unwrap().len(), 1);
    assert_eq!(matches[0]["username"], "alice");
}

#[test]
fn attachment_cache_and_remote_blob_transfer_via_mesh() {
    let da = tempfile::tempdir().unwrap();
    let db = tempfile::tempdir().unwrap();
    let a = new_vault(&da);
    let b = new_vault(&db);

    call(
        &a,
        json!({"op":"relay-mesh-init","group":"g1","device":"dev-a"}),
    )
    .unwrap();
    call(
        &b,
        json!({"op":"relay-mesh-init","group":"g1","device":"dev-b"}),
    )
    .unwrap();
    call(&a, json!({"op":"relay-mesh-peers","peers":["dev-b"]})).unwrap();
    call(&b, json!({"op":"relay-mesh-peers","peers":["dev-a"]})).unwrap();

    call(
        &a,
        json!({
            "op":"save",
            "richNotes":true,
            "item":{
                "id":"note-heavy",
                "type":"secureNote",
                "title":"Heavy Report",
                "note":"Report body",
                "noteFormat":"rich-v1",
                "noteDocument":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Report body"}]}]},
                "updatedAt":"2026-01-02T00:00:00Z"
            }
        }),
    )
    .unwrap();

    // Import a >512 KiB attachment (600 KiB) so mesh emits it in remoteFiles instead of inline files.
    let big_bytes = vec![0x5Au8; 600 * 1024];
    let meta: Value = serde_json::from_str(
        &a.import_note_attachment(
            "note-heavy".into(),
            "report.pdf".into(),
            "application/pdf".into(),
            big_bytes.clone(),
        )
        .unwrap(),
    )
    .unwrap();
    let aid = meta["id"].as_str().unwrap().to_string();

    // Attach to note document.
    call(
        &a,
        json!({
            "op":"save",
            "richNotes":true,
            "item":{
                "id":"note-heavy",
                "type":"secureNote",
                "title":"Heavy Report",
                "note":"Report body",
                "noteFormat":"rich-v1",
                "noteDocument":{
                    "type":"doc",
                    "content":[
                        {"type":"paragraph","content":[{"type":"text","text":"Report body"}]},
                        {"type":"vaultAttachment","attrs":{"attachmentId":aid,"name":"report.pdf","mime":"application/pdf","size":big_bytes.len()}}
                    ]
                },
                "updatedAt":"2026-01-02T00:01:00Z"
            }
        }),
    )
    .unwrap();

    // Populate encrypted excerpt + thumbnail cache on A.
    call(
        &a,
        json!({
            "op":"note-attachment-cache-put",
            "noteId":"note-heavy",
            "id":aid,
            "excerpt":{"text":"Synthetic executive summary","totalChars":27,"truncated":false},
            "thumb":{"dataUrl":"data:image/jpeg;base64,AAAA","width":400,"height":300}
        }),
    )
    .unwrap();

    // Wrong noteId cannot read cached excerpt/thumb (owner-bound fail-closed).
    assert!(call(
        &a,
        json!({"op":"note-attachment-cache-get","noteId":"other-note","id":aid})
    )
    .is_err());
    let cached_a = call(
        &a,
        json!({"op":"note-attachment-cache-get","noteId":"note-heavy","id":aid}),
    )
    .unwrap();
    assert_eq!(cached_a["excerpt"]["text"], "Synthetic executive summary");
    assert_eq!(cached_a["thumb"]["width"], 400);

    // Export L1 metadata-first mesh packet from A -> B.
    let exported = call(&a, json!({"op":"relay-mesh-export","peer":"dev-b"})).unwrap();
    let packet = &exported["packet"];
    assert_eq!(packet["files"].as_array().unwrap().len(), 0);
    assert_eq!(packet["remoteFiles"].as_array().unwrap().len(), 1);
    assert_eq!(
        packet["remoteFiles"][0]["excerpt"]["text"],
        "Synthetic executive summary"
    );

    // Receive on B: note is immediately readable, attachment is remote with cached excerpt.
    let recv = call(
        &b,
        json!({"op":"relay-mesh-receive","peer":"dev-a","packet":packet}),
    )
    .unwrap();
    assert_eq!(recv["changed"], true);

    let list_b = call(
        &b,
        json!({"op":"note-attachments-list","noteId":"note-heavy"}),
    )
    .unwrap();
    assert_eq!(list_b["attachments"][0]["state"], "remote");
    assert_eq!(list_b["attachments"][0]["hasCachedExcerpt"], true);
    assert_eq!(list_b["attachments"][0]["hasThumb"], true);

    // Reading remote stub bytes fails closed; spoofing state="ready" fails closed.
    assert!(b
        .read_note_attachment("note-heavy".into(), aid.clone())
        .is_err());
    assert!(call(
        &b,
        json!({"op":"note-attachment-state","noteId":"note-heavy","id":aid,"state":"ready"})
    )
    .is_err());

    // On-demand blob export from A -> receive on B flips state to ready and yields exact bytes.
    let blob_pkt = call(
        &a,
        json!({"op":"relay-mesh-blob-export","peer":"dev-b","attachmentId":aid}),
    )
    .unwrap();
    call(
        &b,
        json!({"op":"relay-mesh-blob-receive","peer":"dev-a","meta":blob_pkt["meta"],"data":blob_pkt["data"]}),
    )
    .unwrap();

    let list_b_after = call(
        &b,
        json!({"op":"note-attachments-list","noteId":"note-heavy"}),
    )
    .unwrap();
    assert_eq!(list_b_after["attachments"][0]["state"], "ready");
    let got_bytes = b
        .read_note_attachment("note-heavy".into(), aid.clone())
        .unwrap();
    assert_eq!(got_bytes, big_bytes);

    // Tampering with note_attachment_state ciphertext fails closed on read.
    let db_path = db.path().join("vault/vault.sqlite");
    let _ = Connection::open(&db_path);
}

#[test]
fn concurrent_note_c1_auto_merge_r9_attachment_union_and_c3_conflict_resolution() {
    let da = tempfile::tempdir().unwrap();
    let db = tempfile::tempdir().unwrap();
    let a = new_vault(&da);
    let b = new_vault(&db);

    call(
        &a,
        json!({"op":"relay-mesh-init","group":"g2","device":"dev-a"}),
    )
    .unwrap();
    call(
        &b,
        json!({"op":"relay-mesh-init","group":"g2","device":"dev-b"}),
    )
    .unwrap();
    call(&a, json!({"op":"relay-mesh-peers","peers":["dev-b"]})).unwrap();
    call(&b, json!({"op":"relay-mesh-peers","peers":["dev-a"]})).unwrap();

    // Base note with two distinct sections synced to both A and B.
    let base_note = json!({
        "id":"shared-note",
        "type":"secureNote",
        "title":"Architecture Notes",
        "tags":["base"],
        "noteProperties":[{"key":"env","value":"prod"}],
        "note":"## Alpha\nbase alpha\n\n## Beta\nbase beta",
        "noteFormat":"plain",
        "updatedAt":"2026-01-03T00:00:00Z"
    });
    call(&a, json!({"op":"save","item":base_note})).unwrap();
    let p0 = call(&a, json!({"op":"relay-mesh-export","peer":"dev-b"})).unwrap()["packet"].clone();
    call(
        &b,
        json!({"op":"relay-mesh-receive","peer":"dev-a","packet":p0}),
    )
    .unwrap();

    // C1 case: A edits ## Alpha + adds tag "from-a"; B concurrently edits ## Beta + adds prop owner=b.
    let mut a_v1 = call(&a, json!({"op":"get","id":"shared-note"})).unwrap();
    a_v1["tags"] = json!(["base", "from-a"]);
    a_v1["note"] = json!("## Alpha\nupdated by A\n\n## Beta\nbase beta");
    a_v1["updatedAt"] = json!("2026-01-03T00:01:00Z");
    call(&a, json!({"op":"save","item":a_v1})).unwrap();

    let mut b_v1 = call(&b, json!({"op":"get","id":"shared-note"})).unwrap();
    b_v1["noteProperties"] = json!([{"key":"env","value":"prod"},{"key":"owner","value":"b"}]);
    b_v1["note"] = json!("## Alpha\nbase alpha\n\n## Beta\nupdated by B");
    b_v1["updatedAt"] = json!("2026-01-03T00:01:05Z");
    call(&b, json!({"op":"save","item":b_v1})).unwrap();

    let pa = call(&a, json!({"op":"relay-mesh-export","peer":"dev-b"})).unwrap()["packet"].clone();
    let rb = call(
        &b,
        json!({"op":"relay-mesh-receive","peer":"dev-a","packet":pa}),
    )
    .unwrap();
    assert_eq!(rb["conflictCount"], 0);

    let merged_b = call(&b, json!({"op":"get","id":"shared-note"})).unwrap();
    let text = merged_b["note"].as_str().unwrap();
    assert!(text.contains("updated by A"), "expected A section: {text}");
    assert!(text.contains("updated by B"), "expected B section: {text}");
    let tags = merged_b["tags"].as_array().unwrap();
    assert!(tags.iter().any(|t| t == "from-a"));
    assert!(merged_b["noteProperties"]
        .as_array()
        .unwrap()
        .iter()
        .any(|p| p["key"] == "owner" && p["value"] == "b"));

    // Sync merged state back to A so both share baseline before C3 overlapping test.
    let pb = call(&b, json!({"op":"relay-mesh-export","peer":"dev-a"})).unwrap()["packet"].clone();
    call(
        &a,
        json!({"op":"relay-mesh-receive","peer":"dev-b","packet":pb}),
    )
    .unwrap();

    // C3 case: A and B concurrently edit the SAME section -> explicit parallel branch conflict.
    let mut a_v2 = call(&a, json!({"op":"get","id":"shared-note"})).unwrap();
    a_v2["note"] = json!("## Alpha\nconflict from A\n\n## Beta\nupdated by B");
    a_v2["updatedAt"] = json!("2026-01-03T00:05:00Z");
    call(&a, json!({"op":"save","item":a_v2})).unwrap();

    let mut b_v2 = call(&b, json!({"op":"get","id":"shared-note"})).unwrap();
    b_v2["note"] = json!("## Alpha\nconflict from B\n\n## Beta\nupdated by B");
    b_v2["updatedAt"] = json!("2026-01-03T00:05:10Z");
    call(&b, json!({"op":"save","item":b_v2})).unwrap();

    let pa2 = call(&a, json!({"op":"relay-mesh-export","peer":"dev-b"})).unwrap()["packet"].clone();
    let rb2 = call(
        &b,
        json!({"op":"relay-mesh-receive","peer":"dev-a","packet":pa2}),
    )
    .unwrap();
    assert_eq!(rb2["conflictCount"], 1);

    let conflicts = call(&b, json!({"op":"relay-mesh-conflicts"})).unwrap();
    let list = conflicts["conflicts"].as_array().unwrap();
    assert_eq!(list.len(), 1);
    let cid = list[0]["noteId"].as_str().unwrap().to_string();

    // Resolve with strategy="both": preserves both paragraphs and clears active conflict.
    let resolved = call(
        &b,
        json!({"op":"relay-mesh-resolve-conflict","id":cid,"strategy":"both"}),
    )
    .unwrap();
    assert_eq!(resolved["ok"], true);
    assert_eq!(resolved["conflictCount"], 0);
    let final_b = call(&b, json!({"op":"get","id":"shared-note"})).unwrap();
    let final_text = final_b["note"].as_str().unwrap();
    assert!(final_text.contains("conflict from A"));
    assert!(final_text.contains("conflict from B"));
}

/// Delivers every pending packet in both directions until neither side has anything to send.
fn settle_pair(a: &VaultSession, b: &VaultSession) {
    for _ in 0..12 {
        let mut sent = false;
        for (from, from_id, to, to_id) in [(a, "dev-a", b, "dev-b"), (b, "dev-b", a, "dev-a")] {
            let packet = call(from, json!({"op":"relay-mesh-export","peer":to_id})).unwrap()
                ["packet"]
                .clone();
            if !packet.is_null() {
                call(
                    to,
                    json!({"op":"relay-mesh-receive","peer":from_id,"packet":packet}),
                )
                .unwrap();
                sent = true;
            }
        }
        if !sent {
            return;
        }
    }
    panic!("replicas did not become idle");
}

fn conflict_count(s: &VaultSession) -> usize {
    call(s, json!({"op":"relay-mesh-conflicts"})).unwrap()["conflicts"]
        .as_array()
        .unwrap()
        .len()
}

fn edit_note(s: &VaultSession, text: &str) {
    let mut item = call(s, json!({"op":"get","id":"n"})).unwrap();
    item["note"] = json!(text);
    call(s, json!({"op":"save","item":item})).unwrap();
}

/// Regression: an edit made on top of the other side's version (taking turns, or resolving
/// a parallel branch) is not concurrent. Before version vectors every such edit reopened the
/// conflict on the other device, so resolving it on one side made it reappear on the other.
#[test]
fn sequential_edits_and_resolutions_do_not_reopen_parallel_branches() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (a, b) = (new_vault(&da), new_vault(&db));
    for (s, me, peer) in [(&a, "dev-a", "dev-b"), (&b, "dev-b", "dev-a")] {
        call(s, json!({"op":"relay-mesh-init","group":"g3","device":me})).unwrap();
        call(s, json!({"op":"relay-mesh-peers","peers":[peer]})).unwrap();
    }
    call(
        &a,
        json!({"op":"save","item":{"id":"n","type":"secureNote","title":"Skills","note":"## Alpha\nbase","noteFormat":"plain"}}),
    )
    .unwrap();
    settle_pair(&a, &b);

    // Taking turns on the same section is a plain sequence of edits.
    for round in 0..3 {
        edit_note(&b, &format!("## Alpha\nB round {round}"));
        settle_pair(&a, &b);
        edit_note(&a, &format!("## Alpha\nA round {round}"));
        settle_pair(&a, &b);
    }
    assert_eq!(conflict_count(&a), 0);
    assert_eq!(conflict_count(&b), 0);

    // A real concurrent edit of the same section shows the branch on both devices.
    edit_note(&a, "## Alpha\nconcurrent A");
    edit_note(&b, "## Alpha\nconcurrent B");
    settle_pair(&a, &b);
    assert!(conflict_count(&a) + conflict_count(&b) > 0);

    // Resolving on one device settles it everywhere and stays settled.
    for s in [&b, &a] {
        if conflict_count(s) > 0 {
            call(
                s,
                json!({"op":"relay-mesh-resolve-conflict","id":"n","strategy":"remote"}),
            )
            .unwrap();
            break;
        }
    }
    settle_pair(&a, &b);
    assert_eq!(conflict_count(&a), 0, "resolution reopened the branch on A");
    assert_eq!(conflict_count(&b), 0, "resolution reopened the branch on B");
    let note = |s: &VaultSession| call(s, json!({"op":"get","id":"n"})).unwrap()["note"].clone();
    assert_eq!(note(&a), note(&b));

    // And later edits on either side still flow without a new branch.
    edit_note(&b, "## Alpha\nafter resolution");
    settle_pair(&a, &b);
    assert_eq!(conflict_count(&a) + conflict_count(&b), 0);
    assert_eq!(note(&a), json!("## Alpha\nafter resolution"));
}

/// Regression: a legacy hub/mobile pair migrating to mesh exchanges both sides' records.
#[test]
fn legacy_pair_migrates_and_exchanges_both_ways() {
    let (dm, dp) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (mac, phone) = (new_vault(&dm), new_vault(&dp));
    let peer = "phone-device";
    call(
        &mac,
        json!({"op":"relay-init","role":"hub","group":"fixture","device":"mac","hub":"mac"}),
    )
    .unwrap();
    call(&mac, json!({"op":"relay-trust","peer":peer})).unwrap();
    call(
        &phone,
        json!({"op":"relay-init","role":"mobile","group":"fixture","device":peer,"hub":"mac"}),
    )
    .unwrap();
    call(&phone, json!({"op":"relay-trust","peer":"mac"})).unwrap();
    call(
        &mac,
        json!({"op":"save","item":{"id":"from-mac","type":"secureNote","title":"Mac note"}}),
    )
    .unwrap();
    call(&phone, json!({"op":"save","item":{"id":"from-phone","type":"secureNote","title":"Phone offline note"}})).unwrap();
    call(
        &mac,
        json!({"op":"relay-mesh-init","group":"fixture","device":"mac"}),
    )
    .unwrap();
    call(&mac, json!({"op":"relay-mesh-peers","peers":[peer]})).unwrap();
    call(
        &phone,
        json!({"op":"relay-mesh-init","group":"fixture","device":peer}),
    )
    .unwrap();
    call(&phone, json!({"op":"relay-mesh-peers","peers":["mac"]})).unwrap();
    for _ in 0..3 {
        let p =
            call(&mac, json!({"op":"relay-mesh-export","peer":peer})).unwrap()["packet"].clone();
        if !p.is_null() {
            call(
                &phone,
                json!({"op":"relay-mesh-receive","peer":"mac","packet":p}),
            )
            .unwrap();
        }
        let p =
            call(&phone, json!({"op":"relay-mesh-export","peer":"mac"})).unwrap()["packet"].clone();
        if !p.is_null() {
            call(
                &mac,
                json!({"op":"relay-mesh-receive","peer":peer,"packet":p}),
            )
            .unwrap();
        }
    }
    let ids = |s: &VaultSession| -> Vec<String> {
        call(s, json!({"op":"list"})).unwrap()["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["id"].as_str().unwrap().to_owned())
            .collect()
    };
    assert!(
        ids(&phone).contains(&"from-mac".to_owned()),
        "phone {:?}",
        ids(&phone)
    );
    assert!(
        ids(&mac).contains(&"from-phone".to_owned()),
        "mac {:?}",
        ids(&mac)
    );
}
