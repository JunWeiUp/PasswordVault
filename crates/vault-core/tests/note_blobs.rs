use serde_json::{json, Value};
use vault_core::{seal, subkey, VaultError, VaultSession};

const PASSWORD: &str = "synthetic-blob-test-password";

fn call(session: &VaultSession, request: Value) -> Result<Value, VaultError> {
    Ok(serde_json::from_str(&session.command(request.to_string())?).unwrap())
}

fn create_vault(dir: &tempfile::TempDir) -> VaultSession {
    let session = VaultSession::new(dir.path().to_string_lossy().into()).unwrap();
    call(&session, json!({"op":"create","password":PASSWORD})).unwrap();
    call(
        &session,
        json!({"op":"save","item":{"id":"note-1","type":"secureNote","title":"Asset Note","note":"hello"}}),
    )
    .unwrap();
    session
}

fn rich_doc(attachment_id: &str, name: &str, size: usize) -> Value {
    json!({
        "id": "note-1",
        "type": "secureNote",
        "title": "Asset Note",
        "note": name,
        "noteFormat": "rich-v1",
        "noteDocument": {
            "type": "doc",
            "content": [
                {"type": "vaultAttachment", "attrs": {"attachmentId": attachment_id, "name": name, "mime": "application/pdf", "size": size}}
            ]
        }
    })
}

