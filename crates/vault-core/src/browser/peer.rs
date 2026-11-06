use super::*;
use crate::archive::{AttachmentMeta, HistoryRevision};
use crate::peer_sync::{Member, PeerPacket, PeerReplica};
use crypto_box::{
    aead::{Aead, AeadCore, OsRng},
    PublicKey, SalsaBox, SecretKey,
};
use std::collections::{BTreeMap, BTreeSet};
type Records = BTreeMap<String, Value>;
#[derive(Clone, Default, Serialize, Deserialize)]
pub(super) struct BrowserPeerState {
    pub libraries: BTreeMap<String, BrowserLibrary>,
    pub personal: Option<Records>,
    pub transport: Option<Transport>,
    #[serde(default)]
    pub chunks: crate::peer_sync::ChunkAssembler,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct BrowserLibrary {
    replica: PeerReplica,
    baseline: Records,
    personal: bool,
    #[serde(default)]
    hidden: BTreeSet<String>,
    #[serde(default)]
    local_attachments: BTreeSet<String>,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Transport {
    secret: [u8; 32],
    device: String,
    group: String,
    token: String,
    gateway: String,
    #[serde(default)]
    endpoint: String,
    pending: Value,
}
impl Drop for Transport {
    fn drop(&mut self) {
        self.secret.zeroize();
        self.token.zeroize();
    }
}
fn records(doc: &Document) -> Records {
    let mut records = Records::new();
    for item in &doc.items {
        records.insert(
            format!("item:{}", item["id"].as_str().unwrap_or("")),
            item.clone(),
        );
    }
    records.insert("categories".into(), json!(doc.note_categories()));
    records
}
fn install(doc: &mut Document, records: &Records) -> Result<()> {
    doc.items = records
        .iter()
        .filter(|(k, v)| k.starts_with("item:") && !v.is_null())
        .map(|(_, v)| v.clone())
        .collect();
    doc.settings["noteCategories"] = records.get("categories").cloned().unwrap_or(json!([]));
    doc.format_version = doc.format_version.max(6);
    *doc = Document::parse(&serde_json::to_vec(doc).map_err(|_| VaultError::InvalidData)?)?;
    Ok(())
}
fn selected(doc: &Document, l: &BrowserLibrary) -> bool {
    let active = doc.settings["activePeerLibrary"].as_str().unwrap_or("");
    if active.is_empty() {
        l.personal
    } else {
        !l.personal && active == l.replica.library
    }
}
fn text<'a>(request: &'a Value, key: &str) -> Result<&'a str> {
    request[key].as_str().ok_or(VaultError::InvalidData)
}
fn committed_attachment_refs(
    library: &BrowserLibrary,
) -> Result<std::collections::HashSet<String>> {
    let mut refs = std::collections::HashSet::new();
    for value in library
        .baseline
        .values()
        .chain(library.replica.operations.values().map(|o| &o.value))
    {
        crate::archive::item_attachment_refs(value, &mut refs)?;
    }
    Ok(refs)
}
fn require_attachment_scope(
    value: &Value,
    known: &std::collections::HashSet<String>,
    provided: &BTreeSet<String>,
) -> Result<()> {
    let mut refs = std::collections::HashSet::new();
    crate::archive::item_attachment_refs(value, &mut refs)?;
    if refs
        .iter()
        .any(|id| !known.contains(id) && !provided.contains(id))
    {
        return Err(VaultError::Authentication);
    }
    Ok(())
}
impl BrowserVault {
    pub(super) fn mutate_personal_passkey(
        &mut self,
        operation: impl FnOnce(&mut Document) -> Result<Value>,
    ) -> Result<Value> {
        if self.document.settings["activePeerLibrary"]
            .as_str()
            .is_none_or(|id| id.is_empty())
        {
            return operation(&mut self.document);
        }
        let mut visible = self.document.clone();
        let extras = self.extras.clone();
        let result = (|| {
            let personal = self
                .extras
                .peers
                .personal
                .clone()
                .ok_or(VaultError::InvalidData)?;
            install(&mut self.document, &personal)?;
            self.document.settings["activePeerLibrary"] = json!("");
            let before = self.document.clone();
            let result = operation(&mut self.document)?;
            self.capture_peers(&before)?;
            self.capture_history(&before)?;
            self.extras.peers.personal = Some(records(&self.document));
            Ok(result)
        })();
        if result.is_ok() {
            visible.format_version = visible.format_version.max(self.document.format_version);
        }
        self.document = visible;
        if result.is_err() {
            self.extras = extras;
        }
        result
    }

