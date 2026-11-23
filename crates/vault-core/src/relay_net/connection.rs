//! One WSS connection lifetime (common-relay v1 and v2). A reader thread dispatches frames:
//! replies complete the matching request, application events (`message`, `peer.up`,
//! `peer.down`, `group.changed`) queue for [`Connection::next_event`]. Reconnects belong to
//! the caller (see `relay_protocol::policy::retry`); nothing is replayed implicitly.
use super::{invalid, journal::Journal, now, random_hex, Result};
use crate::relay_protocol::{access_password, endpoint, hex, text, Identity, ACCESS_HEADER};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    net::{Shutdown, TcpStream, ToSocketAddrs},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{channel, Receiver, RecvTimeoutError, Sender},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tungstenite::{client::IntoClientRequest, stream::MaybeTlsStream, Message, WebSocket};

const FRAME_LIMIT: usize = 270_336;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(45);
const OFFLINE_TTL: u64 = 86_400;
type Socket = WebSocket<MaybeTlsStream<TcpStream>>;

struct Shared {
    socket: Mutex<Socket>,
    tcp: TcpStream,
    identity: Identity,
    is_v2: bool,
    journal: Option<Journal>,
    pending: Mutex<HashMap<String, Sender<Value>>>,
    events: Sender<Value>,
    closed: AtomicBool,
    error: Mutex<Option<String>>,
}

pub struct Connection {
    shared: Arc<Shared>,
    events: Mutex<Receiver<Value>>,
}

fn io_error(e: tungstenite::Error) -> String {
    match e {
        tungstenite::Error::Io(ref io)
            if matches!(
                io.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ) =>
        {
            "Timeout".into()
        }
        _ => "RelayConnection".into(),
    }
}

fn raw_stream(socket: &mut Socket) -> Result<&mut TcpStream> {
    match socket.get_mut() {
        MaybeTlsStream::Plain(s) => Ok(s),
        MaybeTlsStream::Rustls(s) => Ok(&mut s.sock),
        _ => invalid(),
    }
}

impl Shared {
    fn scope(&self) -> String {
        format!(
            "{}/{}/{}",
            self.identity.app, self.identity.group, self.identity.device
        )
    }

    fn fail(&self, error: String) {
        if self.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        if let Ok(mut slot) = self.error.lock() {
            slot.get_or_insert(error);
        }
        let _ = self.tcp.shutdown(Shutdown::Both);
        if let Ok(mut pending) = self.pending.lock() {
            pending.clear(); // Dropping senders wakes every waiter with an error.
        }
    }

    fn translate_out(&self, event: Value) -> Value {
        if !self.is_v2 {
            return event;
        }
        let space = &self.identity.group;
        match event["type"].as_str() {
            Some("peers") => json!({"type":"presence","space":space,"id":event["id"]}),
            Some("message") => {
                json!({"type":"msg","space":space,"id":event["id"],"to":event["to"],"body":event["body"],"offline":event["offline"].as_bool().unwrap_or(false)})
            }
            Some("ack") => {
                json!({"type":"ack","space":space,"id":event["id"],"from":event["from"]})
            }
            _ => event,
        }
    }

