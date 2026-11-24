//! UniFFI surface of the relay transport for Android and iOS (desktop calls `connection`,
//! `files` and `Journal` directly).
use super::{connection::Connection, files, http::Http, journal::Journal};
use crate::relay_protocol::{groups::Groups, text, unhex, BoxPublicKey, BoxSecretKey, Identity};
use serde_json::{json, Value};
use std::{path::Path, sync::Arc, time::Duration};

/// A relay failure carrying its code (`RelayConnection`, `RelayHttp401`, `InvalidData`, ...);
/// pass the code to `relay-protocol-retry` to decide whether to reconnect.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RelayError {
    #[error("{code}")]
    Failed { code: String },
}

impl From<String> for RelayError {
    fn from(code: String) -> Self {
        RelayError::Failed { code }
    }
}
impl From<crate::relay_protocol::ProtocolError> for RelayError {
    fn from(e: crate::relay_protocol::ProtocolError) -> Self {
        RelayError::Failed { code: e.0.into() }
    }
}

type R<T> = std::result::Result<T, RelayError>;

fn parse(raw: &str) -> R<Value> {
    serde_json::from_str(raw).map_err(|_| "InvalidData".to_owned().into())
}

/// `{app, group, device, secret: hex, trusted: {device: publicKeyHex}}`
fn identity(v: &Value) -> R<Identity> {
    let secret = BoxSecretKey::from_slice(&unhex(text(v, "secret")?)?)
        .ok_or_else(|| RelayError::from("InvalidData".to_owned()))?;
    let mut trusted = std::collections::BTreeMap::new();
    for (device, key) in v["trusted"].as_object().into_iter().flatten() {
        let key = key
            .as_str()
            .ok_or_else(|| RelayError::from("InvalidData".to_owned()))?;
        let key = BoxPublicKey::from_slice(&unhex(key)?)
            .ok_or_else(|| RelayError::from("InvalidData".to_owned()))?;
        trusted.insert(device.clone(), key);
    }
    Ok(Identity {
        app: text(v, "app")?.into(),
        group: text(v, "group")?.into(),
        device: text(v, "device")?.into(),
        secret,
        trusted: trusted.into_iter().collect(),
    })
}

/// One WSS connection. Blocking: call from a background thread/executor.
#[derive(uniffi::Object)]
pub struct RelayConnection {
    inner: Connection,
}

#[uniffi::export]
impl RelayConnection {
    /// `{url, token, password?, allowLocal?, identity, journal?: directory}`
    #[uniffi::constructor]
    pub fn connect(options: String) -> R<Arc<Self>> {
        let o = parse(&options)?;
        let journal = match o["journal"].as_str() {
            Some(dir) => Some(Journal::open(Path::new(dir)).map_err(super::code)?),
            None => None,
        };
        let inner = Connection::connect(
            text(&o, "url")?,
            text(&o, "token")?,
            o["password"].as_str().filter(|p| !p.is_empty()),
            identity(&o["identity"])?,
            o["allowLocal"] == true,
            journal,
        )?;
        Ok(Arc::new(Self { inner }))
    }

    /// Next `message` (with base64 `data`), `peer.up`, `peer.down`, `group.changed` or
    /// `undecryptable` (`{from, id, offline, trusted}`: reconnect if the sender is in the current
    /// roster, else `acknowledge` to drop it) event as JSON; `None` after `timeout_ms`; an
    /// error once the connection is closed.
    pub fn next_event(&self, timeout_ms: u64) -> R<Option<String>> {
        Ok(self
            .inner
            .next_event(Duration::from_millis(timeout_ms))?
            .map(|v| v.to_string()))
    }

    pub fn message(
        &self,
        to: String,
        data: Vec<u8>,
        offline: bool,
        id: Option<String>,
    ) -> R<String> {
        Ok(self
            .inner
            .message(&to, &data, offline, id.as_deref())?
            .to_string())
    }