    pub(super) fn peer_editable_document(&self) -> Document {
        let mut doc = self.document.clone();
        doc.settings["_peerLibraryName"] = json!("");
        let active = doc.settings["activePeerLibrary"]
            .as_str()
            .is_some_and(|s| !s.is_empty());
        doc.settings["_peerLibraryRole"] = json!(if active { "blocked" } else { "admin" });
        doc.settings["_peerLibraryReadOnly"] = json!(active);
        if let Some(l) = self
            .extras
            .peers
            .libraries
            .values()
            .find(|l| selected(&doc, l) && !l.replica.controls.is_empty())
        {
            let role = l
                .replica
                .members()
                .ok()
                .and_then(|m| m.get(&l.replica.device))
                .map(|m| &m.role);
            doc.settings["_peerLibraryRole"] = serde_json::to_value(role).unwrap_or(Value::Null);
            doc.settings["_peerLibraryReadOnly"] = json!(
                l.replica.frozen
                    || !l.replica.has_local_access()
                    || !matches!(
                        role,
                        Some(
                            crate::peer_sync::LibraryRole::Admin
                                | crate::peer_sync::LibraryRole::Editor
                        )
                    )
            );
            if !l.personal {
                doc.settings["_peerLibraryName"] = json!(l
                    .replica
                    .resolved()
                    .get("library-name")
                    .and_then(Value::as_str)
                    .unwrap_or("Family library"));
            }
            for item in &mut doc.items {
                item["_peerBaseHeads"] = json!(l
                    .replica
                    .heads(&format!("item:{}", item["id"].as_str().unwrap_or("")))
                    .iter()
                    .map(|o| &o.id)
                    .collect::<Vec<_>>());
                item["_peerLibrary"] = json!(l.replica.library);
            }
        }
        doc
    }
    pub(super) fn peer_prepare_save(&self, item: &Value) -> Result<Value> {
        let mut item = item.clone();
        if let Some(l) = self
            .extras
            .peers
            .libraries
            .values()
            .find(|l| selected(&self.document, l) && !l.replica.controls.is_empty())
        {
            let key = format!(
                "item:{}",
                item["id"].as_str().ok_or(VaultError::InvalidData)?
            );
            if item
                .get("_peerLibrary")
                .is_some_and(|id| id.as_str() != Some(l.replica.library.as_str()))
                || !l
                    .replica
                    .edit_base_matches(&key, item.get("_peerBaseHeads"))
            {
                return Err(VaultError::StaleEdit);
            }
        } else if item.get("_peerLibrary").is_some() {
            return Err(VaultError::StaleEdit);
        }
        let fields = item.as_object_mut().ok_or(VaultError::InvalidData)?;
        fields.remove("_peerBaseHeads");
        fields.remove("_peerLibrary");
        Ok(item)
    }
    pub(super) fn peer_save_result(&self, id: &str) -> Value {
        if let Some(l) = self
            .extras
            .peers
            .libraries
            .values()
            .find(|l| selected(&self.document, l) && !l.replica.controls.is_empty())
        {
            json!({"ok":true,"peerBaseHeads":l.replica.heads(&format!("item:{id}")).iter().map(|o|&o.id).collect::<Vec<_>>(),"peerLibrary":l.replica.library})
        } else {
            json!({"ok":true})
        }
    }
    pub(super) fn peer_readable_documents(&self) -> Result<Vec<(String, Document)>> {
        let mut personal = self.document.clone();
        if personal.settings["activePeerLibrary"]
            .as_str()
            .is_some_and(|s| !s.is_empty())
        {
            install(
                &mut personal,
                self.extras
                    .peers
                    .personal
                    .as_ref()
                    .ok_or(VaultError::InvalidData)?,
            )?;
        }
        personal.settings["activePeerLibrary"] = json!("");
        let mut documents = vec![(String::new(), personal)];
        for (id, l) in &self.extras.peers.libraries {
            if l.personal
                || l.replica.frozen
                || !l
                    .replica
                    .members()
                    .is_ok_and(|m| m.contains_key(&l.replica.device))
            {
                continue;
            }
            let mut doc = self.document.clone();
            let mut values = l.baseline.clone();
            values.extend(l.replica.resolved());
            install(&mut doc, &values)?;
            doc.settings["activePeerLibrary"] = json!(id);
            documents.push((id.clone(), doc));
        }
        Ok(documents)
    }
    pub(super) fn peer_register_local_attachment(&mut self, id: &str) -> Result<()> {
        if let Some(l) = self
            .extras
            .peers
            .libraries
            .values_mut()
            .find(|l| selected(&self.document, l) && !l.replica.controls.is_empty())
        {
            l.replica.require_write_access()?;
            l.local_attachments.insert(id.into());
        }
        Ok(())
    }
    pub(super) fn peer_forget_local_attachment(&mut self, id: &str) {
        for library in self.extras.peers.libraries.values_mut() {
            library.local_attachments.remove(id);
        }
    }
    pub(super) fn capture_peers(&mut self, before: &Document) -> Result<()> {
        if before.settings["activePeerLibrary"] != self.document.settings["activePeerLibrary"] {
            return Ok(());
        }
        for l in self.extras.peers.libraries.values_mut() {
            if !selected(&self.document, l) || l.replica.controls.is_empty() {
                continue;
            }
            let now = records(&self.document);
            let known = committed_attachment_refs(l)?;
            let keys: BTreeSet<_> = now.keys().chain(l.baseline.keys()).cloned().collect();
            for key in keys {
                if key != "categories" && !key.starts_with("item:") {
                    continue;
                }
                let value = now.get(&key).cloned().unwrap_or(Value::Null);
                if l.baseline.get(&key).unwrap_or(&Value::Null) != &value {
                    require_attachment_scope(&value, &known, &l.local_attachments)?;
                    l.replica.write(key, value)?;
                }
            }
            l.baseline = now;
        }
        Ok(())
    }
    pub(super) fn peer_retained_items(&self) -> Vec<Value> {
        let mut all = Vec::new();
        if let Some(personal) = &self.extras.peers.personal {
            all.extend(
                personal
                    .iter()
                    .filter(|(k, v)| k.starts_with("item:") && !v.is_null())
                    .map(|(_, v)| v.clone()),
            );
        }
        for l in self.extras.peers.libraries.values() {
            all.extend(
                l.baseline
                    .iter()
                    .filter(|(k, v)| k.starts_with("item:") && !v.is_null())
                    .map(|(_, v)| v.clone()),
            );
            all.extend(
                l.replica
                    .operations
                    .values()
                    .filter(|o| o.key.starts_with("item:") && !o.value.is_null())
                    .map(|o| o.value.clone()),
            );
        }
        all
    }
    pub(super) fn peer_backup_document(&self) -> Result<Document> {
        let mut doc = self.document.clone();
        if doc.settings["activePeerLibrary"]
            .as_str()
            .is_some_and(|s| !s.is_empty())
        {
            install(
                &mut doc,
                self.extras
                    .peers
                    .personal
                    .as_ref()
                    .ok_or(VaultError::InvalidData)?,
            )?;
        }
        doc.settings
            .as_object_mut()
            .ok_or(VaultError::InvalidData)?
            .remove("activePeerLibrary");
        let snapshots:Vec<_>=self.extras.peers.libraries.values().filter(|l|!l.personal&&!l.replica.controls.is_empty()).map(|l|json!({"packet":PeerPacket{version:2,library:l.replica.library.clone(),controls:l.replica.controls.clone(),operations:l.replica.operations.values().cloned().collect()},"records":l.baseline})).collect();
        if !snapshots.is_empty() {
            doc.settings["peerLibrarySnapshots"] = json!(snapshots);
        }
        Ok(doc)
    }
    pub(super) fn peer_restore_snapshots(&mut self, snapshots: &Value) -> Result<()> {
        if snapshots.is_null() {
            return Ok(());
        }
        let snapshots = snapshots.as_array().ok_or(VaultError::InvalidData)?;
        if snapshots.len() > 256 {
            return Err(VaultError::InvalidData);
        }
        for snapshot in snapshots {
            let packet: PeerPacket = serde_json::from_value(snapshot["packet"].clone())
                .map_err(|_| VaultError::InvalidData)?;
            let replica = PeerReplica::recover_copy(&packet, format!("recovered-{}", new_id()))?;
            let baseline: Records = serde_json::from_value(snapshot["records"].clone())
                .map_err(|_| VaultError::InvalidData)?;
            install(&mut Document::default(), &baseline)?;
            self.extras.peers.libraries.insert(
                replica.library.clone(),
                BrowserLibrary {
                    replica,
                    baseline,
                    personal: false,
                    hidden: BTreeSet::new(),
                    local_attachments: BTreeSet::new(),
                },
            );
        }
        Ok(())
    }
    pub(super) fn peer_command(&mut self, request: &Value) -> Result<Value> {
        let op = text(request, "op")?;
        if ["relay-peer-join", "relay-peer-receive"].contains(&op)
            && request["envelope"]["protocol"] == "peer-v2-chunk"
        {
            let sender = text(request, "sender")?;
            let envelope = &request["envelope"];
            if let Some(complete) = self.extras.peers.chunks.ingest(sender, envelope)? {
                let mut next = request.clone();
                next["envelope"] = complete;
                let result = self.peer_command(&next)?;
                self.extras
                    .peers
                    .chunks
                    .forget(sender, text(envelope, "transfer")?);
                return Ok(result);
            } else {
                return Ok(json!({"ok":true,"partial":true}));
            }
        }
        if op.starts_with("peer-transport-") {
            return self.transport_command(request);
        }
        if op == "relay-peer-list" {
            return Ok(
                json!({"active":self.document.settings["activePeerLibrary"],"libraries":self.extras.peers.libraries.iter().map(|(id,l)|json!({"id":id,"personal":l.personal,"name":l.replica.resolved().get("library-name").and_then(Value::as_str).map(|s|json!(s)).unwrap_or(json!(id)),"role":l.replica.members().ok().and_then(|m|m.get(&l.replica.device)).map(|m|&m.role)})).collect::<Vec<_>>()}),
            );
        }
        if op == "relay-peer-switch" {
            let id = text(request, "library")?;
            let active = self.document.settings["activePeerLibrary"]
                .as_str()
                .unwrap_or("");
            if active == id {
                return Ok(json!({"ok":true}));
            }
            let values = if id.is_empty() {
                self.extras
                    .peers
                    .personal
                    .clone()
                    .ok_or(VaultError::InvalidData)?
            } else {
                let l = self
                    .extras
                    .peers
                    .libraries
                    .get(id)
                    .ok_or(VaultError::InvalidData)?;
                if l.personal || l.replica.controls.is_empty() {
                    return Err(VaultError::InvalidData);
                }
                let mut values = l.baseline.clone();
                values.extend(l.replica.resolved());
                values
            };
            if active.is_empty() {
                self.extras.peers.personal = Some(records(&self.document));
            }
            install(&mut self.document, &values)?;
            self.document.settings["activePeerLibrary"] = json!(id);
            for library in self.extras.peers.libraries.values_mut() {
                if selected(&self.document, library) && !library.replica.controls.is_empty() {
                    library.baseline = records(&self.document);
                }
            }
            self.validate_extras()?;
            return Ok(json!({"ok":true}));
        }
        if op == "relay-peer-create" || op == "relay-peer-identity" {
            let personal = request["personal"].as_bool().unwrap_or(false);
            if op == "relay-peer-identity" && personal && request["confirmPersonalSync"] != true {
                return Err(VaultError::Authentication);
            }
            if personal && self.extras.peers.libraries.values().any(|l| l.personal) {
                return Err(VaultError::AlreadyExists);
            }
            let mut replica = if op == "relay-peer-create" {
                PeerReplica::create(text(request, "device")?.into())?
            } else {
                PeerReplica::identity(text(request, "device")?.into())?
            };
            let baseline = if personal {
                if self.document.settings["activePeerLibrary"]
                    .as_str()
                    .is_some_and(|s| !s.is_empty())
                {
                    self.extras
                        .peers
                        .personal
                        .clone()
                        .ok_or(VaultError::InvalidData)?
                } else {
                    records(&self.document)
                }
            } else {
                Records::new()
            };
            if op == "relay-peer-create" {
                if let Some(key) = request["transportKey"].as_str() {
                    replica.authorize(
                        replica.device.clone(),
                        Some(Member {
                            public_key: replica.public_key(),
                            transport_key: key.into(),
                            role: crate::peer_sync::LibraryRole::Admin,
                        }),
                    )?;
                }
                replica.write("library-scope".into(), json!(personal))?;
                for (k, v) in &baseline {
                    replica.write(k.clone(), v.clone())?;
                }
                if !personal {
                    let name = request["name"].as_str().unwrap_or("Family library");
                    if name.trim().is_empty() || name.len() > 128 {
                        return Err(VaultError::InvalidData);
                    }
                    replica.write("library-name".into(), json!(name))?;
                }
            } else {
                replica.library = format!("pending-{}", new_id());
            }
            let result = json!({"library":replica.library,"device":replica.device,"publicKey":replica.public_key()});
            self.extras.peers.libraries.insert(
                replica.library.clone(),
                BrowserLibrary {
                    replica,
                    baseline,
                    personal,
                    hidden: BTreeSet::new(),
                    local_attachments: BTreeSet::new(),
                },
            );
            self.document.format_version = self.document.format_version.max(6);
            return Ok(result);
        }
        let id = text(request, "library")?;
        let mut l = self
            .extras
            .peers
            .libraries
            .get(id)
            .cloned()
            .ok_or(VaultError::InvalidData)?;
        if op == "relay-peer-cancel-join" {
            if !l.replica.controls.is_empty() {
                return Err(VaultError::Authentication);
            }
            self.extras.peers.libraries.remove(id);
            if let Some(transport) = &mut self.extras.peers.transport {
                if transport.pending["localLibrary"] == id {
                    transport.pending = Value::Null;
                }
            }
            return Ok(json!({"ok":true}));
        }
        if op == "relay-peer-status" {
            return Ok(
                json!({"library":l.replica.library,"device":l.replica.device,"publicKey":l.replica.public_key(),"personal":l.personal,"generation":l.replica.generation(),"frozen":l.replica.frozen,"members":l.replica.members().ok(),"conflicts":l.replica.conflicts(),"records":l.replica.resolved()}),
            );
        }
        if op == "relay-peer-export" {
            let packet = l.replica.export(text(request, "peer")?)?;
            let mut ids = std::collections::HashSet::new();
            for o in &packet.operations {
                crate::archive::item_attachment_refs(&o.value, &mut ids)?;
            }
            let files = self
                .extras
                .attachments
                .iter()
                .filter(|m| ids.contains(&m.id))
                .map(|m| {
                    Ok(json!({"meta":m,"data":STANDARD.encode(self.read_file(m)?.as_slice())}))
                })
                .collect::<Result<Vec<_>>>()?;
            return Ok(json!({"protocol":"peer-v2","packet":packet,"files":files}));
        }
        if op == "relay-peer-history-status" || op == "relay-peer-history-enable" {
            return Ok(json!({"ok":true,"enabled":true}));
        }
        if op == "relay-peer-history-list" {
            let key = format!("item:{}", text(request, "id")?);
            let mut revisions: Vec<_> = l
                .replica
                .operations
                .values()
                .filter(|o| o.key == key && !l.hidden.contains(&o.id))
                .map(|o| HistoryRevision {
                    id: o.id.clone(),
                    item_id: text(request, "id").unwrap().into(),
                    captured_at: o.captured_at,
                    item: o.value.clone(),
                })
                .collect();
            revisions.sort_by(|a, b| b.captured_at.cmp(&a.captured_at).then(b.id.cmp(&a.id)));
            let total = revisions.len();
            return Ok(
                json!({"total":total,"revisions":revisions.into_iter().skip(request["offset"].as_u64().unwrap_or(0) as usize).take(request["limit"].as_u64().unwrap_or(100).clamp(1,500) as usize).collect::<Vec<_>>()}),
            );
        }
        match op {
            "relay-peer-rekey" => {
                if l.replica.members()?.get(&l.replica.device).map(|m| &m.role)
                    != Some(&crate::peer_sync::LibraryRole::Admin)
                {
                    return Err(VaultError::Authentication);
                }
                let packet = PeerPacket {
                    version: 2,
                    library: l.replica.library.clone(),
                    controls: l.replica.controls.clone(),
                    operations: l.replica.operations.values().cloned().collect(),
                };
                let mut replica =
                    PeerReplica::recover_copy(&packet, text(request, "device")?.into())?;
                replica.authorize(
                    replica.device.clone(),
                    Some(Member {
                        public_key: replica.public_key(),
                        transport_key: text(request, "transportKey")?.into(),
                        role: crate::peer_sync::LibraryRole::Admin,
                    }),
                )?;
                if self.document.settings["activePeerLibrary"] == id {
                    self.document.settings["activePeerLibrary"] = json!(replica.library);
                }
                l.replica = replica;
                l.hidden.clear();
            }
            "relay-peer-authorize" => {
                l.replica.authorize(
                    text(request, "peer")?.into(),
                    if request["member"].is_null() {
                        None
                    } else {
                        Some(
                            serde_json::from_value(request["member"].clone())
                                .map_err(|_| VaultError::InvalidData)?,
                        )
                    },
                )?;
            }
            "relay-peer-join" | "relay-peer-receive" => {
                let packet: PeerPacket =
                    serde_json::from_value(request["envelope"]["packet"].clone())
                        .map_err(|_| VaultError::InvalidData)?;
                let known = committed_attachment_refs(&l)?;
                let provided: BTreeSet<String> = request["envelope"]["files"]
                    .as_array()
                    .ok_or(VaultError::InvalidData)?
                    .iter()
                    .map(|file| text(&file["meta"], "id").map(str::to_owned))
                    .collect::<Result<_>>()?;
                for operation in &packet.operations {
                    require_attachment_scope(&operation.value, &known, &provided)?;
                }
                if op == "relay-peer-join" {
                    l.replica.join(
                        &packet,
                        text(request, "expectedLibrary")?,
                        text(request, "founderKey")?,
                    )?;
                    if l.replica.scope()? != Some(l.personal) {
                        return Err(VaultError::Authentication);
                    }
                    if l.personal {
                        let local = if self.document.settings["activePeerLibrary"]
                            .as_str()
                            .is_some_and(|s| !s.is_empty())
                        {
                            self.extras
                                .peers
                                .personal
                                .clone()
                                .ok_or(VaultError::InvalidData)?
                        } else {
                            records(&self.document)
                        };
                        for (key, value) in local {
                            if l.replica.resolved().get(&key) != Some(&value) {
                                l.replica.import_local(key, value)?;
                            }
                        }
                    }
                } else if let Err(error) = l.replica.receive(&packet) {
                    if l.replica.frozen {
                        self.extras.peers.libraries.insert(id.into(), l);
                        return Ok(json!({"ok":false,"frozen":true}));
                    }
                    return Err(error);
                }
                let files = request["envelope"]["files"]
                    .as_array()
                    .ok_or(VaultError::InvalidData)?;
                for file in files {
                    let meta: AttachmentMeta = serde_json::from_value(file["meta"].clone())
                        .map_err(|_| VaultError::InvalidData)?;
                    let bytes = Zeroizing::new(
                        STANDARD
                            .decode(text(file, "data")?)
                            .map_err(|_| VaultError::InvalidData)?,
                    );
                    if bytes.len() != meta.size || meta.size > crate::archive::FILE_LIMIT {
                        return Err(VaultError::InvalidData);
                    }
                    if let Some(old) = self.extras.attachments.iter().find(|m| m.id == meta.id) {
                        if serde_json::to_value(old).ok() != serde_json::to_value(&meta).ok()
                            || self.read_file(old)?.as_slice() != bytes.as_slice()
                        {
                            return Err(VaultError::Authentication);
                        }
                    } else {
                        let sealed = seal(
                            &subkey(&self.root, b"note-attachments-v1"),
                            &bytes,
                            &crate::archive::attachment_aad(&self.header.vault_id, &meta)?,
                        )?;
                        Arc::make_mut(&mut self.files).insert(meta.id.clone(), sealed);
                        self.extras.attachments.push(meta);
                    }
                }
            }
            "relay-peer-write" | "relay-peer-resolve" => {
                let key = text(request, "key")?;
                if op == "relay-peer-resolve" && l.replica.heads(key).len() < 2 {
                    return Err(VaultError::InvalidData);
                }
                let value = request.get("value").ok_or(VaultError::InvalidData)?.clone();
                require_attachment_scope(
                    &value,
                    &committed_attachment_refs(&l)?,
                    &l.local_attachments,
                )?;
                l.replica.write(key.into(), value)?;
            }
            "relay-peer-history-restore" => {
                let key = format!("item:{}", text(request, "id")?);
                let old = l
                    .replica
                    .operations
                    .get(text(request, "revisionId")?)
                    .ok_or(VaultError::InvalidData)?;
                if old.key != key || old.value.is_null() {
                    return Err(VaultError::InvalidData);
                }
                let mut value = old.value.clone();
                chrono::DateTime::parse_from_rfc3339(text(request, "time")?)
                    .map_err(|_| VaultError::InvalidData)?;
                value["updatedAt"] = request["time"].clone();
                l.replica.write(key, value)?;
            }
            "relay-peer-history-prune" => {
                let key = format!("item:{}", text(request, "id")?);
                let heads: BTreeSet<_> =
                    l.replica.heads(&key).iter().map(|o| o.id.clone()).collect();
                l.hidden.extend(
                    l.replica
                        .operations
                        .values()
                        .filter(|o| o.key == key && !heads.contains(&o.id))
                        .map(|o| o.id.clone()),
                );
            }
            _ => return Err(VaultError::Unsupported),
        }
        let is_selected = selected(&self.document, &l);
        let mut values = if is_selected {
            records(&self.document)
        } else {
            l.baseline.clone()
        };
        values.extend(l.replica.resolved());
        l.baseline = values.clone();
        if is_selected {
            install(&mut self.document, &values)?;
            l.baseline = records(&self.document);
        } else if l.personal {
            self.extras.peers.personal = Some(values);
        }
        let output = json!({"ok":true,"library":l.replica.library,"publicKey":l.replica.public_key(),"device":l.replica.device,"personal":l.personal});
        self.extras.peers.libraries.remove(id);
        self.extras
            .peers
            .libraries
            .insert(l.replica.library.clone(), l);
        self.validate_extras()?;
        Ok(output)
    }
    fn transport_command(&mut self, request: &Value) -> Result<Value> {
        let op = text(request, "op")?;
        if op == "peer-transport-identity" && self.extras.peers.transport.is_none() {
            self.extras.peers.transport = Some(Transport {
                secret: random_bytes(),
                device: new_id(),
                group: String::new(),
                token: String::new(),
                gateway: String::new(),
                endpoint: String::new(),
                pending: Value::Null,
            });
        }
        let t = self
            .extras
            .peers
            .transport
            .as_mut()
            .ok_or(VaultError::InvalidData)?;
        if op == "peer-transport-configure" {
            let gateway =
                url::Url::parse(text(request, "gateway")?).map_err(|_| VaultError::InvalidData)?;
            let endpoint =
                url::Url::parse(text(request, "endpoint")?).map_err(|_| VaultError::InvalidData)?;
            let credential = &request["credential"];
            let local_test = credential["testOnlyLoopback"] == true
                && [&gateway, &endpoint].iter().all(|url| {
                    matches!(url.host_str(), Some("localhost" | "127.0.0.1"))
                        && ["ws", "wss"].contains(&url.scheme())
                });
            for url in [&gateway, &endpoint] {
                if (url.scheme() != "wss" && !local_test)
                    || url.host_str().is_none()
                    || !url.username().is_empty()
                    || url.password().is_some()
                    || url.query().is_some()
                    || url.fragment().is_some()
                {
                    return Err(VaultError::InvalidData);
                }
            }
            let identity = &credential["identity"];
            if identity["app"] != "passwordvault"
                || identity["device"] != t.device
                || identity["public_key"]
                    != hex::encode(SecretKey::from(t.secret).public_key().as_bytes())
            {
                return Err(VaultError::Authentication);
            }
            t.endpoint = endpoint.to_string();
            t.group = text(identity, "group")?.into();
            t.token = text(credential, "token")?.into();
            t.gateway = gateway.to_string();
        }
        if op == "peer-transport-pending" {
            t.pending = request["value"].clone();
            return Ok(json!({"ok":true}));
        }
        if [
            "peer-transport-status",
            "peer-transport-identity",
            "peer-transport-configure",
        ]
        .contains(&op)
        {
            return Ok(
                json!({"device":t.device,"publicKey":hex::encode(SecretKey::from(t.secret).public_key().as_bytes()),"group":t.group,"gateway":t.gateway,"endpoint":t.endpoint,"token":t.token,"pending":t.pending}),
            );
        }
        let peer = text(request, "peer")?;
        let kind = "message";
        let message_id = text(request, "id")?;
        let opening = op == "peer-transport-open";
        if !opening && op != "peer-transport-seal" {
            return Err(VaultError::Unsupported);
        }
        let expected_key = text(request, "publicKey")?;
        let mut trusted = false;
        for l in self.extras.peers.libraries.values() {
            if l.replica
                .members()
                .ok()
                .and_then(|m| m.get(peer))
                .is_some_and(|m| m.transport_key == expected_key)
            {
                trusted = true;
            }
        }
        if t.pending["device"] == peer && t.pending["transportKey"] == expected_key {
            trusted = true;
        }
        if !trusted {
            return Err(VaultError::Authentication);
        }
        let public: [u8; 32] = hex::decode(expected_key)
            .map_err(|_| VaultError::InvalidData)?
            .try_into()
            .map_err(|_| VaultError::InvalidData)?;
        let crypt = SalsaBox::new(&PublicKey::from(public), &SecretKey::from(t.secret));
        let context = if opening {
            json!([
                1,
                "passwordvault",
                t.group,
                peer,
                t.device,
                kind,
                message_id
            ])
        } else {
            json!([
                1,
                "passwordvault",
                t.group,
                t.device,
                peer,
                kind,
                message_id
            ])
        };
        if opening {
            let raw = STANDARD
                .decode(text(request, "body")?)
                .map_err(|_| VaultError::InvalidData)?;
            if raw.len() < 40 {
                return Err(VaultError::InvalidData);
            }
            let plain = Zeroizing::new(
                crypt
                    .decrypt(raw[..24].into(), &raw[24..])
                    .map_err(|_| VaultError::Authentication)?,
            );
            let envelope: Value =
                serde_json::from_slice(&plain).map_err(|_| VaultError::InvalidData)?;
            if envelope["context"] != context {
                return Err(VaultError::Authentication);
            }
            Ok(envelope["value"].clone())
        } else {
            let nonce = SalsaBox::generate_nonce(&mut OsRng);
            let plain = Zeroizing::new(
                serde_json::to_vec(&json!({"context":context,"value":request["value"]}))
                    .map_err(|_| VaultError::InvalidData)?,
            );
            let cipher = crypt
                .encrypt(&nonce, plain.as_slice())
                .map_err(|_| VaultError::Authentication)?;
            let mut data = nonce.to_vec();
            data.extend(cipher);
            Ok(json!({"body":STANDARD.encode(data)}))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wasm_adapter_rejects_cross_library_attachment_reference_without_payload() {
        let root = Zeroizing::new(random_bytes::<32>());
        let mut victim = BrowserVault {
            header: Header::create("synthetic fixture", &root, new_id()).unwrap(),
            root,
            document: Document::default(),
            extras: BrowserExtras::default(),
            recovery: None,
            files: Arc::new(HashMap::new()),
        };
        victim
            .document
            .upsert(json!({"id":"collision","type":"secureNote","title":"Private note"}))
            .unwrap();
        let meta=victim.extra_command(&json!({"op":"attachment-add","noteId":"collision","name":"private.txt","mime":"text/plain","data":STANDARD.encode(b"PRIVATE_CONTENT")})).unwrap();
        let rich = json!({"id":"collision","type":"secureNote","title":"Private note","noteFormat":"rich-v1","noteDocument":{"type":"doc","content":[{"type":"vaultAttachment","attrs":{"attachmentId":meta["id"]}}]}});
        victim.document.upsert(rich.clone()).unwrap();
        let identity = victim
            .peer_command(&json!({"op":"relay-peer-identity","device":"victim","personal":false}))
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
        victim.peer_command(&json!({"op":"relay-peer-join","library":identity["library"],"expectedLibrary":attacker.library,"founderKey":attacker.public_key(),"envelope":{"packet":attacker.export("victim").unwrap(),"files":[]}})).unwrap();
        let mut stolen = rich;
        stolen["title"] = json!("Family reference");
        attacker.write("item:collision".into(), stolen).unwrap();
        let packet = attacker.export("victim").unwrap();
        assert!(victim.peer_command(&json!({"op":"relay-peer-receive","library":attacker.library,"envelope":{"packet":packet,"files":[]}})).is_err());
        assert!(victim.peer_command(&json!({"op":"relay-peer-receive","library":attacker.library,"envelope":{"packet":packet,"files":[{"meta":meta,"data":STANDARD.encode(b"FORGED_CONTENT!")}]}})).is_err());
        assert_eq!(victim.document.items[0]["title"], "Private note");
        victim.peer_command(&json!({"op":"relay-peer-receive","library":attacker.library,"envelope":{"packet":packet,"files":[{"meta":meta,"data":STANDARD.encode(b"PRIVATE_CONTENT")}]}})).unwrap();
        assert_eq!(victim.document.items[0]["title"], "Private note");
    }
}