    fn translate_in(&self, v: Value) -> Value {
        if !self.is_v2 {
            return v;
        }
        match v["type"].as_str() {
            Some("presence") => {
                let devices: Vec<Value> = v["peers"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .map(
                        |d| json!({"app":self.identity.app,"group":self.identity.group,"device":d}),
                    )
                    .collect();
                json!({"type":"peers","id":v["id"],"devices":devices})
            }
            Some("msg") => {
                json!({"type":"message","id":v["id"],"from":v["from"],"body":v["body"],"offline":v["offline"].as_bool().unwrap_or(false)})
            }
            Some("ack") => json!({"type":v["event"].as_str().unwrap_or("stored"),"id":v["id"]}),
            Some("group.changed") => {
                json!({"type":"group.changed","revision":v["seq"].as_u64().unwrap_or(0)})
            }
            _ => v,
        }
    }

    fn send(&self, event: Value) -> Result<()> {
        if self.closed.load(Ordering::SeqCst) {
            return Err(self
                .error
                .lock()
                .ok()
                .and_then(|e| e.clone())
                .unwrap_or_else(|| "RelayConnection".into()));
        }
        let text = self.translate_out(event).to_string();
        if text.len() > FRAME_LIMIT {
            return invalid();
        }
        let mut socket = self.socket.lock().map_err(|_| "RelayConnection")?;
        socket.send(Message::Text(text.into())).map_err(io_error)
    }

    fn request(&self, mut event: Value) -> Result<Value> {
        let id = event["id"]
            .as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| random_hex(16));
        event["id"] = json!(id);
        let (tx, rx) = channel();
        {
            let mut pending = self.pending.lock().map_err(|_| "RelayConnection")?;
            if pending.contains_key(&id) {
                return Err("RelayRequestPending".into());
            }
            pending.insert(id.clone(), tx);
        }
        let result = self
            .send(event)
            .and_then(|_| match rx.recv_timeout(REQUEST_TIMEOUT) {
                Ok(reply) if reply["type"] == "error" => {
                    Err(reply["code"].as_str().unwrap_or("RelayError").to_owned())
                }
                Ok(reply) => Ok(reply),
                Err(RecvTimeoutError::Timeout) => Err("Timeout".into()),
                Err(RecvTimeoutError::Disconnected) => Err(self
                    .error
                    .lock()
                    .ok()
                    .and_then(|e| e.clone())
                    .unwrap_or_else(|| "RelayConnection".into())),
            });
        if let Ok(mut pending) = self.pending.lock() {
            pending.remove(&id);
        }
        result
    }

    fn dispatch(&self, raw: Value) -> Result<()> {
        let mut event = self.translate_in(raw);
        let kind = event["type"].as_str().unwrap_or("").to_owned();
        let id = event["id"].as_str().unwrap_or("").to_owned();
        if kind != "message" && kind != "stream.open" {
            if let Some(waiter) = self.pending.lock().map_err(|_| "Storage")?.remove(&id) {
                let _ = waiter.send(event);
                return Ok(());
            }
        }
        if kind == "message" {
            let offline = event["offline"] == true;
            if offline && self.journal.is_none() {
                return Err("PersistentJournalRequired".into());
            }
            let from = text(&event, "from")?.to_owned();
            let value = self
                .identity
                .open(&from, "message", &id, text(&event, "body")?)?;
            let expired = value["expires"].as_u64().is_some_and(|e| e <= now());
            let replay = match &self.journal {
                Some(journal) => journal.contains(&self.scope(), &from, &id)?,
                None => false,
            };
            if expired || replay {
                if offline {
                    self.send(json!({"type":"ack","id":id,"from":from}))?;
                }
                return Ok(());
            }
            event["data"] = value["data"].clone();
            if let Some(o) = event.as_object_mut() {
                o.remove("body");
            }
        }
        if matches!(
            kind.as_str(),
            "message" | "peer.up" | "peer.down" | "group.changed"
        ) {
            let _ = self.events.send(event);
        }
        Ok(())
    }
}

