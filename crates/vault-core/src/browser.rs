//! The browser persists only an authenticated encrypted bundle. Password KDFs run
//! in a disposable Worker; the live vault Worker never retains its 64 MiB arena.
use crate::recovery::RecoveryEnvelope;
use crate::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use wasm_bindgen::prelude::*;
use zeroize::{Zeroize, Zeroizing};
mod drafts;
mod extra;
mod passkeys;
mod peer;
use extra::BrowserExtras;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Portable {
    header: Header,
    payload: Sealed,
    #[serde(default)]
    extras: Option<Sealed>,
    #[serde(default)]
    recovery: Option<RecoveryEnvelope>,
    #[serde(default)]
    files: HashMap<String, Sealed>,
}

#[derive(Serialize)]
struct PortableRef<'a> {
    header: &'a Header,
    payload: Sealed,
    #[serde(skip_serializing_if = "Option::is_none")]
    extras: Option<Sealed>,
    #[serde(skip_serializing_if = "Option::is_none")]
    recovery: &'a Option<RecoveryEnvelope>,
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    files: &'a HashMap<String, Sealed>,
}

fn js_error(error: VaultError) -> JsValue {
    JsValue::from_str(&error.to_string())
}
fn parse_bundle(input: &str) -> Result<Portable> {
    if input.len() > MAX_INPUT * 2 {
        return Err(VaultError::InvalidData);
    }
    let bundle: Portable = serde_json::from_str(input).map_err(|_| VaultError::InvalidData)?;
    if bundle.header.format != "PasswordVault" || bundle.header.version != 2 {
        return Err(VaultError::Unsupported);
    }
    Ok(bundle)
}

#[wasm_bindgen(js_name = bootstrapCreate)]
pub fn bootstrap_create(password: String) -> std::result::Result<String, JsValue> {
    let password = Zeroizing::new(password);
    let root = Zeroizing::new(random_bytes::<32>());
    let header = Header::create(&password, &root, new_id()).map_err(js_error)?;
    let engine = BrowserVault {
        header,
        root,
        document: Document::default(),
        extras: BrowserExtras::default(),
        recovery: None,
        files: Arc::new(HashMap::new()),
    };
    let storage = engine.snapshot()?;
    Ok(json!({"storage":storage,"key":STANDARD.encode(engine.root.as_ref())}).to_string())
}

#[wasm_bindgen(js_name = bootstrapUnlock)]
pub fn bootstrap_unlock(
    storage: String,
    password: String,
) -> std::result::Result<Vec<u8>, JsValue> {
    let password = Zeroizing::new(password);
    let bundle = parse_bundle(&storage).map_err(js_error)?;
    let root = bundle.header.unlock(&password).map_err(js_error)?;
    Ok(root.to_vec())
}

#[wasm_bindgen]
pub struct BrowserVault {
    header: Header,
    root: Secret,
    document: Document,
    extras: BrowserExtras,
    recovery: Option<RecoveryEnvelope>,
    files: Arc<HashMap<String, Sealed>>,
}

#[wasm_bindgen]
impl BrowserVault {
    #[wasm_bindgen(constructor)]
    pub fn new(storage: String, key: Vec<u8>) -> std::result::Result<BrowserVault, JsValue> {
        let key = Zeroizing::new(key);
        let root = Zeroizing::new(
            key.as_slice()
                .try_into()
                .map_err(|_| js_error(VaultError::Authentication))?,
        );
        let bundle = parse_bundle(&storage).map_err(js_error)?;
        let data = unseal(
            &subkey(&root, b"document"),
            &bundle.payload,
            bundle.header.vault_id.as_bytes(),
        )
        .map_err(js_error)?;
        let document = Document::parse(&data).map_err(js_error)?;
        let extras = extra::decode_extras(&root, bundle.extras.as_ref(), &bundle.header.vault_id)
            .map_err(js_error)?;
        let engine = Self {
            header: bundle.header,
            root,
            document,
            extras,
            recovery: bundle.recovery,
            files: Arc::new(bundle.files),
        };
        engine.validate_extras().map_err(js_error)?;
        Ok(engine)
    }

