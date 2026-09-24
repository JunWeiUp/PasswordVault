use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use vault_core::*;

const PASSWORD: &str = "Disposable test passphrase 47";

#[test]
fn short_local_passwords_create_change_and_restore_without_weakening_storage() {
    let directory = tempfile::tempdir().unwrap();
    let session = VaultSession::new(directory.path().to_string_lossy().into()).unwrap();
    assert!(call(&session, json!({"op":"create","password":""})).is_err());
    call(&session, json!({"op":"create","password":"1"})).unwrap();
    call(&session, json!({"op":"save","item":item("short-password")})).unwrap();
    assert!(call(
        &session,
        json!({"op":"change-password","currentPassword":"1","newPassword":""})
    )
    .is_err());
    call(
        &session,
        json!({"op":"change-password","currentPassword":"1","newPassword":"字"}),
    )
    .unwrap();
    let backup = call(&session, json!({"op":"export","password":PASSWORD})).unwrap()["content"]
        .as_str()
        .unwrap()
        .to_owned();
    drop(session);
    let reopened = VaultSession::new(directory.path().to_string_lossy().into()).unwrap();
    assert!(call(&reopened, json!({"op":"unlock","password":"1"})).is_err());
    call(&reopened, json!({"op":"unlock","password":"字"})).unwrap();
    assert_eq!(
        call(&reopened, json!({"op":"list"})).unwrap()["items"][0]["id"],
        "short-password"
    );
    let restored_dir = tempfile::tempdir().unwrap();
    let restored = VaultSession::new(restored_dir.path().to_string_lossy().into()).unwrap();
    call(&restored,json!({"op":"create-from-backup","content":backup,"backupPassword":PASSWORD,"password":"2","kind":"json"})).unwrap();
    assert_eq!(
        call(&restored, json!({"op":"list"})).unwrap()["items"][0]["id"],
        "short-password"
    );
    let bytes = std::fs::read(restored_dir.path().join("vault/vault.sqlite")).unwrap();
    assert!(!bytes.starts_with(b"SQLite format 3"));
    assert!(!bytes
        .windows(b"synthetic-secret-body-canary".len())
        .any(|w| w == b"synthetic-secret-body-canary"));
}

