use serde_json::json;
use vault_core::{update_settings, Document};
#[test]
fn ui_settings_cannot_select_a_library_or_rewrite_migration_state() {
    let mut doc = Document::default();
    doc.settings["activePeerLibrary"] = json!("existing-library");
    doc.settings["entryHistoryEnabled"] = json!(true);
    update_settings(&mut doc,&json!({"activePeerLibrary":"attacker-library","peerLibrarySnapshots":[{"records":{}}],"entryHistoryEnabled":false,"theme":"dark","_peerLibraryName":"forged"})).unwrap();
    assert_eq!(doc.settings["activePeerLibrary"], "existing-library");
    assert_eq!(doc.settings["entryHistoryEnabled"], true);
    assert!(doc.settings.get("peerLibrarySnapshots").is_none());
    assert_eq!(doc.settings["theme"], "dark");
    assert!(doc.settings.get("_peerLibraryName").is_none());
}
