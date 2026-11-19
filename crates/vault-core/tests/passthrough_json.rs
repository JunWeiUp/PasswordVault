use serde_json::{json, Value};
use tempfile::tempdir;
use vault_core::VaultSession;

fn run(s: &VaultSession, req: Value) -> Value {
    serde_json::from_str(&s.command(req.to_string()).unwrap()).unwrap()
}

#[test]
fn generic_passthrough_ui_meta_and_ui_prefs_round_trip_and_enforce_bounds() {
    let dir = tempdir().unwrap();
    let root = dir.path().to_string_lossy().into_owned();
    let s = VaultSession::new(root.clone()).unwrap();
    run(
        &s,
        json!({"op": "create", "password": "test-pass-passthrough"}),
    );

    // Arbitrary nested UI metadata on notes and accounts without any Rust whitelist changes.
    let note_meta = json!({
        "notes": { "defaultView": "preview", "collapsedProps": true, "accent": "blue" },
        "customFlags": ["pinned-outline", "compact"]
    });
    run(
        &s,
        json!({
            "op": "save",
            "richNotes": true,
            "item": {
                "id": "note-meta-1",
                "type": "secureNote",
                "title": "架构笔记",
                "note": "# 标题\n正文内容",
                "uiMeta": note_meta,
                "updatedAt": "2026-11-19T10:00:00Z"
            }
        }),
    );

    let account_meta = json!({"accounts": {"badgeColor": "#3265db", "lastQuickCopy": 1732000000}});
    run(
        &s,
        json!({
            "op": "save",
            "item": {
                "id": "acc-meta-1",
                "type": "password",
                "title": "GitHub",
                "username": "dev",
                "password": "secret-value",
                "uiMeta": account_meta,
                "updatedAt": "2026-11-19T10:00:00Z"
            }
        }),
    );

    // Arbitrary UI preferences in settings.uiPrefs + protection of core-owned keys.
    let ui_prefs = json!({
        "noteDefaultMode": "preview",
        "sidebarSections": {"folders": true, "tools": false}
    });
    run(
        &s,
        json!({
            "op": "settings",
            "settings": {
                "uiPrefs": ui_prefs,
                "devicesEnabled": true,
                "sharingIdentity": {"publicKey": "spoofed"}
            }
        }),
    );

    // Reopen vault from disk to verify persistence through SQLCipher + note_bodies split/hydrate.
    drop(s);
    let s2 = VaultSession::new(root).unwrap();
    run(
        &s2,
        json!({"op": "unlock", "password": "test-pass-passthrough"}),
    );
    let listed = run(&s2, json!({"op": "list"}));
    let items = listed["items"].as_array().unwrap();
    let note = items.iter().find(|i| i["id"] == "note-meta-1").unwrap();
    assert_eq!(note["uiMeta"], note_meta);
    let acc = items.iter().find(|i| i["id"] == "acc-meta-1").unwrap();
    assert_eq!(acc["uiMeta"], account_meta);
    assert_eq!(listed["settings"]["uiPrefs"], ui_prefs);
    // Protected core keys were NOT overwritten by UI settings patch.
    assert!(listed["settings"].get("sharingIdentity").is_none());
    assert!(listed["settings"].get("devicesEnabled").is_none());

    // Malformed / oversized / overly deep uiMeta & uiPrefs are rejected cleanly.
    assert!(s2
        .command(
            json!({
                "op": "save",
                "item": {
                    "id": "bad-meta-type",
                    "type": "password",
                    "title": "Bad",
                    "uiMeta": "not-an-object",
                    "updatedAt": "2026-11-19T10:01:00Z"
                }
            })
            .to_string()
        )
        .is_err());

    let big = "x".repeat(17 * 1024);
    assert!(s2
        .command(
            json!({
                "op": "save",
                "item": {
                    "id": "bad-meta-size",
                    "type": "password",
                    "title": "Huge",
                    "uiMeta": {"blob": big},
                    "updatedAt": "2026-11-19T10:01:00Z"
                }
            })
            .to_string()
        )
        .is_err());

    let deep = json!({"a":{"b":{"c":{"d":{"e":{"f":{"g":1}}}}}}});
    assert!(s2
        .command(
            json!({
                "op": "save",
                "item": {
                    "id": "bad-meta-depth",
                    "type": "password",
                    "title": "Deep",
                    "uiMeta": deep,
                    "updatedAt": "2026-11-19T10:01:00Z"
                }
            })
            .to_string()
        )
        .is_err());

    assert!(s2
        .command(
            json!({
                "op": "settings",
                "settings": {"uiPrefs": [1, 2, 3]}
            })
            .to_string()
        )
        .is_err());
}