    pub fn snapshot(&self) -> std::result::Result<String, JsValue> {
        let data = Zeroizing::new(
            serde_json::to_vec(&self.document).map_err(|_| js_error(VaultError::InvalidData))?,
        );
        let payload = seal(
            &subkey(&self.root, b"document"),
            &data,
            self.header.vault_id.as_bytes(),
        )
        .map_err(js_error)?;
        let extras = if self.extras.enabled
            || !self.extras.attachments.is_empty()
            || !self.extras.peers.libraries.is_empty()
            || self.extras.peers.transport.is_some()
            || self.extras.draft.is_some()
        {
            let bytes = Zeroizing::new(
                serde_json::to_vec(&self.extras).map_err(|_| js_error(VaultError::InvalidData))?,
            );
            Some(
                seal(
                    &subkey(&self.root, b"browser-extras-v1"),
                    &bytes,
                    self.header.vault_id.as_bytes(),
                )
                .map_err(js_error)?,
            )
        } else {
            None
        };
        let serialized = serde_json::to_string(&PortableRef {
            header: &self.header,
            payload,
            extras,
            recovery: &self.recovery,
            files: &self.files,
        })
        .map_err(|_| js_error(VaultError::InvalidData))?;
        if serialized.len() > MAX_INPUT * 2 {
            return Err(js_error(VaultError::InvalidData));
        }
        Ok(serialized)
    }

    #[wasm_bindgen(js_name = restoreCheckpoint)]
    pub fn restore_checkpoint(&mut self, storage: String) -> std::result::Result<(), JsValue> {
        let mut candidate = Self::new(storage, self.root.to_vec())?;
        if candidate.header.vault_id != self.header.vault_id {
            return Err(js_error(VaultError::Authentication));
        }
        std::mem::swap(self, &mut candidate);
        Ok(())
    }

    pub fn command(&mut self, input: String) -> std::result::Result<String, JsValue> {
        let input = Zeroizing::new(input);
        if input.len() > MAX_INPUT * 2 {
            return Err(js_error(VaultError::InvalidData));
        }
        let mut request: Value =
            serde_json::from_str(&input).map_err(|_| js_error(VaultError::InvalidData))?;
        let read_only = [
            "list",
            "totp",
            "parse-totp",
            "generate",
            "audit",
            "matches",
            "fill",
            "export",
            "export-plain",
            "wallet",
            "share-options",
            "share-seal",
            "structured-list",
            "structured-fill",
            "history-status",
            "draft-read",
            "relay-peer-status",
            "relay-peer-list",
            "relay-peer-export",
            "peer-transport-status",
            "peer-transport-open",
            "peer-transport-seal",
            "history-list",
            "recovery-status",
            "recovery-generate",
            "recovery-export",
            "attachment-read",
            "passkey-index",
            "passkey-matches",
            "passkey-assert",
            "import-preview",
            "security-audit",
            "breach-request",
            "breach-response",
            "otp-matches",
            "otp-fill",
        ]
        .contains(&request["op"].as_str().unwrap_or(""));
        let checkpoint = (!read_only).then(|| {
            (
                self.document.clone(),
                self.header.clone(),
                self.extras.clone(),
                self.recovery.clone(),
                Arc::clone(&self.files),
            )
        });
        let mut result = self.execute(&request);
        if result.is_ok() && !read_only {
            if let Some((document, _, _, _, _)) = &checkpoint {
                if let Err(error) = self
                    .capture_peers(document)
                    .and_then(|_| self.capture_history(document))
                {
                    result = Err(error);
                }
            }
        }
        if result.is_err() {
            if let Some((document, header, extras, recovery, files)) = checkpoint {
                self.document = document;
                self.header = header;
                self.extras = extras;
                self.recovery = recovery;
                self.files = files;
            }
        }
        if result.is_ok() && request["op"] == "save" {
            result = Ok(self.peer_save_result(request["item"]["id"].as_str().unwrap_or("")));
        }
        wipe(&mut request);
        serde_json::to_string(&result.map_err(js_error)?)
            .map_err(|_| js_error(VaultError::InvalidData))
    }
}

