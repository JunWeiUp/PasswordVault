//! The browser persists only an authenticated encrypted bundle. Password KDFs run
//! in a disposable Worker; the live vault Worker never retains its 64 MiB arena.
use crate::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use wasm_bindgen::prelude::*;
use zeroize::{Zeroize, Zeroizing};

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Portable {
    header: Header,
    payload: Sealed,
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
        Ok(Self {
            header: bundle.header,
            root,
            document,
        })
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
        serde_json::to_string(&Portable {
            header: self.header.clone(),
            payload,
        })
        .map_err(|_| js_error(VaultError::InvalidData))
    }

    #[wasm_bindgen(js_name = restoreCheckpoint)]
    pub fn restore_checkpoint(&mut self, storage: String) -> std::result::Result<(), JsValue> {
        let bundle = parse_bundle(&storage).map_err(js_error)?;
        if bundle.header.vault_id != self.header.vault_id {
            return Err(js_error(VaultError::Authentication));
        }
        let bytes = unseal(
            &subkey(&self.root, b"document"),
            &bundle.payload,
            self.header.vault_id.as_bytes(),
        )
        .map_err(js_error)?;
        self.document = Document::parse(&bytes).map_err(js_error)?;
        self.header = bundle.header;
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
        ]
        .contains(&request["op"].as_str().unwrap_or(""));
        let checkpoint = (!read_only).then(|| (self.document.clone(), self.header.clone()));
        let result = self.execute(&request);
        if result.is_err() {
            if let Some((document, header)) = checkpoint {
                self.document = document;
                self.header = header;
            }
        }
        wipe(&mut request);
        serde_json::to_string(&result.map_err(js_error)?)
            .map_err(|_| js_error(VaultError::InvalidData))
    }
}

impl BrowserVault {
    fn execute(&mut self, request: &Value) -> Result<Value> {
        let text = |key: &str| request[key].as_str().ok_or(VaultError::InvalidData);
        match text("op")? {
            "list" => Ok(json!(self.document)),
            "category-add" => Ok(json!({"name":self.document.add_note_category(text("name")?)?})),
            "category-remove" => Ok(
                json!({"updated":self.document.remove_note_category(text("name")?,text("time")?)?}),
            ),
            "save" => {
                authorize_item_write(&self.document, &request["item"])?;
                if let Some(old) = self
                    .document
                    .items
                    .iter()
                    .find(|v| v["id"] == request["item"]["id"])
                {
                    authorize_item_write(&self.document, old)?;
                }
                self.document.upsert(request["item"].clone())?;
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
                Ok(json!({"ok":true}))
            }
            "settings" => {
                update_settings(&mut self.document, &request["settings"])?;
                Ok(json!({"ok":true}))
            }
            "export" => {
                let bytes = Zeroizing::new(
                    serde_json::to_vec(&self.document).map_err(|_| VaultError::InvalidData)?,
                );
                Ok(json!({"content":encrypt_backup(&bytes,text("password")?)?}))
            }
            "export-plain" => Ok(
                json!({"content":if request["kind"]=="csv"{export_csv(&self.document)?}else{serde_json::to_string(&self.document).map_err(|_|VaultError::InvalidData)?}}),
            ),
            "import" => {
                let incoming = import_document(
                    text("content")?,
                    request["password"].as_str().unwrap_or(""),
                    request["kind"].as_str().unwrap_or("json"),
                )?;
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
    }
}