impl Connection {
    /// Connects and waits for the relay's identity greeting. `journal` enables offline messages.
    pub fn connect(
        url: &str,
        token: &str,
        password: Option<&str>,
        identity: Identity,
        local: bool,
        journal: Option<Journal>,
    ) -> Result<Self> {
        let u = endpoint(url, local)?;
        if token.len() < 32 {
            return invalid();
        }
        let is_v2 = u.path() == "/v2/ws";
        let mut req = u
            .as_str()
            .into_client_request()
            .map_err(|_| "InvalidData")?;
        req.headers_mut().insert(
            "Authorization",
            format!("Bearer {token}")
                .parse()
                .map_err(|_| "InvalidData")?,
        );
        if let Some(password) = password {
            req.headers_mut().insert(
                ACCESS_HEADER,
                access_password(password)?
                    .parse()
                    .map_err(|_| "InvalidData")?,
            );
        }
        if !is_v2 {
            req.headers_mut()
                .insert("Sec-WebSocket-Protocol", "common-relay.v1".parse().unwrap());
        }
        let cfg = tungstenite::protocol::WebSocketConfig::default()
            .max_message_size(Some(FRAME_LIMIT))
            .max_frame_size(Some(FRAME_LIMIT));
        let address = (
            u.host_str().ok_or("InvalidData")?,
            u.port_or_known_default().ok_or("InvalidData")?,
        )
            .to_socket_addrs()
            .map_err(|_| "RelayConnection")?
            .next()
            .ok_or("RelayConnection")?;
        let tcp = TcpStream::connect_timeout(&address, Duration::from_secs(15))
            .map_err(|_| "RelayConnection")?;
        tcp.set_read_timeout(Some(Duration::from_secs(15)))
            .map_err(|_| "RelayConnection")?;
        tcp.set_write_timeout(Some(Duration::from_secs(15)))
            .map_err(|_| "RelayConnection")?;
        let control = tcp.try_clone().map_err(|_| "RelayConnection")?;
        let (mut socket, response) = tungstenite::client_tls_with_config(req, tcp, Some(cfg), None)
            .map_err(|error| match error {
                tungstenite::HandshakeError::Failure(tungstenite::Error::Http(response)) => {
                    format!("RelayHttp{}", response.status().as_u16())
                }
                _ => "RelayConnection".to_owned(),
            })?;
        if !is_v2
            && response
                .headers()
                .get("Sec-WebSocket-Protocol")
                .and_then(|h| h.to_str().ok())
                != Some("common-relay.v1")
        {
            return invalid();
        }
        let greeting: Value = loop {
            match socket.read().map_err(io_error)? {
                Message::Text(t) => break serde_json::from_str(&t).map_err(|_| "InvalidData")?,
                Message::Ping(_) | Message::Pong(_) => continue,
                _ => return invalid(),
            }
        };
        if is_v2 {
            let device = greeting["from"]
                .as_str()
                .or_else(|| greeting["device"].as_str());
            if greeting["type"] != "hello" || device != Some(identity.device.as_str()) {
                return Err("RelayIdentityMismatch".into());
            }
        } else if greeting["type"] != "welcome"
            || greeting["version"] != 1
            || greeting["identity"]["app"] != identity.app
            || greeting["identity"]["group"] != identity.group
            || greeting["identity"]["device"] != identity.device
            || greeting["identity"]["public_key"] != hex(&identity.secret.public_key().0)
        {
            return Err("RelayIdentityMismatch".into());
        }
        // Short reads let senders take the socket between frames.
        raw_stream(&mut socket)?
            .set_read_timeout(Some(Duration::from_millis(100)))
            .map_err(|_| "RelayConnection")?;
        let (events_tx, events_rx) = channel();
        let shared = Arc::new(Shared {
            socket: Mutex::new(socket),
            tcp: control,
            identity,
            is_v2,
            journal,
            pending: Mutex::new(HashMap::new()),
            events: events_tx,
            closed: AtomicBool::new(false),
            error: Mutex::new(None),
        });
        let reader = shared.clone();
        std::thread::Builder::new()
            .name("relay-reader".into())
            .spawn(move || {
                let mut cleaned = Instant::now();
                while !reader.closed.load(Ordering::SeqCst) {
                    let frame = match reader.socket.lock() {
                        Ok(mut socket) => socket.read().map_err(io_error),
                        Err(_) => Err("RelayConnection".into()),
                    };
                    let outcome = match frame {
                        Ok(Message::Text(t)) => serde_json::from_str::<Value>(&t)
                            .map_err(|_| "InvalidData".to_owned())
                            .and_then(|v| reader.dispatch(v)),
                        Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_)) => Ok(()),
                        Ok(Message::Binary(_)) => Ok(()), // Streams are not used by PasswordVault.
                        Ok(Message::Close(_)) => Err("RelayConnection".into()),
                        Err(e) if e == "Timeout" => {
                            std::thread::sleep(Duration::from_millis(5));
                            Ok(())
                        }
                        Err(e) => Err(e),
                    };
                    if let Err(e) = outcome {
                        reader.fail(e);
                        break;
                    }
                    if cleaned.elapsed() > Duration::from_secs(3600) {
                        cleaned = Instant::now();
                        if let Some(journal) = &reader.journal {
                            let _ = journal.cleanup();
                        }
                    }
                }
            })
            .map_err(|_| "Storage")?;
        Ok(Connection {
            shared,
            events: Mutex::new(events_rx),
        })
    }

    pub fn identity(&self) -> &Identity {
        &self.shared.identity
    }

    /// Next application event, `Ok(None)` on timeout, `Err` once the connection is closed.
    pub fn next_event(&self, timeout: Duration) -> Result<Option<Value>> {
        let events = self.events.lock().map_err(|_| "RelayConnection")?;
        match events.recv_timeout(timeout) {
            Ok(event) => Ok(Some(event)),
            Err(RecvTimeoutError::Timeout) if !self.shared.closed.load(Ordering::SeqCst) => {
                Ok(None)
            }
            _ => Err(self
                .shared
                .error
                .lock()
                .ok()
                .and_then(|e| e.clone())
                .unwrap_or_else(|| "RelayConnection".into())),
        }
    }

    pub fn peers(&self) -> Result<Value> {
        self.shared.request(json!({"type":"peers"}))
    }

    /// Online-only frame: no journal, no receipt, no replay.
    pub fn send_online(&self, to: &str, data: &[u8]) -> Result<()> {
        let id = random_hex(16);
        let body =
            self.shared
                .identity
                .seal(to, "message", &id, json!({"data":STANDARD.encode(data)}))?;
        self.shared
            .send(json!({"type":"message","id":id,"to":to,"body":body,"offline":false}))
    }

    /// Sends a message and waits for the relay's reply (`stored`, `forwarded`, `received`).
    /// Offline messages are journaled first so a retry with the same `id` resends the same body.
    pub fn message(&self, to: &str, data: &[u8], offline: bool, id: Option<&str>) -> Result<Value> {
        let shared = &self.shared;
        let id = id.map(str::to_owned).unwrap_or_else(|| random_hex(16));
        let encoded = STANDARD.encode(data);
        let (body, expires) = if offline {
            let journal = shared.journal.as_ref().ok_or("PersistentJournalRequired")?;
            let row = journal.prepare(&shared.scope(), &id, to, data, OFFLINE_TTL, |expires| {
                Ok(shared.identity.seal(
                    to,
                    "message",
                    &id,
                    json!({"data":encoded,"expires":expires}),
                )?)
            })?;
            if row["status"] == "received" {
                return Ok(json!({"type":"received","id":id}));
            }
            (
                text(&row, "body")?.to_owned(),
                row["expires"].as_u64().unwrap_or(0),
            )
        } else {
            (
                shared
                    .identity
                    .seal(to, "message", &id, json!({"data":encoded}))?,
                0,
            )
        };
        let reply = shared.request(json!({"type":"message","id":id,"to":to,"body":body,"offline":offline,"expires":expires}))?;
        if offline && reply["type"] == "received" {
            if let Some(journal) = &shared.journal {
                journal.complete(&shared.scope(), &id)?;
            }
        }
        Ok(reply)
    }

    /// Records the message as handled (drops future replays) and acknowledges it.
    pub fn acknowledge(&self, from: &str, id: &str, offline: bool) -> Result<Value> {
        let shared = &self.shared;
        if offline && shared.journal.is_none() {
            return Err("PersistentJournalRequired".into());
        }
        if let Some(journal) = &shared.journal {
            journal.acknowledge(&shared.scope(), from, id)?;
        }
        let ack = json!({"type":"ack","id":id,"from":from});
        if shared.is_v2 {
            // v2 relays answer an ack only to the sender (`received`), never to us.
            shared.send(ack)?;
            return Ok(json!({"type":"ack","id":id}));
        }
        shared.request(ack)
    }

    pub fn close(&self) {
        self.shared.fail("RelayClosed".into());
    }

    pub fn is_closed(&self) -> bool {
        self.shared.closed.load(Ordering::SeqCst)
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        self.close();
    }
}