#[test]
fn every_record_kind_settings_and_recovery_remain_encrypted_while_unlocked() {
    let directory = tempfile::tempdir().unwrap();
    let session = VaultSession::new(directory.path().to_string_lossy().into()).unwrap();
    call(&session, json!({"op":"create","password":PASSWORD})).unwrap();
    let canaries = [
        "PRIVATE-NOTE-CANARY",
        "PRIVATE-PASSWORD-CANARY",
        "PRIVATE-TOTP-CANARY",
        "PRIVATE-WALLET-CANARY",
        "PRIVATE-WEBDAV-CANARY",
    ];
    for (kind, secret) in ["secureNote", "password", "totp", "crypto"]
        .iter()
        .zip(canaries)
    {
        call(&session, json!({"op":"save","item":{"id":kind,"type":kind,"title":secret,"note":secret,"password":secret,"secret":secret,"privateKey":secret,"mnemonic":secret}})).unwrap();
    }
    call(
        &session,
        json!({"op":"settings","settings":{"webdavPassword":canaries[4],"autoLockMinutes":60}}),
    )
    .unwrap();
    let draft = call(
        &session,
        json!({"op":"seal-drafts","items":[item("draft")]}),
    )
    .unwrap();
    std::fs::write(
        directory.path().join("draft-recovery.json"),
        draft.to_string(),
    )
    .unwrap();
    assert_eq!(
        call(&session, json!({"op":"status"})).unwrap()["unlocked"],
        true
    );
    fn scan(path: &std::path::Path, canaries: &[&str]) {
        for entry in std::fs::read_dir(path).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                scan(&path, canaries);
            } else if path.is_file() {
                let bytes = std::fs::read(&path).unwrap();
                for value in canaries {
                    assert!(
                        !bytes.windows(value.len()).any(|w| w == value.as_bytes()),
                        "Plaintext found in {:?}",
                        path.file_name()
                    );
                }
                assert!(!bytes.starts_with(b"SQLite format 3"));
            }
        }
    }
    let mut all = canaries.to_vec();
    all.extend([
        PASSWORD,
        "synthetic-private-title-canary",
        "synthetic-secret-body-canary",
    ]);
    scan(directory.path(), &all);
    let plain = rusqlite::Connection::open_with_flags(
        directory.path().join("vault/vault.sqlite"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    assert!(plain
        .query_row("SELECT count(*) FROM sqlite_master", [], |r| r
            .get::<_, i64>(0))
        .is_err());
    assert_eq!(
        call(&session, json!({"op":"list"})).unwrap()["items"]
            .as_array()
            .unwrap()
            .len(),
        4
    );
}
fn call(session: &VaultSession, request: Value) -> Result<Value> {
    Ok(serde_json::from_str(&session.command(request.to_string())?).unwrap())
}
fn item(id: &str) -> Value {
    json!({"id":id,"type":"secureNote","title":"synthetic-private-title-canary",
    "username":"canary@example.com","note":"synthetic-secret-body-canary","updatedAt":"2020-01-01T00:00:00Z"})
}

#[test]
fn encrypted_disk_reopens_and_lock_denies_all_sensitive_operations() {
    let directory = tempfile::tempdir().unwrap();
    let session = VaultSession::new(directory.path().to_string_lossy().into()).unwrap();
    call(&session, json!({"op":"create","password":PASSWORD})).unwrap();
    call(&session, json!({"op":"save","item":item("one")})).unwrap();
    for path in ["vault/vault.sqlite", "vault/header.json"] {
        let bytes = std::fs::read(directory.path().join(path)).unwrap();
        for canary in [
            PASSWORD,
            "synthetic-private-title-canary",
            "canary@example.com",
            "synthetic-secret-body-canary",
        ] {
            assert!(!bytes.windows(canary.len()).any(|w| w == canary.as_bytes()));
        }
        if path.ends_with("sqlite") {
            assert!(!bytes.starts_with(b"SQLite format 3"));
        }
    }
    call(&session, json!({"op":"lock"})).unwrap();
    for req in [
        json!({"op":"list"}),
        json!({"op":"save","item":item("two")}),
        json!({"op":"export","password":PASSWORD}),
        json!({"op":"matches","origin":"https://example.com"}),
        json!({"op":"remove","id":"one"}),
    ] {
        assert!(matches!(call(&session, req), Err(VaultError::Locked)));
    }
    assert!(session.biometric_key().is_err());
    assert!(call(
        &session,
        json!({"op":"unlock","password":"incorrect password"})
    )
    .is_err());
    drop(session);
    let reopened = VaultSession::new(directory.path().to_string_lossy().into()).unwrap();
    assert_eq!(
        call(&reopened, json!({"op":"status"})).unwrap()["unlocked"],
        false
    );
    call(&reopened, json!({"op":"unlock","password":PASSWORD})).unwrap();
    assert_eq!(
        call(&reopened, json!({"op":"list"})).unwrap()["items"][0]["note"],
        item("one")["note"]
    );
}

#[test]
fn password_change_preserves_all_records_and_rejects_previous_password() {
    let directory = tempfile::tempdir().unwrap();
    let session = VaultSession::new(directory.path().to_string_lossy().into()).unwrap();
    call(&session, json!({"op":"create","password":PASSWORD})).unwrap();
    let record = json!({"id":"identity","type":"crypto","title":"Example wallet","privateKey":"fixture only","accounts":[{"id":"additional","password":"test only"}],"unknownFutureField":{"keep":true}});
    call(&session, json!({"op":"save","item":record})).unwrap();
    let original = call(&session, json!({"op":"list"})).unwrap();
    assert!(call(&session,json!({"op":"change-password","currentPassword":"wrong","newPassword":"Replacement passphrase 98"})).is_err());
    call(&session,json!({"op":"change-password","currentPassword":PASSWORD,"newPassword":"Replacement passphrase 98"})).unwrap();
    call(&session, json!({"op":"lock"})).unwrap();
    assert!(call(&session, json!({"op":"unlock","password":PASSWORD})).is_err());
    call(
        &session,
        json!({"op":"unlock","password":"Replacement passphrase 98"}),
    )
    .unwrap();
    assert_eq!(call(&session, json!({"op":"list"})).unwrap(), original);
}

#[test]
fn backup_randomness_tamper_and_hostile_kdf() {
    let data = serde_json::to_vec(&json!({"items":[item("one")]})).unwrap();
    let first = encrypt_backup(&data, PASSWORD).unwrap();
    let second = encrypt_backup(&data, PASSWORD).unwrap();
    assert_ne!(first, second);
    assert_eq!(decrypt_backup(&first, PASSWORD).unwrap().as_slice(), data);
    assert!(decrypt_backup(&first, "wrong").is_err());
    let mut changed: Value = serde_json::from_str(&first).unwrap();
    changed["kdf"]["memoryKib"] = json!(u64::MAX);
    assert!(decrypt_backup(&changed.to_string(), PASSWORD).is_err());
    changed = serde_json::from_str(&first).unwrap();
    changed["payload"]["ciphertext"] = json!("AAAA");
    assert!(decrypt_backup(&changed.to_string(), PASSWORD).is_err());
}

#[test]
fn reads_flutter_sha256_and_argon_backups_without_dropping_history() {
    let value = json!({"items":[item("one")],"sharedVaults":[{"id":"shared","name":"Example","encryptedVaultKey":"wrapped"}],"sharedMembers":[{"id":"member","role":"owner"}]});
    let data = value.to_string();
    let legacy_key: [u8; 32] = Sha256::digest(PASSWORD.as_bytes()).into();
    let sealed = seal(&legacy_key, data.as_bytes(), b"").unwrap();
    let mut bytes = STANDARD.decode(sealed.nonce).unwrap();
    bytes.extend(STANDARD.decode(sealed.ciphertext).unwrap());
    let legacy =
        json!({"metadata":{"encrypted":true,"version":"3.0.0"},"payload":STANDARD.encode(bytes)});
    let imported = import_document(&legacy.to_string(), PASSWORD, "json").unwrap();
    assert_eq!(
        imported.shared_members,
        value["sharedMembers"].as_array().unwrap().clone()
    );
    let kdf = Kdf {
        salt: STANDARD.encode([17u8; 16]),
        memory_kib: 32768,
        iterations: 2,
        parallelism: 1,
    };
    let sealed = seal(&kdf.derive(PASSWORD).unwrap(), data.as_bytes(), b"").unwrap();
    let mut bytes = STANDARD.decode(sealed.nonce).unwrap();
    bytes.extend(STANDARD.decode(sealed.ciphertext).unwrap());
    let legacy = json!({"metadata":{"encrypted":true,"version":"1.3.0","salt":kdf.salt,"iterations":2,"memory":32768,"parallelism":1},"payload":STANDARD.encode(bytes)});
    assert_eq!(
        import_document(&legacy.to_string(), PASSWORD, "json")
            .unwrap()
            .items
            .len(),
        1
    );
}

#[test]
fn malformed_import_is_atomic_and_existing_ids_are_not_duplicated() {
    let directory = tempfile::tempdir().unwrap();
    let session = VaultSession::new(directory.path().to_string_lossy().into()).unwrap();
    call(&session, json!({"op":"create","password":PASSWORD})).unwrap();
    call(&session, json!({"op":"save","item":item("one")})).unwrap();
    let before = call(&session, json!({"op":"list"})).unwrap();
    let malformed =
        json!({"items":[item("two"),{"id":"broken","title":"missing type"}]}).to_string();
    assert!(call(&session, json!({"op":"import","content":malformed})).is_err());
    assert_eq!(call(&session, json!({"op":"list"})).unwrap(), before);
    let duplicate = json!({"items":[item("one")]}).to_string();
    assert_eq!(
        call(&session, json!({"op":"import","content":duplicate})).unwrap()["imported"],
        0
    );
}

#[test]
fn rfc_totp_and_strict_origin_matching() {
    let key = data_encoding::BASE32_NOPAD.encode(b"12345678901234567890");
    assert_eq!(totp(&key, 30, 59).unwrap(), "287082");
    let uri = format!("otpauth://totp/Example:alex?secret={key}&issuer=Example&period=60");
    assert_eq!(parse_totp_uri(&uri).unwrap()["period"], 60);
    assert!(parse_totp_uri(&(uri.clone() + "&secret=again")).is_err());
    assert!(parse_totp_uri(&(uri + "&algorithm=SHA256")).is_err());
    let records = vec![
        json!({"id":"one","type":"password","title":"test","username":"test","url":"https://example.com"}),
    ];
    assert_eq!(
        matching_accounts(&records, "https://example.com/login")
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        matching_accounts(&records, "https://example.com.attacker.test").unwrap(),
        json!([])
    );
    assert_eq!(
        matching_accounts(&records, "https://sub.example.com").unwrap(),
        json!([])
    );
}

#[test]
fn concurrent_process_cannot_open_or_overwrite_vault() {
    let directory = tempfile::tempdir().unwrap();
    let first = VaultSession::new(directory.path().to_string_lossy().into()).unwrap();
    assert!(matches!(
        VaultSession::new(directory.path().to_string_lossy().into()),
        Err(VaultError::InUse)
    ));
    call(&first, json!({"op":"create","password":PASSWORD})).unwrap();
    assert!(matches!(
        call(&first, json!({"op":"create","password":PASSWORD})),
        Err(VaultError::AlreadyExists)
    ));
}

#[test]
fn encrypted_draft_recovery_is_bound_to_its_vault_and_detects_tampering() {
    let directory = tempfile::tempdir().unwrap();
    let other = tempfile::tempdir().unwrap();
    let a = VaultSession::new(directory.path().to_string_lossy().into()).unwrap();
    let b = VaultSession::new(other.path().to_string_lossy().into()).unwrap();
    for s in [&a, &b] {
        call(s, json!({"op":"create","password":PASSWORD})).unwrap();
    }
    let sealed = call(&a, json!({"op":"seal-drafts","items":[item("draft")]})).unwrap();
    assert!(!sealed.to_string().contains("synthetic-secret-body-canary"));
    assert_eq!(
        call(&a, json!({"op":"open-drafts","payload":sealed["payload"]})).unwrap()["items"][0],
        item("draft")
    );
    assert_eq!(
        call(&a, json!({"op":"list"})).unwrap()["items"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert!(call(&b, json!({"op":"open-drafts","payload":sealed["payload"]})).is_err());

    assert!(call(
        &b,
        json!({"op":"restore-drafts","payload":sealed["payload"]})
    )
    .is_err());
    let mut changed = sealed.clone();
    changed["payload"]["ciphertext"] = json!("AAAA");
    assert!(call(&a, json!({"op":"open-drafts","payload":changed["payload"]})).is_err());
    assert!(call(
        &a,
        json!({"op":"restore-drafts","payload":changed["payload"]})
    )
    .is_err());
    call(&a, json!({"op":"lock"})).unwrap();
    call(&a, json!({"op":"unlock","password":PASSWORD})).unwrap();
    call(
        &a,
        json!({"op":"restore-drafts","payload":sealed["payload"]}),
    )
    .unwrap();
    assert_eq!(
        call(&a, json!({"op":"list"})).unwrap()["items"][0]["note"],
        item("draft")["note"]
    );
}

#[test]
fn additional_accounts_fill_and_audit_keep_the_site_boundary() {
    let records = vec![
        json!({"id":"account","type":"password","title":"Synthetic","username":"primary","password":"Repeated synthetic passphrase","url":"https://example.com","passwordDuration":30,"passwordLastChanged":"2020-01-01T00:00:00Z","accounts":[{"id":"second","username":"secondary","password":"Repeated synthetic passphrase"}]}),
    ];
    let matches = matching_accounts(&records, "https://example.com").unwrap();
    assert_eq!(matches.as_array().unwrap().len(), 2);
    assert_eq!(
        fill_account(&records, "https://example.com", "account", Some("second")).unwrap()
            ["username"],
        "secondary"
    );
    assert!(fill_account(&records, "http://example.com", "account", Some("second")).is_err());
    assert!(fill_account(&records, "https://example.com", "account", Some("missing")).is_err());
    let findings = audit(&records);
    assert_eq!(findings[0]["expired"], true);
    assert_eq!(findings[0]["reused"], true);
}

#[test]
fn same_hostname_matches_across_ports_without_crossing_host_or_https_boundaries() {
    let records = vec![
        json!({"id":"local","type":"password","url":"http://127.0.0.1","username":"demo","password":"fixture-only"}),
        json!({"id":"custom","type":"password","url":"https://example.test:8443","username":"fixture","password":"synthetic"}),
    ];
    for origin in [
        "http://127.0.0.1:4387",
        "http://127.0.0.1:8080",
        "http://127.0.0.1",
    ] {
        assert_eq!(
            fill_account(&records, origin, "local", None).unwrap()["username"],
            "demo"
        );
    }
    for origin in ["https://example.test", "https://example.test:9443"] {
        assert_eq!(
            fill_account(&records, origin, "custom", None).unwrap()["username"],
            "fixture"
        );
    }
    for origin in [
        "http://127.0.0.2:4387",
        "http://localhost:4387",
        "http://127.0.0.1.attacker.test:4387",
    ] {
        assert!(fill_account(&records, origin, "local", None).is_err());
    }
    assert!(fill_account(&records, "https://sub.example.test:8443", "custom", None).is_err());
    assert!(fill_account(&records, "http://example.test:8443", "custom", None).is_err());
}

#[test]
fn native_legacy_migration_is_authenticated_atomic_and_read_only() {
    use base64::{engine::general_purpose::STANDARD, Engine};
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("legacy.sqlite");
    let key = Kdf {
        salt: STANDARD.encode([7u8; 16]),
        memory_kib: 32768,
        iterations: 2,
        parallelism: 1,
    }
    .derive(PASSWORD)
    .unwrap();
    let sealed = seal(&key, b"legacy-note-canary", b"").unwrap();
    let mut bytes = STANDARD.decode(sealed.nonce).unwrap();
    bytes.extend(STANDARD.decode(sealed.ciphertext).unwrap());
    let conn = rusqlite::Connection::open(&source).unwrap();
    conn.execute_batch("PRAGMA user_version=12; CREATE TABLE vault_items(id TEXT, type INTEGER, title TEXT, username TEXT, note TEXT, updated_at INTEGER, is_deleted INTEGER);").unwrap();
    conn.execute(
        "INSERT INTO vault_items VALUES('legacy-1',3,'Old note','',?1,1700000000,0)",
        [STANDARD.encode(bytes)],
    )
    .unwrap();
    drop(conn);
    let before = std::fs::read(&source).unwrap();
    let destination = directory.path().join("native");
    let session = VaultSession::new(destination.to_string_lossy().into()).unwrap();
    let request = json!({"op":"create-migrated","source":source,"legacyPassword":"wrong","salt":STANDARD.encode([7u8;16]),"password":PASSWORD});
    assert!(call(&session, request.clone()).is_err());
    assert!(!call(&session, json!({"op":"status"})).unwrap()["exists"]
        .as_bool()
        .unwrap());
    let mut request = request;
    request["legacyPassword"] = json!(PASSWORD);
    assert_eq!(call(&session, request).unwrap()["imported"], 1);
    let document = call(&session, json!({"op":"list"})).unwrap();
    assert_eq!(document["items"][0]["id"], "legacy-1");
    assert_eq!(document["items"][0]["note"], "legacy-note-canary");
    assert_eq!(std::fs::read(source).unwrap(), before);
}

#[test]
fn creating_from_backup_rejects_wrong_password_without_empty_vault() {
    let directory = tempfile::tempdir().unwrap();
    let source = serde_json::to_vec(&json!({"items":[item("migration-fixture")]})).unwrap();
    let backup = encrypt_backup(&source, PASSWORD).unwrap();
    let session = VaultSession::new(directory.path().to_string_lossy().into()).unwrap();
    let mut request = json!({"op":"create-from-backup","content":backup,"backupPassword":"wrong","password":PASSWORD});
    assert!(call(&session, request.clone()).is_err());
    assert_eq!(
        call(&session, json!({"op":"status"})).unwrap()["exists"],
        false
    );
    request["backupPassword"] = json!(PASSWORD);
    assert_eq!(call(&session, request).unwrap()["imported"], 1);
    assert_eq!(
        call(&session, json!({"op":"list"})).unwrap()["items"][0]["id"],
        "migration-fixture"
    );
}

#[test]
fn encrypted_csv_uses_native_backup_crypto_and_rejects_tampering_without_mutation() {
    let directory = tempfile::tempdir().unwrap();
    let session = VaultSession::new(directory.path().to_string_lossy().into()).unwrap();
    call(&session, json!({"op":"create","password":PASSWORD})).unwrap();
    let record = json!({"id":"csv-fixture","type":"password","title":"CSV canary","username":"sample@example.test","password":"CSV_SECRET_CANARY","note":"comma, quote \" and\nnew line"});
    call(&session, json!({"op":"save","item":record})).unwrap();
    let content = call(
        &session,
        json!({"op":"export-csv-backup","password":PASSWORD}),
    )
    .unwrap()["content"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(!content.contains("CSV_SECRET_CANARY"));
    let restored = import_document(&content, PASSWORD, "json").unwrap();
    assert_eq!(restored.items.len(), 1);
    assert_eq!(restored.items[0]["password"], record["password"]);
    assert_eq!(restored.items[0]["note"], record["note"]);
    assert!(call(
        &session,
        json!({"op":"import","content":content,"password":"wrong","kind":"json"})
    )
    .is_err());
    let mut changed: Value = serde_json::from_str(&content).unwrap();
    changed["envelope"]["payload"]["ciphertext"] = json!("AAAA");
    assert!(call(
        &session,
        json!({"op":"import","content":changed.to_string(),"password":PASSWORD,"kind":"json"})
    )
    .is_err());
    assert_eq!(
        call(&session, json!({"op":"list"})).unwrap()["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    changed = serde_json::from_str(&content).unwrap();
    changed["version"] = json!(99);
    assert!(import_document(&changed.to_string(), PASSWORD, "json").is_err());
}

#[test]
fn legacy_csv_aliases_and_short_rows_preserve_credentials() {
    let csv = "type,title,user,private_key,note\ncrypto,Alias wallet,owner,fictional-private-key\npassword,Login,user-name,,memo\n";
    let doc = import_document(csv, "", "csv").unwrap();
    assert_eq!(doc.items[0]["username"], "owner");
    assert_eq!(doc.items[0]["privateKey"], "fictional-private-key");
    assert_eq!(doc.items[1]["username"], "user-name");
    assert_eq!(doc.items[1]["note"], "memo");
    assert!(import_document("title,user\nName,User,unexpected\n", "", "csv").is_err());
}
