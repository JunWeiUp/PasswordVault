use super::*;
#[test]
fn native_peer_capture_conflict_and_restart() {
    let da = tempfile::tempdir().unwrap();
    let db = tempfile::tempdir().unwrap();
    let mut a = DiskVault::new(da.path()).unwrap();
    let mut b = DiskVault::new(db.path()).unwrap();
    a.create("a-fixture").unwrap();
    b.create("b-fixture").unwrap();
    let ai = command(
        &mut a,
        &json!({"op":"relay-peer-create","device":"phone-a","personal":true}),
    )
    .unwrap();
    let bi = command(
        &mut b,
        &json!({"op":"relay-peer-identity","device":"phone-b","personal":true,"confirmPersonalSync":true}),
    )
    .unwrap();
    let lib = ai["library"].as_str().unwrap();
    command(&mut a,&json!({"op":"relay-peer-authorize","library":lib,"peer":"phone-b","member":{"publicKey":bi["publicKey"],"role":"editor"}})).unwrap();
    let envelope = command(
        &mut a,
        &json!({"op":"relay-peer-export","library":lib,"peer":"phone-b"}),
    )
    .unwrap();
    command(&mut b,&json!({"op":"relay-peer-join","library":bi["library"],"expectedLibrary":lib,"founderKey":ai["publicKey"],"envelope":envelope})).unwrap();
    a.command(&json!({"op":"save","item":{"id":"example","type":"password","title":"A"}}))
        .unwrap();
    let old_draft = a.command(&json!({"op":"list"})).unwrap()["items"][0].clone();
    let sealed_draft = a
        .command(&json!({"op":"seal-drafts","items":[old_draft]}))
        .unwrap();
    b.command(&json!({"op":"save","item":{"id":"example","type":"password","title":"B"}}))
        .unwrap();
    let envelope = command(
        &mut a,
        &json!({"op":"relay-peer-export","library":lib,"peer":"phone-b"}),
    )
    .unwrap();
    command(
        &mut b,
        &json!({"op":"relay-peer-receive","library":lib,"envelope":envelope}),
    )
    .unwrap();
    let status = command(&mut b, &json!({"op":"relay-peer-status","library":lib})).unwrap();
    assert_eq!(
        status["conflicts"]["item:example"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    command(&mut b,&json!({"op":"relay-peer-resolve","library":lib,"key":"item:example","value":{"id":"example","type":"password","title":"chosen"}})).unwrap();
    let envelope = command(
        &mut b,
        &json!({"op":"relay-peer-export","library":lib,"peer":"phone-a"}),
    )
    .unwrap();
    command(
        &mut a,
        &json!({"op":"relay-peer-receive","library":lib,"envelope":envelope}),
    )
    .unwrap();
    a.lock();
    a.unlock("a-fixture").unwrap();
    assert_eq!(a.open().unwrap().document.items[0]["title"], "chosen");
    let restoration = a.command(
        &json!({"op":"restore-drafts","payload":sealed_draft["payload"],"richNotes":true}),
    );
    assert!(
        matches!(restoration, Err(VaultError::StaleEdit)),
        "{restoration:?}"
    );
    assert_eq!(a.open().unwrap().document.items[0]["title"], "chosen");
    assert!(a.open().unwrap().document.items[0]
        .get("_peerBaseHeads")
        .is_none());
}
#[test]
fn personal_mutation_failure_preserves_family_and_disk() {
    let d = tempfile::tempdir().unwrap();
    let mut vault = DiskVault::new(d.path()).unwrap();
    vault.create("synthetic-local-test").unwrap();
    let family = command(
        &mut vault,
        &json!({"op":"relay-peer-create","device":"phone","personal":false,"name":"Family"}),
    )
    .unwrap()["library"]
        .clone();
    command(
        &mut vault,
        &json!({"op":"relay-peer-switch","library":family}),
    )
    .unwrap();
    let before = serde_json::to_value(&vault.open().unwrap().document).unwrap();
    let failure = vault.mutate_personal_passkey(|doc| {
        doc.items.push(json!({"id":"must-not-persist"}));
        Err(VaultError::Authentication)
    });
    assert!(matches!(failure, Err(VaultError::Authentication)));
    assert_eq!(
        serde_json::to_value(&vault.open().unwrap().document).unwrap(),
        before
    );
    vault.lock();
    vault.unlock("synthetic-local-test").unwrap();
    assert_eq!(
        serde_json::to_value(&vault.open().unwrap().document).unwrap(),
        before
    );
    command(&mut vault, &json!({"op":"relay-peer-switch","library":""})).unwrap();
    assert!(vault.open().unwrap().document.items.is_empty());
}
#[test]
fn migration_requires_explicit_consent_and_archives_legacy() {
    let d = tempfile::tempdir().unwrap();
    let mut a = DiskVault::new(d.path()).unwrap();
    a.create("fixture").unwrap();
    a.relay_command(
        &json!({"op":"relay-init","role":"mobile","group":"g","device":"phone","hub":"mac"}),
    )
    .unwrap();
    assert!(command(
        &mut a,
        &json!({"op":"relay-peer-create","device":"phone","personal":true})
    )
    .is_err());
    assert!(enabled(&a.open().unwrap().connection).unwrap());
    command(
        &mut a,
        &json!({"op":"relay-peer-create","device":"phone","personal":true,"migrateLegacy":true}),
    )
    .unwrap();
    assert!(!enabled(&a.open().unwrap().connection).unwrap());
    let count: i64 = a
        .open()
        .unwrap()
        .connection
        .query_row("SELECT count(*) FROM personal_relay_archive", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(count, 1);
}
#[test]
fn family_switch_keeps_personal_data_history_and_backup_separate() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = DiskVault::new(dir.path()).unwrap();
    vault.create("fixture-password").unwrap();
    vault
        .command(&json!({"op":"save","item":{"id":"same","type":"password","title":"Private"}}))
        .unwrap();
    vault
        .history_command(&json!({"op":"history-enable"}))
        .unwrap();
    let family = command(
        &mut vault,
        &json!({"op":"relay-peer-create","device":"phone","personal":false,"name":"Family"}),
    )
    .unwrap()["library"]
        .as_str()
        .unwrap()
        .to_owned();
    command(
        &mut vault,
        &json!({"op":"relay-peer-switch","library":family}),
    )
    .unwrap();
    assert!(vault.open().unwrap().document.items.is_empty());
    vault
        .command(&json!({"op":"save","item":{"id":"same","type":"password","title":"Shared"}}))
        .unwrap();
    let history = vault
        .history_command(&json!({"op":"history-list","id":"same"}))
        .unwrap();
    assert_eq!(history["revisions"][0]["item"]["title"], "Shared");
    assert_eq!(history["total"], 1);
    {
        let open = vault.open().unwrap();
        let documents = readable_documents(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            &open.document,
        )
        .unwrap();
        assert_eq!(documents.len(), 2);
        assert_eq!(documents[0].0, "");
        assert_eq!(documents[0].1.items[0]["title"], "Private");
        assert_eq!(documents[1].1.items[0]["title"], "Shared");
        let library =
            load_library(&open.connection, &open.root, &open.header.vault_id, &family).unwrap();
        let mut frozen = library.clone();
        frozen.replica.frozen = true;
        save(&open.connection, &open.root, &open.header.vault_id, &frozen).unwrap();
        assert_eq!(
            readable_documents(
                &open.connection,
                &open.root,
                &open.header.vault_id,
                &open.document
            )
            .unwrap()
            .len(),
            1
        );
        let mut removed = library.clone();
        removed
            .replica
            .authorize(
                "other-admin".into(),
                Some(Member {
                    public_key: hex::encode([7; 32]),
                    transport_key: String::new(),
                    role: crate::peer_sync::LibraryRole::Admin,
                }),
            )
            .unwrap();
        removed.replica.authorize("phone".into(), None).unwrap();
        save(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            &removed,
        )
        .unwrap();
        assert_eq!(
            readable_documents(
                &open.connection,
                &open.root,
                &open.header.vault_id,
                &open.document
            )
            .unwrap()
            .len(),
            1
        );
        save(
            &open.connection,
            &open.root,
            &open.header.vault_id,
            &library,
        )
        .unwrap();
    }
    let archive = vault.archive("fixture-backup-password").unwrap();
    command(&mut vault, &json!({"op":"relay-peer-switch","library":""})).unwrap();
    assert_eq!(vault.open().unwrap().document.items[0]["title"], "Private");
    let history = vault
        .history_command(&json!({"op":"history-list","id":"same"}))
        .unwrap();
    assert_eq!(history["revisions"][0]["item"]["title"], "Private");
    let restored_dir = tempfile::tempdir().unwrap();
    let mut restored = DiskVault::new(restored_dir.path()).unwrap();
    restored
        .import_archive(&archive, "fixture-backup-password", Some("new-password"))
        .unwrap();
    assert_eq!(
        restored.open().unwrap().document.items[0]["title"],
        "Private"
    );
    let libraries = command(&mut restored, &json!({"op":"relay-peer-list"})).unwrap();
    let recovered = libraries["libraries"][0]["id"].as_str().unwrap();
    assert_ne!(recovered, family);
    command(
        &mut restored,
        &json!({"op":"relay-peer-switch","library":recovered}),
    )
    .unwrap();
    assert_eq!(
        restored.open().unwrap().document.items[0]["title"],
        "Shared"
    );
    let renewed=command(&mut restored,&json!({"op":"relay-peer-rekey","library":recovered,"device":"replacement-phone","transportKey":"a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209"})).unwrap(); // gitleaks:allow -- synthetic fixture or non-secret expression
    assert_ne!(renewed["library"], recovered);
    assert_eq!(renewed["device"], "replacement-phone");
    assert_eq!(
        restored.open().unwrap().document.items[0]["title"],
        "Shared"
    );
    let status = command(
        &mut restored,
        &json!({"op":"relay-peer-status","library":renewed["library"]}),
    )
    .unwrap();
    assert_eq!(status["members"].as_object().unwrap().len(), 1);
}
#[test]
fn reader_backup_receipt_cannot_confirm_after_library_freezes_or_revokes_access() {
    let a_dir = tempfile::tempdir().unwrap();
    let b_dir = tempfile::tempdir().unwrap();
    let mut a = DiskVault::new(a_dir.path()).unwrap();
    let mut b = DiskVault::new(b_dir.path()).unwrap();
    a.create("owner fixture passphrase").unwrap();
    b.create("reader fixture passphrase").unwrap();
    let owner = command(
        &mut a,
        &json!({"op":"relay-peer-create","device":"owner","personal":false,"name":"Family"}),
    )
    .unwrap();
    let library = owner["library"].as_str().unwrap();
    command(&mut a, &json!({"op":"relay-peer-switch","library":library})).unwrap();
    // Seed an existing shared credential explicitly. Public registration always
    // targets the personal vault, irrespective of the selected family view.
    let (record, response) =
        crate::passkey_create_system("example.com", b"reader-fixture", "Reader fixture", &[1; 32])
            .unwrap();
    let created = serde_json::to_value(response).unwrap();
    a.mutate(|doc| {
        doc.upsert(json!({"id":"shared-passkey-fixture","type":concat!("pass", "word"),"title":"Shared fixture","passkeys":[serde_json::to_value(&record).unwrap()]}))?;
        Ok(json!({}))
    }).unwrap();
    let identity = command(
        &mut b,
        &json!({"op":"relay-peer-identity","device":"reader","personal":false}),
    )
    .unwrap();
    command(&mut a,&json!({"op":"relay-peer-authorize","library":library,"peer":"reader","member":{"publicKey":identity["publicKey"],"role":"reader"}})).unwrap();
    let envelope = command(
        &mut a,
        &json!({"op":"relay-peer-export","library":library,"peer":"reader"}),
    )
    .unwrap();
    command(&mut b,&json!({"op":"relay-peer-join","library":identity["library"],"expectedLibrary":library,"founderKey":owner["publicKey"],"envelope":envelope})).unwrap();
    command(&mut b, &json!({"op":"relay-peer-switch","library":library})).unwrap();
    let index = b.passkey_command(&json!({"op":"passkey-index"})).unwrap();
    let item_id = index["passkeys"][0]["itemId"].as_str().unwrap();
    let exported=b.passkey_backup_command(&json!({"op":"passkey-backup-export","credentialId":created["id"],"itemId":item_id,"library":library,"currentPassword":"reader fixture passphrase","backupPassword":"separate backup fixture"})).unwrap();
    let archive = crate::archive::decode_archive(
        exported["content"].as_str().unwrap(),
        "separate backup fixture",
    )
    .unwrap();
    assert_eq!(archive.manifest.document.items.len(), 1);
    assert_eq!(
        archive.manifest.document.items[0]["passkeys"][0]["backupState"],
        true
    );
    assert_eq!(
        b.open().unwrap().document.items[0]["passkeys"][0]["backupState"],
        false
    );
    let confirm = json!({"op":"passkey-backup-confirm","credentialId":created["id"],"itemId":item_id,"library":library,"currentPassword":"reader fixture passphrase","receipt":exported["receipt"],"actualArchiveHash":hex::encode(Sha256::digest(exported["content"].as_str().unwrap().as_bytes()))});
    let open = b.open().unwrap();
    let original =
        load_library(&open.connection, &open.root, &open.header.vault_id, library).unwrap();
    let mut frozen = original.clone();
    frozen.replica.frozen = true;
    save(&open.connection, &open.root, &open.header.vault_id, &frozen).unwrap();
    assert!(matches!(
        b.passkey_backup_command(&confirm),
        Err(VaultError::Authentication)
    ));
    let open = b.open().unwrap();
    save(
        &open.connection,
        &open.root,
        &open.header.vault_id,
        &original,
    )
    .unwrap();
    command(
        &mut a,
        &json!({"op":"relay-peer-authorize","library":library,"peer":"reader","member":null}),
    )
    .unwrap();
    // Deliver the valid signed control update explicitly; the removed recipient is
    // intentionally no longer eligible for a normal data export.
    let notice = command(
        &mut a,
        &json!({"op":"relay-peer-export","library":library,"peer":"owner"}),
    )
    .unwrap();
    command(
        &mut b,
        &json!({"op":"relay-peer-receive","library":library,"envelope":notice}),
    )
    .unwrap();
    assert!(matches!(
        b.passkey_backup_command(&confirm),
        Err(VaultError::Authentication)
    ));
}
#[test]
fn family_enrollment_never_merges_personal_records_or_accepts_scope_override() {
    let a_dir = tempfile::tempdir().unwrap();
    let b_dir = tempfile::tempdir().unwrap();
    let mut a = DiskVault::new(a_dir.path()).unwrap();
    let mut b = DiskVault::new(b_dir.path()).unwrap();
    a.create("owner fixture").unwrap();
    b.create("reader fixture").unwrap();
    b.command(
        &json!({"op":"save","item":{"id":"private","type":"secureNote","title":"PRIVATE_CANARY"}}),
    )
    .unwrap();
    let owner = command(
        &mut a,
        &json!({"op":"relay-peer-create","device":"owner","personal":false}),
    )
    .unwrap();
    let library = owner["library"].as_str().unwrap();
    assert!(command(
        &mut b,
        &json!({"op":"relay-peer-identity","device":"reader","personal":true})
    )
    .is_err());
    let wrong=command(&mut b,&json!({"op":"relay-peer-identity","device":"reader","personal":true,"confirmPersonalSync":true})).unwrap();
    command(&mut a,&json!({"op":"relay-peer-authorize","library":library,"peer":"reader","member":{"publicKey":wrong["publicKey"],"role":"editor"}})).unwrap();
    let envelope = command(
        &mut a,
        &json!({"op":"relay-peer-export","library":library,"peer":"reader"}),
    )
    .unwrap();
    assert!(command(&mut b,&json!({"op":"relay-peer-join","library":wrong["library"],"expectedLibrary":library,"founderKey":owner["publicKey"],"envelope":envelope})).is_err());
    assert_eq!(
        b.open().unwrap().document.items[0]["title"],
        "PRIVATE_CANARY"
    );
    command(
        &mut b,
        &json!({"op":"relay-peer-cancel-join","library":wrong["library"]}),
    )
    .unwrap();
    let right = command(
        &mut b,
        &json!({"op":"relay-peer-identity","device":"reader","personal":false}),
    )
    .unwrap();
    command(&mut a,&json!({"op":"relay-peer-authorize","library":library,"peer":"reader","member":{"publicKey":right["publicKey"],"role":"reader"}})).unwrap();
    let envelope = command(
        &mut a,
        &json!({"op":"relay-peer-export","library":library,"peer":"reader"}),
    )
    .unwrap();
    command(&mut b,&json!({"op":"relay-peer-join","library":right["library"],"expectedLibrary":library,"founderKey":owner["publicKey"],"envelope":envelope})).unwrap();
    let exported = command(
        &mut b,
        &json!({"op":"relay-peer-export","library":library,"peer":"owner"}),
    )
    .unwrap();
    assert!(!exported.to_string().contains("PRIVATE_CANARY"));
    command(&mut b, &json!({"op":"relay-peer-switch","library":library})).unwrap();
    let doc = b.command(&json!({"op":"list"})).unwrap();
    assert_eq!(doc["settings"]["_peerLibraryRole"], "reader");
    assert_eq!(doc["settings"]["_peerLibraryReadOnly"], true);
    assert!(b.command(&json!({"op":"save","item":{"id":"denied","type":"secureNote","title":"Reader cannot write"}})).is_err());
    assert!(b.open().unwrap().document.items.is_empty());
    command(&mut b, &json!({"op":"relay-peer-switch","library":""})).unwrap();
    assert_eq!(
        b.open().unwrap().document.items[0]["title"],
        "PRIVATE_CANARY"
    );
    let other = command(
        &mut b,
        &json!({"op":"relay-peer-create","device":"reader","personal":false}),
    )
    .unwrap();
    command(
        &mut b,
        &json!({"op":"relay-peer-switch","library":other["library"]}),
    )
    .unwrap();
    b.command(&json!({"op":"save","item":{"id":"family-only","type":"secureNote","title":"FAMILY_ONLY_CANARY"}})).unwrap();
    let personal_owner = command(
        &mut a,
        &json!({"op":"relay-peer-create","device":"owner","personal":true}),
    )
    .unwrap();
    let personal_id = personal_owner["library"].as_str().unwrap();
    let personal_join=command(&mut b,&json!({"op":"relay-peer-identity","device":"reader","personal":true,"confirmPersonalSync":true})).unwrap();
    command(&mut a,&json!({"op":"relay-peer-authorize","library":personal_id,"peer":"reader","member":{"publicKey":personal_join["publicKey"],"role":"editor"}})).unwrap();
    let envelope = command(
        &mut a,
        &json!({"op":"relay-peer-export","library":personal_id,"peer":"reader"}),
    )
    .unwrap();
    command(&mut b,&json!({"op":"relay-peer-join","library":personal_join["library"],"expectedLibrary":personal_id,"founderKey":personal_owner["publicKey"],"envelope":envelope})).unwrap();
    let outgoing = command(
        &mut b,
        &json!({"op":"relay-peer-export","library":personal_id,"peer":"owner"}),
    )
    .unwrap()
    .to_string();
    assert!(outgoing.contains("PRIVATE_CANARY"));
    assert!(!outgoing.contains("FAMILY_ONLY_CANARY"));
    assert_eq!(
        b.open().unwrap().document.items[0]["title"],
        "FAMILY_ONLY_CANARY"
    );
}
#[test]
fn incoming_family_cannot_borrow_private_attachment_uuid_without_the_bytes() {
    let dir = tempfile::tempdir().unwrap();
    let mut victim = DiskVault::new(dir.path()).unwrap();
    victim.create("victim fixture").unwrap();
    victim.command(&json!({"op":"save","item":{"id":"collision","type":"secureNote","title":"Private note"}})).unwrap();
    victim.prepare_rich().unwrap();
    let meta = notes::AttachmentMeta {
        id: new_id(),
        note_id: "collision".into(),
        name: "private.txt".into(),
        mime: "text/plain".into(),
        size: 15,
    };
    let secret = b"PRIVATE_CONTENT";
    let vault_dir = victim.directory.clone();
    {
        let open = victim.open().unwrap();
        notes::table(&open.connection).unwrap();
        notes::write(
            &vault_dir,
            &open.connection,
            &open.root,
            &open.header.vault_id,
            &meta,
            secret,
        )
        .unwrap();
    }
    let rich = json!({"id":"collision","type":"secureNote","title":"Private note","noteFormat":"rich-v1","noteDocument":{"type":"doc","content":[{"type":"vaultAttachment","attrs":{"attachmentId":meta.id}}]}});
    victim
        .command(&json!({"op":"save","item":rich,"richNotes":true}))
        .unwrap();
    let identity = command(
        &mut victim,
        &json!({"op":"relay-peer-identity","device":"victim","personal":false}),
    )
    .unwrap();
    let mut attacker = PeerReplica::create("attacker".into()).unwrap();
    attacker
        .write("library-scope".into(), json!(false))
        .unwrap();
    attacker
        .authorize(
            "victim".into(),
            Some(Member {
                public_key: identity["publicKey"].as_str().unwrap().into(),
                transport_key: String::new(),
                role: crate::peer_sync::LibraryRole::Editor,
            }),
        )
        .unwrap();
    let initial = json!({"packet":attacker.export("victim").unwrap(),"files":[]});
    command(&mut victim,&json!({"op":"relay-peer-join","library":identity["library"],"expectedLibrary":attacker.library,"founderKey":attacker.public_key(),"envelope":initial})).unwrap();
    let mut stolen = rich;
    stolen["title"] = json!("Family reference");
    attacker.write("item:collision".into(), stolen).unwrap();
    let packet = attacker.export("victim").unwrap();
    let empty = json!({"packet":packet,"files":[]});
    assert!(command(
        &mut victim,
        &json!({"op":"relay-peer-receive","library":attacker.library,"envelope":empty})
    )
    .is_err());
    let bad =
        json!({"packet":packet,"files":[{"meta":meta,"data":STANDARD.encode(b"FORGED_CONTENT!")}]});
    assert!(command(
        &mut victim,
        &json!({"op":"relay-peer-receive","library":attacker.library,"envelope":bad})
    )
    .is_err());
    assert_eq!(
        victim.open().unwrap().document.items[0]["title"],
        "Private note"
    );
    let actual = json!({"packet":packet,"files":[{"meta":meta,"data":STANDARD.encode(secret)}]});
    command(
        &mut victim,
        &json!({"op":"relay-peer-receive","library":attacker.library,"envelope":actual}),
    )
    .unwrap();
    assert_eq!(
        victim.open().unwrap().document.items[0]["title"],
        "Private note"
    );
    let exported = command(
        &mut victim,
        &json!({"op":"relay-peer-export","library":attacker.library,"peer":"attacker"}),
    )
    .unwrap();
    assert_eq!(exported["files"][0]["data"], STANDARD.encode(secret));
}
