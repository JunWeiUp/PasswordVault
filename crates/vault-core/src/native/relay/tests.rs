use super::*;
#[test]
fn capability_expiry_and_wrong_identity_do_not_mutate_state() {
    use crypto_box::SecretKey;
    let dir = tempfile::tempdir().unwrap();
    let mut vault = DiskVault::new(dir.path()).unwrap();
    vault.create("fixture").unwrap();
    vault
        .relay_command(
            &json!({"op":"relay-init","role":"hub","group":"test","device":"mac","hub":"mac"}),
        )
        .unwrap();
    let open = vault.open().unwrap();
    let mut state = load(&open.connection, &open.root, &open.header.vault_id).unwrap();
    let a = SecretKey::from([1u8; 32]);
    let b = SecretKey::from([2u8; 32]);
    let aid = capabilities::Identity::parse(&json!({"group":"test","device":"mac","secret":hex::encode(a.to_bytes()),"groups":{"trusted_peers":{"phone":hex::encode(b.public_key().as_bytes())}}}).to_string(), &state).unwrap();
    let mut other = state.clone();
    other.device = "phone".into();
    let bid = capabilities::Identity::parse(&json!({"group":"test","device":"phone","secret":hex::encode(b.to_bytes()),"groups":{"trusted_peers":{"mac":hex::encode(a.public_key().as_bytes())}}}).to_string(), &other).unwrap();
    let challenge = aid
        .command(
            &mut state,
            &json!({"op":"relay-capabilities-challenge","peer":"phone"}),
        )
        .unwrap();
    let proof = bid.command(&mut other,&json!({"op":"relay-capabilities-prove","peer":"mac","challenge":challenge["challenge"]})).unwrap();
    state.challenges.get_mut("phone").unwrap().1 = 0;
    let before = serde_json::to_value(&state).unwrap();
    assert!(matches!(
        aid.command(
            &mut state,
            &json!({"op":"relay-capabilities-accept","peer":"phone","proof":proof["proof"]})
        ),
        Err(VaultError::Authentication)
    ));
    assert_eq!(before, serde_json::to_value(&state).unwrap());
    let renewed = aid
        .command(
            &mut state,
            &json!({"op":"relay-capabilities-challenge","peer":"phone"}),
        )
        .unwrap();
    assert_ne!(renewed, challenge);
    let before = serde_json::to_value(&state).unwrap();
    assert!(aid
        .command(
            &mut state,
            &json!({"op":"relay-capabilities-accept","peer":"unknown","proof":proof["proof"]})
        )
        .is_err());
    assert_eq!(before, serde_json::to_value(&state).unwrap());
}
#[test]
fn failed_journal_write_rolls_back_document() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = DiskVault::new(dir.path()).unwrap();
    vault.create("fixture").unwrap();
    vault
        .relay_command(
            &json!({"op":"relay-init","role":"hub","group":"test","device":"mac","hub":"mac"}),
        )
        .unwrap();
    let open = vault.open().unwrap();
    open.connection.execute_batch("CREATE TRIGGER reject_relay BEFORE UPDATE ON personal_relay BEGIN SELECT RAISE(ABORT,'fixture failure'); END;").unwrap();
    assert!(vault
        .command(
            &json!({"op":"save","item":{"id":"a","type":"password","title":"never committed"}})
        )
        .is_err());
    assert!(vault.open().unwrap().document.items.is_empty());
    vault.lock();
    vault.unlock("fixture").unwrap();
    assert!(vault.open().unwrap().document.items.is_empty());
}
#[test]
fn detach_archive_failure_preserves_binding_and_encrypted_history() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = DiskVault::new(dir.path()).unwrap();
    vault.create("fixture").unwrap();
    vault
        .relay_command(
            &json!({"op":"relay-init","role":"mobile","group":"test","device":"phone","hub":"mac"}),
        )
        .unwrap();
    let before = vault.relay_command(&json!({"op":"relay-status"})).unwrap();
    vault.open().unwrap().connection.execute_batch("CREATE TABLE personal_relay_archive(id INTEGER PRIMARY KEY,payload BLOB NOT NULL); CREATE TRIGGER reject_archive BEFORE INSERT ON personal_relay_archive BEGIN SELECT RAISE(ABORT,'fixture failure'); END;").unwrap();
    assert!(vault
        .relay_command(&json!({"op":"relay-detach","group":"test","device":"phone"}))
        .is_err());
    assert_eq!(
        vault.relay_command(&json!({"op":"relay-status"})).unwrap(),
        before
    );
    vault
        .open()
        .unwrap()
        .connection
        .execute_batch("DROP TRIGGER reject_archive")
        .unwrap();
    vault
        .relay_command(&json!({"op":"relay-detach","group":"test","device":"phone"}))
        .unwrap();
    let open = vault.open().unwrap();
    assert!(!enabled(&open.connection).unwrap());
    assert!(retains_attachments(&open.connection).unwrap());
    let archived: Vec<u8> = open
        .connection
        .query_row("SELECT payload FROM personal_relay_archive", [], |row| {
            row.get(0)
        })
        .unwrap();
    let sealed: Sealed = serde_json::from_slice(&archived).unwrap();
    let raw = unseal(
        &subkey(&open.root, b"personal-relay-v1"),
        &sealed,
        open.header.vault_id.as_bytes(),
    )
    .unwrap();
    let history: State = serde_json::from_slice(&raw).unwrap();
    assert_eq!(history.group, "test");
    assert_eq!(
        history.pending.len() as u64,
        before["pending"].as_u64().unwrap()
    );
}