impl BrowserVault {
    fn execute(&mut self, request: &Value) -> Result<Value> {
        let text = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        let op = text("op")?;
        guard_device_sync(self.document.format_version, op)?;
        if self.extras.draft.is_some()
            && [
                "export",
                "recovery-export",
                "import",
                "import-commit",
                "remove",
                "share-seal",
                "relay-peer-switch",
                "relay-peer-rekey",
            ]
            .contains(&op)
        {
            return Err(VaultError::Unsupported);
        }
        if op.starts_with("relay-peer-") || op.starts_with("peer-transport-") {
            return self.peer_command(request);
        }
        if op.starts_with("draft-") {
            return self.draft_command(request);
        }
        if op.starts_with("history-")
            && self.document.settings["activePeerLibrary"]
                .as_str()
                .is_some_and(|s| !s.is_empty())
        {
            let mut scoped = request.clone();
            scoped["library"] = self.document.settings["activePeerLibrary"].clone();
            scoped["op"] = json!(op.replacen("history-", "relay-peer-history-", 1));
            return self.peer_command(&scoped);
        }
        if op.starts_with("passkey-") {
            return self.passkey_command(request);
        }
        if op.starts_with("history-")
            || op.starts_with("recovery-")
            || op.starts_with("attachment-")
        {
            return self.extra_command(request);
        }
        if self.document.format_version >= 3
            && ["export-plain", "sync-request", "sync-respond", "sync-apply"].contains(&text("op")?)
        {
            return Err(VaultError::Unsupported);
        }
        match text("op")? {
            "list" => Ok(json!(self.peer_editable_document())),
            "structured-list" => Ok(structured_items(&self.document.items)),
            "structured-fill" => fill_structured(
                &self.document.items,
                text("origin")?,
                text("id")?,
                request["includeSecurityCode"] == true,
            ),
            "import-preview" | "import-commit" => {
                let data = Zeroizing::new(
                    STANDARD
                        .decode(text("data")?)
                        .map_err(|_| VaultError::InvalidData)?,
                );
                let mapping =
                    serde_json::from_value(request.get("mapping").cloned().unwrap_or(json!({})))
                        .map_err(|_| VaultError::InvalidData)?;
                let preview = preview_import(text("format")?, &data, &mapping, &self.document)?;
                if op == "import-preview" {
                    serde_json::to_value(preview).map_err(|_| VaultError::InvalidData)
                } else {
                    let choices = serde_json::from_value(
                        request.get("choices").cloned().unwrap_or(json!({})),
                    )
                    .map_err(|_| VaultError::InvalidData)?;
                    apply_import(&mut self.document, preview, &choices)
                }
            }
            "security-audit" => security_audit(
                &self.document,
                self.document.settings.get("securityCatalog"),
            ),
            "security-ignore" => {
                set_security_ignored(
                    &mut self.document,
                    text("key")?,
                    request["ignored"]
                        .as_bool()
                        .ok_or(VaultError::InvalidData)?,
                )?;
                Ok(json!({"ok":true}))
            }
            "security-catalog" => {
                validate_security_catalog(&request["catalog"])?;
                self.document.settings["securityCatalog"] = request["catalog"].clone();
                Ok(json!({"ok":true}))
            }
            "breach-request" => Ok(breach_request(text("password")?)),
            "breach-response" => {
                Ok(json!({"count":breach_response(text("suffix")?,text("response")?)?}))
            }
            "update-login" => update_login(
                &mut self.document,
                text("origin")?,
                text("id")?,
                request["accountId"].as_str(),
                text("username")?,
                text("password")?,
                text("time")?,
            ),
            "otp-matches" => matching_otps(&self.document.items, text("origin")?),
            "otp-fill" => fill_otp(
                &self.document.items,
                text("origin")?,
                text("id")?,
                request["time"].as_u64().ok_or(VaultError::InvalidData)?,
            ),
            "share-options" => {
                let item = self
                    .document
                    .items
                    .iter()
                    .find(|i| i["id"] == text("id").unwrap_or("") && i["isDeleted"] != true)
                    .ok_or(VaultError::InvalidData)?;
                let fields: Vec<_> = SHARE_FIELDS
                    .iter()
                    .filter(|key| item.get(**key).is_some())
                    .collect();
                let mut used = std::collections::HashSet::new();
                crate::archive::item_attachment_refs(item, &mut used)?;
                let attachments: Vec<_> = self
                    .extras
                    .attachments
                    .iter()
                    .filter(|m| m.note_id == item["id"] && used.contains(&m.id))
                    .collect();
                Ok(json!({"fields":fields,"attachments":attachments}))
            }
            "share-seal" => {
                let item = self
                    .document
                    .items
                    .iter()
                    .find(|i| i["id"] == text("id").unwrap_or("") && i["isDeleted"] != true)
                    .ok_or(VaultError::InvalidData)?;
                let fields: Vec<String> = serde_json::from_value(request["fields"].clone())
                    .map_err(|_| VaultError::InvalidData)?;
                let ids: Vec<String> = serde_json::from_value(
                    request.get("attachmentIds").cloned().unwrap_or(json!([])),
                )
                .map_err(|_| VaultError::InvalidData)?;
                let mut used = std::collections::HashSet::new();
                crate::archive::item_attachment_refs(item, &mut used)?;
                let mut attachments = vec![];
                for id in ids {
                    let meta = self
                        .extras
                        .attachments
                        .iter()
                        .find(|m| m.id == id && m.note_id == item["id"] && used.contains(&id))
                        .ok_or(VaultError::InvalidData)?;
                    attachments.push(share_attachment(
                        meta.name.clone(),
                        meta.mime.clone(),
                        &self.read_file(meta)?,
                    ));
                }
                seal_share(item, &fields, &attachments)
            }
            "category-add" => Ok(json!({"name":self.document.add_note_category(text("name")?)?})),
            "category-remove" => Ok(
                json!({"updated":self.document.remove_note_category(text("name")?,text("time")?)?}),
            ),
            "save" => {
                let mut item = self.peer_prepare_save(&request["item"])?;
                preserve_passkeys_for_edit(&self.document, &mut item)?;
                if request["richNotes"] != true
                    && (request["item"]["noteFormat"] == "rich-v1"
                        || self.document.items.iter().any(|n| {
                            n["id"] == request["item"]["id"] && n["noteFormat"] == "rich-v1"
                        }))
                {
                    return Err(VaultError::Unsupported);
                }
                authorize_item_write(&self.document, &request["item"])?;
                if let Some(old) = self
                    .document
                    .items
                    .iter()
                    .find(|v| v["id"] == request["item"]["id"])
                {
                    authorize_item_write(&self.document, old)?;
                }
                self.document.upsert(item)?;
                self.validate_extras()?;
                Ok(json!({"ok":true}))
            }
            "remove" => {
                let id = text("id")?;
                if let Some(item) = self.document.items.iter().find(|v| v["id"] == id) {
                    authorize_item_write(&self.document, item)?;
                    if item["sharedVaultId"]
                        .as_str()
                        .is_some_and(|s| !s.is_empty())
                    {
                        return Err(VaultError::Unsupported);
                    }
                }
                self.document.items.retain(|v| v["id"] != id);
                self.forget_entry_extras(id);
                Ok(json!({"ok":true}))
            }
            "settings" => {
                update_settings(&mut self.document, &request["settings"])?;
                Ok(json!({"ok":true}))
            }
            "export" => {
                if self.document.format_version >= 3 {
                    return Ok(json!({"content":self.full_archive(text("password")?)?}));
                }
                let bytes = Zeroizing::new(
                    serde_json::to_vec(&self.document).map_err(|_| VaultError::InvalidData)?,
                );
                Ok(json!({"content":encrypt_backup(&bytes,text("password")?)?}))
            }
            "export-plain" => Ok(
                json!({"content":if request["kind"]=="csv"{export_csv(&self.document)?}else{serde_json::to_string(&self.document).map_err(|_|VaultError::InvalidData)?}}),
            ),
            "import" => {
                if text("content")?.contains("\"PasswordVaultArchive\"") {
                    let count = self.import_full_archive(
                        text("content")?,
                        request["password"].as_str().unwrap_or(""),
                    )?;
                    return Ok(json!({"imported":count}));
                }
                let incoming = import_document(
                    text("content")?,
                    request["password"].as_str().unwrap_or(""),
                    request["kind"].as_str().unwrap_or("json"),
                )?;
                if incoming.format_version >= 3 {
                    return Err(VaultError::Unsupported);
                }
                let mut next = self.document.clone();
                let count = next.merge(incoming)?;
                self.document = next;
                Ok(json!({"imported":count}))
            }
            "change-password" => {
                let check = self.header.unlock(text("currentPassword")?)?;
                if check.as_ref() != self.root.as_ref() {
                    return Err(VaultError::Authentication);
                }
                self.header = Header::create(
                    text("newPassword")?,
                    &self.root,
                    self.header.vault_id.clone(),
                )?;
                Ok(json!({"ok":true}))
            }
            "totp" => Ok(
                json!({"code":totp(text("secret")?,request["period"].as_u64().unwrap_or(30),request["time"].as_u64().ok_or(VaultError::InvalidData)?)?}),
            ),
            "parse-totp" => parse_totp_uri(text("uri")?),
            "wallet" => wallet(request),
            "generate" => Ok(
                json!({"password":generate_password(request["length"].as_u64().unwrap_or(20)as usize,request["upper"]!=false,request["lower"]!=false,request["digits"]!=false,request["symbols"]!=false)?}),
            ),
            "audit" => Ok(audit(&self.document.items)),
            "matches" => matching_accounts(&self.document.items, text("origin")?),
            "fill" => fill_account(
                &self.document.items,
                text("origin")?,
                text("id")?,
                request["accountId"].as_str(),
            ),
            "identity" => Ok(json!({"publicKey":sharing_identity(&mut self.document)?})),
            "create-shared" => create_shared(&mut self.document, text("name")?, text("time")?),
            "add-member" => add_member(
                &mut self.document,
                text("vaultId")?,
                text("publicKey")?,
                request["role"].as_str().unwrap_or("viewer"),
                request["name"].as_str().unwrap_or(""),
            ),
            "remove-member" => {
                remove_member(&mut self.document, text("vaultId")?, text("publicKey")?)
            }
            "sync-request" => {
                create_sync_request(&mut self.document, text("peerKey")?, text("vaultId")?)
            }
            "sync-respond" => respond_sync(&mut self.document, &request["packet"]),
            "sync-apply" => apply_sync(
                &mut self.document,
                &request["packet"],
                text("peerKey")?,
                text("vaultId")?,
            ),
            _ => Err(VaultError::Unsupported),
        }
    }
}

fn wipe(value: &mut Value) {
    match value {
        Value::String(s) => s.zeroize(),
        Value::Array(a) => a.iter_mut().for_each(wipe),
        Value::Object(o) => o.values_mut().for_each(wipe),
        _ => {}
    }
}

impl Drop for BrowserVault {
    fn drop(&mut self) {
        for item in &mut self.document.items {
            wipe(item);
        }
        wipe(&mut self.document.settings);
        for revision in &mut self.extras.history {
            wipe(&mut revision.item);
        }
    }
}
