//! Peer ("family") libraries were removed. Stored extras may still carry their state; only the
//! personal snapshot is read, to return a vault left switched into a library to its personal
//! records. Everything else is ignored and dropped on the next save.
use super::*;
use std::collections::BTreeMap;
type Records = BTreeMap<String, Value>;

#[derive(Clone, Default, Deserialize)]
pub(super) struct LegacyPeers {
    #[serde(default)]
    personal: Option<Records>,
}

const SETTINGS: [&str; 4] = [
    "activePeerLibrary",
    "_peerLibraryRole",
    "_peerLibraryReadOnly",
    "_peerLibraryName",
];

impl BrowserVault {
    /// Leaves a peer library once, on load. Idempotent: the fixed state is saved by the next
    /// snapshot, and until then it is simply recomputed.
    pub(super) fn leave_peer_library(&mut self) -> Result<()> {
        let peers = std::mem::take(&mut self.extras.peers);
        if self.document.settings["activePeerLibrary"]
            .as_str()
            .is_none_or(str::is_empty)
        {
            return Ok(());
        }
        // Without a personal snapshot the library records are all that is left: keep them.
        if let Some(records) = peers.personal {
            self.document.items = records
                .iter()
                .filter(|(k, v)| k.starts_with("item:") && !v.is_null())
                .map(|(_, v)| v.clone())
                .collect();
            self.document.settings["noteCategories"] =
                records.get("categories").cloned().unwrap_or(json!([]));
        }
        self.document.format_version = self.document.format_version.max(6);
        if let Some(settings) = self.document.settings.as_object_mut() {
            for key in SETTINGS {
                settings.remove(key);
            }
        }
        self.document = Document::parse(
            &serde_json::to_vec(&self.document).map_err(|_| VaultError::InvalidData)?,
        )?;
        Ok(())
    }
}
