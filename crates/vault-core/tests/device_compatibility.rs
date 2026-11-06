//! Phase-one compatibility probes, not support for a device schema.
use serde_json::json;
use vault_core::{export_csv, Document};

#[test]
fn unknown_device_type_rejects_the_entire_document() {
    for version in [2, 3, 4, 5, 6] {
        let data = json!({"formatVersion":version,"items":[
            {"id":"ordinary","type":"password","title":"Existing"},
            {"id":"device","type":"device","title":"Synthetic device"}
        ]});
        assert!(Document::parse(&serde_json::to_vec(&data).unwrap()).is_err());
    }
}

#[test]
fn opaque_device_fields_survive_parse_and_merge_but_are_absent_from_csv() {
    let data = json!({"items":[{"id":"device","type":"secureNote","title":"Device",
        "device":{"password":"DEVICE_SECRET_CANARY","files":[{"data":"FILE_CANARY"}]}}]});
    let incoming = Document::parse(&serde_json::to_vec(&data).unwrap()).unwrap();
    let mut document = Document::default();
    document.merge(incoming).unwrap();
    let restored = Document::parse(&serde_json::to_vec(&document).unwrap()).unwrap();
    assert_eq!(restored.items[0]["device"], data["items"][0]["device"]);
    let csv = export_csv(&restored).unwrap();
    assert!(!csv.contains("DEVICE_SECRET_CANARY"));
    assert!(!csv.contains("FILE_CANARY"));
}

#[test]
fn older_snapshot_save_can_silently_remove_opaque_device_data() {
    let old_snapshot = json!({"id":"device","type":"secureNote","title":"Device"});
    let mut decorated = old_snapshot.clone();
    decorated["device"] = json!({"password":"DEVICE_SECRET_CANARY"});
    let mut document = Document::default();
    document.upsert(decorated).unwrap();
    document.upsert(old_snapshot).unwrap();
    // Full-record replacement has no preservation guard for unknown fields.
    assert!(document.items[0].get("device").is_none());
}

#[test]
fn mirroring_device_secrets_into_legacy_fields_leaks_to_csv() {
    let mut document = Document::default();
    document
        .upsert(json!({"id":"device","type":"secureNote","title":"Device",
            "note":"DEVICE_SECRET_CANARY"}))
        .unwrap();
    assert!(export_csv(&document)
        .unwrap()
        .contains("DEVICE_SECRET_CANARY"));
}