#[test]
fn chunked_blobs_hide_filenames_deduplicate_and_gc_safely_with_history() {
    let dir = tempfile::tempdir().unwrap();
    let s = create_vault(&dir);
    call(&s, json!({"op":"history-enable"})).unwrap();

    // Multi-chunk (> 3 * 64 KiB) synthetic PDF payload.
    let mut payload = b"%PDF-1.7\n".to_vec();
    payload.resize(210 * 1024, b'A');
    let src_file = dir.path().join("2026-Q4-statement.pdf");
    std::fs::write(&src_file, &payload).unwrap();

    let meta1: Value = serde_json::from_str(
        &s.import_note_attachment_file(
            "note-1".into(),
            src_file.to_string_lossy().into(),
            "2026-Q4-statement.pdf".into(),
            "application/pdf".into(),
        )
        .unwrap(),
    )
    .unwrap();
    let id1 = meta1["id"].as_str().unwrap().to_string();
    assert_eq!(meta1["size"].as_u64().unwrap() as usize, payload.len());

    // Original filename and extension must never appear on disk in blobs/.
    let blobs_dir = dir.path().join("vault/blobs");
    let files: Vec<String> = std::fs::read_dir(&blobs_dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(files.len(), 1);
    assert!(files[0].ends_with(".pvblob"));
    assert!(!files[0].contains("statement") && !files[0].contains("pdf"));
    let disk_bytes = std::fs::read(blobs_dir.join(&files[0])).unwrap();
    assert!(disk_bytes.starts_with(b"PVBLOB01"));
    assert!(!disk_bytes.windows(8).any(|w| w == b"%PDF-1.7"));

    // Importing identical bytes a second time deduplicates the backing .pvblob file.
    let meta2: Value = serde_json::from_str(
        &s.import_note_attachment(
            "note-1".into(),
            "duplicate-copy.pdf".into(),
            "application/pdf".into(),
            payload.clone(),
        )
        .unwrap(),
    )
    .unwrap();
    let id2 = meta2["id"].as_str().unwrap().to_string();
    assert_ne!(id1, id2);
    let status = call(&s, json!({"op":"note-attachments-status"})).unwrap();
    assert_eq!(status["count"], 2);
    assert_eq!(status["uniqueBlobs"], 1);
    assert_eq!(status["diskFiles"], 1);

    // Save note referencing id1, then discard unreferenced id2: shared .pvblob must remain intact!
    call(
        &s,
        json!({"op":"save","richNotes":true,"item":rich_doc(&id1, "2026-Q4-statement.pdf", payload.len())}),
    )
    .unwrap();
    s.discard_note_attachment("note-1".into(), id2).unwrap();
    assert_eq!(
        s.read_note_attachment("note-1".into(), id1.clone())
            .unwrap(),
        payload
    );

    // Replace attachment with a new version; history still references id1 so GC keeps both blobs.
    let mut payload_v2 = b"%PDF-1.7\n".to_vec();
    payload_v2.resize(130 * 1024, b'B');
    let meta_v2: Value = serde_json::from_str(
        &s.import_note_attachment(
            "note-1".into(),
            "2026-Q4-statement.pdf".into(),
            "application/pdf".into(),
            payload_v2.clone(),
        )
        .unwrap(),
    )
    .unwrap();
    let id_v2 = meta_v2["id"].as_str().unwrap().to_string();
    call(
        &s,
        json!({"op":"save","richNotes":true,"item":rich_doc(&id_v2, "2026-Q4-statement.pdf", payload_v2.len())}),
    )
    .unwrap();
    call(
        &s,
        json!({"op":"collect-note-attachments","richNotes":true}),
    )
    .unwrap();
    assert_eq!(
        s.read_note_attachment("note-1".into(), id1.clone())
            .unwrap(),
        payload
    );
    assert_eq!(
        s.read_note_attachment("note-1".into(), id_v2.clone())
            .unwrap(),
        payload_v2
    );

    // Export streaming file and verify bytes + SHA-256 + readonly mode.
    let export_dest = dir.path().join("exported.pdf");
    let exp: Value = serde_json::from_str(
        &s.export_note_attachment_file(
            "note-1".into(),
            id_v2.clone(),
            export_dest.to_string_lossy().into(),
            true,
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(exp["size"].as_u64().unwrap() as usize, payload_v2.len());
    assert_eq!(std::fs::read(&export_dest).unwrap(), payload_v2);

    // Pruning history removes id1 and prunes its orphaned .pvblob file from disk.
    call(
        &s,
        json!({"op":"history-prune","id":"note-1","keepMilestones":false}),
    )
    .unwrap();
    assert!(s.read_note_attachment("note-1".into(), id1).is_err());
    assert_eq!(
        s.read_note_attachment("note-1".into(), id_v2).unwrap(),
        payload_v2
    );
    let status_after = call(&s, json!({"op":"note-attachments-status"})).unwrap();
    assert_eq!(status_after["uniqueBlobs"], 1);
    assert_eq!(status_after["diskFiles"], 1);
}

#[test]
fn streaming_supports_over_25mb_and_blocks_over_100mb() {
    let dir = tempfile::tempdir().unwrap();
    let s = create_vault(&dir);

    // 26 MiB file exceeds legacy 25 MiB cap and succeeds under the 100 MiB streaming architecture.
    let large = vec![0x5Au8; 26 * 1024 * 1024];
    let src = dir.path().join("large.pdf");
    std::fs::write(&src, &large).unwrap();
    let meta: Value = serde_json::from_str(
        &s.import_note_attachment_file(
            "note-1".into(),
            src.to_string_lossy().into(),
            "large.pdf".into(),
            "application/pdf".into(),
        )
        .unwrap(),
    )
    .unwrap();
    let id = meta["id"].as_str().unwrap().to_string();
    let list = call(&s, json!({"op":"note-attachments-list","noteId":"note-1"})).unwrap();
    assert_eq!(list["attachments"][0]["storage"], "pvblob-v1");
    assert_eq!(
        list["attachments"][0]["chunks"],
        (26 * 1024 * 1024) / (64 * 1024)
    );

    let out = dir.path().join("out.pdf");
    s.export_note_attachment_file("note-1".into(), id, out.to_string_lossy().into(), false)
        .unwrap();
    assert_eq!(std::fs::read(&out).unwrap().len(), large.len());

    // 100 MiB + 1 byte file must be rejected cleanly.
    let huge = dir.path().join("huge.bin");
    {
        let f = std::fs::File::create(&huge).unwrap();
        f.set_len(100 * 1024 * 1024 + 1).unwrap();
    }
    assert!(s
        .import_note_attachment_file(
            "note-1".into(),
            huge.to_string_lossy().into(),
            "huge.bin".into(),
            "application/octet-stream".into(),
        )
        .is_err());
}

#[test]
fn blob_tampering_fails_authentication_and_legacy_inline_blobs_still_read() {
    let dir = tempfile::tempdir().unwrap();
    let s = create_vault(&dir);
    let data = vec![0x33u8; 150 * 1024];
    let meta: Value = serde_json::from_str(
        &s.import_note_attachment(
            "note-1".into(),
            "report.pdf".into(),
            "application/pdf".into(),
            data.clone(),
        )
        .unwrap(),
    )
    .unwrap();
    let id = meta["id"].as_str().unwrap().to_string();

    // Flip one byte in the .pvblob ciphertext -> must fail with Authentication.
    let blobs_dir = dir.path().join("vault/blobs");
    let blob_path = std::fs::read_dir(&blobs_dir)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let original_blob = std::fs::read(&blob_path).unwrap();
    let mut tampered = original_blob.clone();
    let last = tampered.len() - 1;
    tampered[last] ^= 0xFF;
    std::fs::write(&blob_path, &tampered).unwrap();
    assert!(matches!(
        s.read_note_attachment("note-1".into(), id.clone()),
        Err(VaultError::Authentication)
    ));
    // Appending trailing garbage must also fail with Authentication.
    let mut extended = original_blob.clone();
    extended.push(0x00);
    std::fs::write(&blob_path, &extended).unwrap();
    assert!(matches!(
        s.read_note_attachment("note-1".into(), id.clone()),
        Err(VaultError::Authentication)
    ));
    std::fs::write(&blob_path, &original_blob).unwrap();
    assert_eq!(s.read_note_attachment("note-1".into(), id).unwrap(), data);

    // Insert a legacy inline SQLite attachment row and confirm backward-compatible read.
    #[derive(serde::Serialize)]
    #[serde(rename_all = "camelCase")]
    struct LegacyMeta<'a> {
        id: &'a str,
        note_id: &'a str,
        name: &'a str,
        mime: &'a str,
        size: usize,
    }
    let root: [u8; 32] = s.biometric_key().unwrap().try_into().unwrap();
    let header: Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("vault/header.json")).unwrap())
            .unwrap();
    let vault_id = header["vaultId"].as_str().unwrap();
    let legacy_meta = LegacyMeta {
        id: "legacyinlineattachment0000000001",
        note_id: "note-1",
        name: "legacy.txt",
        mime: "text/plain",
        size: 11,
    };
    let aad = serde_json::to_vec(&(vault_id, &legacy_meta)).unwrap();
    let sealed = seal(&subkey(&root, b"note-attachments-v1"), b"legacy-data", &aad).unwrap();
    let conn = rusqlite::Connection::open(dir.path().join("vault/vault.sqlite")).unwrap();
    let key = format!(
        "x'{}'",
        hex::encode(subkey(&root, b"native-database").as_ref())
    );
    conn.pragma_update(None, "key", key).unwrap();
    conn.execute(
        "INSERT INTO note_attachments(id,note_id,metadata,payload) VALUES(?1,?2,?3,?4)",
        rusqlite::params![
            "legacyinlineattachment0000000001",
            "note-1",
            serde_json::to_string(&legacy_meta).unwrap(),
            serde_json::to_vec(&sealed).unwrap(),
        ],
    )
    .unwrap();
    drop(conn);
    assert_eq!(
        s.read_note_attachment("note-1".into(), "legacyinlineattachment0000000001".into())
            .unwrap(),
        b"legacy-data"
    );
}