    pub fn acknowledge(&self, from: String, id: String, offline: bool) -> R<String> {
        Ok(self.inner.acknowledge(&from, &id, offline)?.to_string())
    }

    /// `{type:"peers", devices:[{app, group, device}]}`
    pub fn peers(&self) -> R<String> {
        Ok(self.inner.peers()?.to_string())
    }

    /// Closes the socket (named `disconnect`: `close` is taken by Kotlin's AutoCloseable).
    pub fn disconnect(&self) {
        self.inner.close()
    }

    pub fn is_closed(&self) -> bool {
        self.inner.is_closed()
    }
}

/// Encrypted relay file transfers (`passwordvault.sync.v1`). Blocking.
#[derive(uniffi::Object)]
pub struct RelayFileClient {
    url: String,
    token: String,
    password: Option<String>,
    local: bool,
    identity: Identity,
}

impl RelayFileClient {
    fn files(&self) -> R<files::Files<'static>> {
        static NO_CHECK: fn() -> super::Result<()> = || Ok(());
        Ok(files::Files::new(
            &self.url,
            &self.token,
            self.password.as_deref(),
            self.local,
            &NO_CHECK,
        )?)
    }
}

#[uniffi::export]
impl RelayFileClient {
    /// Same options as [`RelayConnection::connect`] (the `journal` field is ignored).
    #[uniffi::constructor]
    pub fn new(options: String) -> R<Arc<Self>> {
        let o = parse(&options)?;
        let client = Self {
            url: text(&o, "url")?.into(),
            token: text(&o, "token")?.into(),
            password: o["password"]
                .as_str()
                .filter(|p| !p.is_empty())
                .map(str::to_owned),
            local: o["allowLocal"] == true,
            identity: identity(&o["identity"])?,
        };
        client.files()?;
        Ok(Arc::new(client))
    }

    /// Encrypts `data` for `to` and uploads it (resumable on retry with the same file only).
    pub fn send(&self, to: String, data: Vec<u8>) -> R<()> {
        let (descriptor, cipher) = files::prepare(&self.identity, &to, &data)?;
        Ok(self.files()?.upload(&descriptor, &cipher)?)
    }

    /// JSON array of pending file descriptors (`{id, from, size, ...}`).
    pub fn inbox(&self) -> R<String> {
        Ok(Value::Array(self.files()?.inbox()?).to_string())
    }

    /// Downloads, verifies and decrypts one inbox entry; returns the plaintext bytes.
    pub fn receive(&self, descriptor: String) -> R<Vec<u8>> {
        let d = parse(&descriptor)?;
        let from = text(&d, "from")?.to_owned();
        let files = self.files()?;
        let cipher = files.download(&d)?;
        Ok(files::decrypt(&self.identity, &from, &d, &cipher)?.to_vec())
    }

    pub fn acknowledge(&self, id: String) -> R<()> {
        Ok(self.files()?.acknowledge(&id)?)
    }
}

/// Durable storage for group drafts: `save` must persist the config before the call returns.
#[uniffi::export(with_foreign)]
pub trait RelayGroupStore: Send + Sync {
    fn save(&self, config: String) -> std::result::Result<(), RelayError>;
}

