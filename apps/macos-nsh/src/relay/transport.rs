//! Bounded WSS transport; callers own reconnect and business acknowledgments.
use super::{
    Result, invalid,
    protocol::{hex, text},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use sodiumoxide::crypto::box_;
use std::{
    collections::BTreeMap,
    net::{TcpStream, ToSocketAddrs},
    time::Duration,
};
use tungstenite::{Message, WebSocket, client::IntoClientRequest, stream::MaybeTlsStream};
pub struct Identity {
    pub app: String,
    pub group: String,
    pub device: String,
    pub secret: box_::SecretKey,
    pub trusted: BTreeMap<String, box_::PublicKey>,
}
impl Identity {
    fn context(&self, from: &str, to: &str, kind: &str, id: &str) -> Value {
        json!([1, self.app, self.group, from, to, kind, id])
    }
    pub fn seal(&self, to: &str, kind: &str, id: &str, value: Value) -> Result<String> {
        let peer = self.trusted.get(to).ok_or("UntrustedPeer")?;
        let nonce = box_::gen_nonce();
        let plain = zeroize::Zeroizing::new(
            json!({"context":self.context(&self.device,to,kind,id),"value":value}).to_string(),
        );
        let mut raw = nonce.0.to_vec();
        raw.extend(box_::seal(plain.as_bytes(), &nonce, peer, &self.secret));
        Ok(STANDARD.encode(raw))
    }
    pub fn open(&self, from: &str, kind: &str, id: &str, body: &str) -> Result<Value> {
        let peer = self.trusted.get(from).ok_or("UntrustedPeer")?;
        let raw = STANDARD.decode(body).map_err(|_| "InvalidData")?;
        if !(40..=270336).contains(&raw.len()) {
            return invalid();
        }
        let nonce = box_::Nonce::from_slice(&raw[..24]).ok_or("InvalidData")?;
        let plain = zeroize::Zeroizing::new(
            box_::open(&raw[24..], &nonce, peer, &self.secret).map_err(|_| "Authentication")?,
        );
        let v: Value = serde_json::from_slice(&plain).map_err(|_| "InvalidData")?;
        if v["context"] != self.context(from, &self.device, kind, id) || !v["value"].is_object() {
            return invalid();
        }
        Ok(v["value"].clone())
    }
}
pub fn endpoint(raw: &str, local: bool) -> Result<url::Url> {
    let u = url::Url::parse(raw).map_err(|_| "InvalidData")?;
    if !(u.scheme() == "wss" || (local && u.scheme() == "ws" && u.host_str() == Some("127.0.0.1")))
        || u.host_str().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
        || u.path() != "/relay/v1/ws"
    {
        return invalid();
    }
    Ok(u)
}
pub struct Connection {
    socket: WebSocket<MaybeTlsStream<TcpStream>>,
    pub identity: Identity,
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
        req.headers_mut()
            .insert("Sec-WebSocket-Protocol", "common-relay.v1".parse().unwrap());
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
        if response
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
        if v["version"] != 1
            || v["identity"]["app"] != identity.app
            || v["identity"]["group"] != identity.group
            || v["identity"]["device"] != identity.device
            || v["identity"]["public_key"] != hex(&identity.secret.public_key().0)
        {
            return invalid();
        }
        Ok(Self { socket, identity })
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
                    return serde_json::from_str(&t).map_err(|_| "InvalidData".into());
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
        let text = event.to_string();
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
                    let mut v: Value = serde_json::from_str(&t).map_err(|_| "InvalidData")?;
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
