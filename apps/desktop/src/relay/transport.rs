//! Bounded WSS transport; callers own reconnect and business acknowledgments.
use super::{
    Result, invalid,
    protocol::{hex, text},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    net::{TcpStream, ToSocketAddrs},
    time::Duration,
};
use tungstenite::{Message, WebSocket, client::IntoClientRequest, stream::MaybeTlsStream};
#[cfg(test)]
pub use vault_core::relay_protocol::box_keypair;
pub use vault_core::relay_protocol::{BoxPublicKey, BoxSecretKey, Identity, endpoint};
pub struct Connection {
    socket: WebSocket<MaybeTlsStream<TcpStream>>,
    pub identity: Identity,
    is_v2: bool,
}
impl Connection {
    pub fn connect(
        raw: &str,
        token: &str,
        password: Option<&str>,
        identity: Identity,
        local: bool,
    ) -> Result<Self> {
        Self::connect_controlled(raw, token, password, identity, local, None)
    }
    pub fn connect_controlled(
        raw: &str,
        token: &str,
        password: Option<&str>,
        identity: Identity,
        local: bool,
        control: Option<&super::runtime::Run>,
    ) -> Result<Self> {
        let u = endpoint(raw, local)?;
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
                super::protocol::ACCESS_HEADER,
                super::protocol::access_password(password)?
                    .parse()
                    .map_err(|_| "InvalidData")?,
            );
        }
        if !is_v2 {
            req.headers_mut()
                .insert("Sec-WebSocket-Protocol", "common-relay.v1".parse().unwrap());
        }
        let cfg = tungstenite::protocol::WebSocketConfig::default()
            .max_message_size(Some(270336))
            .max_frame_size(Some(270336));
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
        if let Some(control) = control {
            let mut slot = control.socket.lock().map_err(|_| "Storage")?;
            if control.stopped() {
                return Err("Locked".into());
            }
            *slot = Some(tcp.try_clone().map_err(|_| "RelayConnection")?);
        }
        let (mut socket, response) = tungstenite::client_tls_with_config(req, tcp, Some(cfg), None)
            .map_err(|error| match error {
                tungstenite::HandshakeError::Failure(tungstenite::Error::Http(response)) => format!("RelayHttp{}", response.status().as_u16()),
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
        let stream = match socket.get_mut() {
            MaybeTlsStream::Plain(s) => s,
            MaybeTlsStream::Rustls(s) => &mut s.sock,
            _ => return invalid(),
        };
        stream
            .set_read_timeout(Some(Duration::from_secs(15)))
            .map_err(|_| "RelayConnection")?;
        stream
            .set_write_timeout(Some(Duration::from_secs(15)))
            .map_err(|_| "RelayConnection")?;
        let msg = socket.read().map_err(|_| "RelayConnection")?;
        let v: Value = serde_json::from_str(msg.to_text().map_err(|_| "InvalidData")?)
            .map_err(|_| "InvalidData")?;
        if is_v2 {
            let dev = v["from"].as_str().or_else(|| v["device"].as_str());
            if v["type"] != "hello" || dev != Some(identity.device.as_str()) {
                return invalid();
            }
        } else if v["version"] != 1
            || v["identity"]["app"] != identity.app
            || v["identity"]["group"] != identity.group
            || v["identity"]["device"] != identity.device
            || v["identity"]["public_key"] != hex(&identity.secret.public_key().0)
        {
            return invalid();
        }
        Ok(Self {
            socket,
            identity,
            is_v2,
        })
    }
    pub fn poll_timeout(&mut self) -> Result<()> {
        let s = match self.socket.get_mut() {
            MaybeTlsStream::Plain(s) => s,
            MaybeTlsStream::Rustls(s) => &mut s.sock,
            _ => return invalid(),
        };
        s.set_read_timeout(Some(Duration::from_millis(200)))
            .map_err(|_| "RelayConnection".into())
    }
    fn translate_incoming_v2(&self, v: Value) -> Value {
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
                    .map(|dev| json!({"app": self.identity.app, "group": self.identity.group, "device": dev}))
                    .collect();
                json!({"type": "peers", "id": v["id"], "devices": devices})
            }
            Some("msg") => json!({
                "type": "message",
                "id": v["id"],
                "from": v["from"],
                "body": v["body"],
                "offline": v["offline"].as_bool().unwrap_or(false),
            }),
            Some("ack") => {
                let kind = v["event"].as_str().unwrap_or("stored");
                json!({"type": kind, "id": v["id"]})
            }
            Some("group.changed") => {
                json!({"type": "group.changed", "revision": v["seq"].as_u64().unwrap_or(0)})
            }
            _ => v,
        }
    }
    fn translate_outgoing_v2(&self, event: Value) -> Value {
        if !self.is_v2 {
            return event;
        }
        match event["type"].as_str() {
            Some("peers") => json!({
                "type": "presence",
                "space": self.identity.group,
                "id": event["id"],
            }),
            Some("message") => json!({
                "type": "msg",
                "space": self.identity.group,
                "id": event["id"],
                "to": event["to"],
                "body": event["body"],
                "offline": event["offline"].as_bool().unwrap_or(false),
            }),
            Some("ack") => json!({
                "type": "ack",
                "space": self.identity.group,
                "id": event["id"],
                "from": event["from"],
            }),
            _ => event,
        }
    }
    pub fn read_wire(&mut self) -> Result<Value> {
        loop {
            let message = self.socket.read().map_err(|e| match e {
                tungstenite::Error::Io(ref io)
                    if matches!(
                        io.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    "Timeout".to_string()
                }
                _ => "RelayConnection".to_string(),
            })?;
            match message {
                Message::Text(t) => {
                    let v: Value = serde_json::from_str(&t).map_err(|_| "InvalidData")?;
                    return Ok(self.translate_incoming_v2(v));
                }
                Message::Ping(_) | Message::Pong(_) => continue,
                _ => return invalid(),
            }
        }
    }
    pub fn send_online(&mut self, to: &str, data: &[u8]) -> Result<()> {
        let id = uuid::Uuid::new_v4().simple().to_string();
        let body = self
            .identity
            .seal(to, "message", &id, json!({"data":STANDARD.encode(data)}))?;
        self.send(json!({"type":"message","id":id,"to":to,"body":body,"offline":false}))
    }
    pub fn send(&mut self, event: Value) -> Result<()> {
        let text = self.translate_outgoing_v2(event).to_string();
        if text.len() > 270336 {
            return invalid();
        }
        self.socket
            .send(Message::Text(text.into()))
            .map_err(|_| "RelayConnection".into())
    }
    pub fn receive(&mut self) -> Result<Value> {
        loop {
            match self.socket.read().map_err(|_| "RelayConnection")? {
                Message::Text(t) => {
                    let raw: Value = serde_json::from_str(&t).map_err(|_| "InvalidData")?;
                    let mut v = self.translate_incoming_v2(raw);
                    if v["type"] == "message" {
                        if v["offline"] == true {
                            return Err("PersistentJournalRequired".into());
                        }
                        let plain = self.identity.open(
                            text(&v, "from")?,
                            "message",
                            text(&v, "id")?,
                            text(&v, "body")?,
                        )?;
                        v["data"] = plain["data"].clone();
                    }
                    return Ok(v);
                }
                Message::Ping(_) | Message::Pong(_) => continue,
                _ => return invalid(),
            }
        }
    }
}
impl Drop for Connection {
    fn drop(&mut self) {
        let _ = self.socket.close(None);
    }
}