/// Runs one group operation with HTTPS transport and returns `{config, result}`.
/// Request: `{config, allowLocal?, op, ...}` with ops `create{name, deviceName}`,
/// `invite{mode}`, `publish`, `resolve{link, typed?, override?}`, `join{invitation, name}`,
/// `finish-join`, `pending`, `code`, `approve{code, manager}`, `cancel`, `rename{device, name}`,
/// `remove{device}`, `exit{disband}`, `check-exit{disband}` (offline), `refresh`, `member{name}`.
#[uniffi::export]
pub fn relay_groups(request: String, store: Arc<dyn RelayGroupStore>) -> R<String> {
    let r = parse(&request)?;
    let local = r["allowLocal"] == true;
    let mut save = |config: &Value| {
        store
            .save(config.to_string())
            .map_err(|RelayError::Failed { code }| code)
    };
    let mut groups = Groups {
        config: r["config"].clone(),
        api: Http { local },
        save: &mut save,
        local,
    };
    let s = |key: &str| text(&r, key).map(str::to_owned);
    let result: Value = match text(&r, "op")? {
        "create" => groups
            .create(&s("name")?, &s("deviceName")?)
            .map(|_| json!(true))?,
        "invite" => json!(groups.invite(&s("mode")?)?),
        "publish" => json!(groups.publish()?),
        "resolve" => {
            groups.resolve_with(&s("link")?, r["typed"].as_str(), r["override"].as_str())?
        }
        "join" => json!(groups.join(r["invitation"].clone(), &s("name")?)?),
        "finish-join" => json!(groups.finish_join()?),
        "pending" => groups.pending().map(|_| json!(true))?,
        "code" => json!(groups.code()?),
        "approve" => groups
            .approve(&s("code")?, r["manager"] == true)
            .map(|_| json!(true))?,
        "cancel" => groups.cancel().map(|_| json!(true))?,
        "rename" => groups
            .rename(&s("device")?, &s("name")?)
            .map(|_| json!(true))?,
        "remove" => groups.remove(&s("device")?).map(|_| json!(true))?,
        "exit" => groups.exit(r["disband"] == true).map(|_| json!(true))?,
        "check-exit" => groups
            .check_exit(r["disband"] == true)
            .map(|_| json!(true))?,
        "refresh" => groups.refresh()?,
        "member" => groups.member(&s("name")?)?,
        _ => return Err("InvalidData".to_owned().into()),
    };
    let config = std::mem::take(&mut groups.config);
    Ok(json!({"config": config, "result": result}).to_string())
}

/// The shared personal-sync session (see `relay_net::mesh_sync`). Blocking: run it on a
/// background thread. Loop: `cycle` (every few seconds), `pump` events in between, and
/// reconnect when `pump` returns a `reconnect` reason or any call fails.
#[derive(uniffi::Object)]
pub struct RelayMeshSync {
    inner: super::mesh_sync::MeshSync,
}

#[uniffi::export]
impl RelayMeshSync {
    /// Same options as [`RelayConnection::connect`]; `journal` (a directory) is required.
    #[uniffi::constructor]
    pub fn connect(vault: Arc<crate::VaultSession>, options: String) -> R<Arc<Self>> {
        let o = parse(&options)?;
        let settings = super::mesh_sync::Settings {
            url: text(&o, "url")?.into(),
            token: text(&o, "token")?.into(),
            password: o["password"]
                .as_str()
                .filter(|p| !p.is_empty())
                .map(str::to_owned),
            local: o["allowLocal"] == true,
            identity: identity(&o["identity"])?,
            journal: text(&o, "journal")?.into(),
        };
        let inner = super::mesh_sync::MeshSync::connect(vault, settings)?;
        Ok(Arc::new(Self { inner }))
    }

    /// One round with the current group config (`relay_groups` config JSON):
    /// `{changed, online, sent, received, peers}`. `force` resends unchanged packets.
    pub fn cycle(&self, groups: String, force: bool) -> R<String> {
        Ok(self.inner.cycle(&parse(&groups)?, force)?.to_string())
    }

    /// Handles events for up to `timeout_ms`: `{changed, reconnect: null|"roster"|"group"}`.
    pub fn pump(&self, timeout_ms: u64) -> R<String> {
        Ok(self
            .inner
            .pump(Duration::from_millis(timeout_ms))?
            .to_string())
    }

    /// Closes the connection (named `disconnect`: `close` is taken by Kotlin's AutoCloseable).
    pub fn disconnect(&self) {
        self.inner.close()
    }

    pub fn is_closed(&self) -> bool {
        self.inner.is_closed()
    }
}
