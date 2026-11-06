const TEST_PASSWORD: &str = "qa-relay-fixture-passphrase";
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use super::{
    groups::{Groups, Http, now},
    protocol::*,
    *,
};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    net::TcpListener,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
};
struct Fixture {
    url: String,
    connections: Arc<AtomicUsize>,
    rejected: Arc<AtomicUsize>,
    reject_exit: Arc<AtomicBool>,
    hold_group: Arc<AtomicBool>,
    group_entered: Arc<AtomicBool>,
    polls: Arc<AtomicUsize>,
    live: Arc<AtomicUsize>,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let _ = std::net::TcpStream::connect(
            self.url
                .trim_start_matches("ws://")
                .trim_end_matches("/relay/v1/ws"),
        );
        self.thread.take().unwrap().join().unwrap();
    }
}
impl Fixture {
    fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        let connections = Arc::new(AtomicUsize::new(0));
        let polls = Arc::new(AtomicUsize::new(0));
        let live = Arc::new(AtomicUsize::new(0));
        let rejected = Arc::new(AtomicUsize::new(0));
        let rejected_count = rejected.clone();
        let reject_exit = Arc::new(AtomicBool::new(false));
        let reject_exit_flag = reject_exit.clone();
        let hold_group = Arc::new(AtomicBool::new(false));
        let hold = hold_group.clone();
        let group_entered = Arc::new(AtomicBool::new(false));
        let entered = group_entered.clone();
        let counts = connections.clone();
        let poll_count = polls.clone();
        let live_count = live.clone();
        let routes = Arc::new(std::sync::Mutex::new(BTreeMap::<
            String,
            std::sync::mpsc::Sender<Value>,
        >::new()));
        let offline = Arc::new(std::sync::Mutex::new(BTreeMap::<String, Vec<Value>>::new()));
        let thread = std::thread::spawn(move || {
            let mut entries: Vec<Value> = vec![];
            let mut invites: BTreeMap<String, Value> = BTreeMap::new();
            let mut tokens: BTreeMap<String, String> = BTreeMap::new();
            for stream in listener.incoming() {
                if flag.load(Ordering::SeqCst) {
                    break;
                }
                let mut stream = stream.unwrap();
                stream
                    .set_read_timeout(Some(std::time::Duration::from_secs(3)))
                    .unwrap();
                let mut bytes = vec![];
                let mut byte = [0];
                while !bytes.ends_with(b"\r\n\r\n") {
                    if stream.read_exact(&mut byte).is_err() {
                        break;
                    }
                    bytes.push(byte[0]);
                    if bytes.len() > 16384 {
                        break;
                    }
                }
                let header = String::from_utf8(bytes).unwrap();
                let mut lines = header.lines();
                let mut first = lines.next().unwrap().split_whitespace();
                let method = first.next().unwrap();
                let path = first
                    .next()
                    .unwrap()
                    .strip_prefix("/relay/v1")
                    .unwrap()
                    .to_owned();
                let headers: BTreeMap<_, _> = lines
                    .filter_map(|l| l.split_once(':'))
                    .map(|(k, v)| (k.to_ascii_lowercase(), v.trim().to_owned()))
                    .collect();
                let length = headers
                    .get("content-length")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0usize);
                let mut body = vec![0; length];
                stream.read_exact(&mut body).unwrap();
                let body: Value = if body.is_empty() {
                    json!({})
                } else {
                    serde_json::from_slice(&body).unwrap()
                };
                let auth = headers
                    .get("authorization")
                    .map(String::as_str)
                    .unwrap_or("");
                // Like the real relay, every request must carry the server access password.
                if headers.get("relay-access").map(String::as_str) != Some(RELAY_ACCESS)
                    || (path == "/group/exit" && reject_exit_flag.load(Ordering::SeqCst)) {
                    rejected_count.fetch_add(1, Ordering::SeqCst);
                    let _ = write!(stream, "HTTP/1.1 401 Fixture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                    continue;
                }
                if path.starts_with("/group?after=") && hold.load(Ordering::SeqCst) {
                    entered.store(true, Ordering::SeqCst);
                    while hold.load(Ordering::SeqCst) && !flag.load(Ordering::SeqCst) {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                    }
                }
                if path == "/ws" {
                    let device = tokens
                        .get(&digest(
                            auth.strip_prefix("Bearer ").unwrap_or("").as_bytes(),
                        ))
                        .unwrap()
                        .clone();
                    let state = unpack(entries.last().unwrap()).unwrap();
                    let member = state["members"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .find(|m| m["device"] == device)
                        .unwrap();
                    let identity = json!({"app":state["app"],"group":state["group"],"device":device,"public_key":member["public_key"]});
                    let accept = tungstenite::handshake::derive_accept_key(
                        headers["sec-websocket-key"].as_bytes(),
                    );
                    write!(stream,"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Protocol: common-relay.v1\r\n\r\n").unwrap();
                    let count = counts.fetch_add(1, Ordering::SeqCst);
                    let stop = flag.clone();
                    let polls = poll_count.clone();
                    let live = live_count.clone();
                    let routes = routes.clone();
                    let offline = offline.clone();
                    let (tx, rx) = std::sync::mpsc::channel();
                    if count > 0 {
                        routes.lock().unwrap().insert(device.clone(), tx.clone());
                        for event in offline.lock().unwrap().get(&device).into_iter().flatten() {
                            let _ = tx.send(event.clone());
                        }
                    }
                    std::thread::spawn(move || {
                        live.fetch_add(1, Ordering::SeqCst);
                        stream
                            .set_read_timeout(Some(std::time::Duration::from_millis(200)))
                            .unwrap();
                        let mut ws = tungstenite::WebSocket::from_raw_socket(
                            stream,
                            tungstenite::protocol::Role::Server,
                            None,
                        );
                        ws.send(tungstenite::Message::Text(
                            json!({"version":1,"identity":identity}).to_string().into(),
                        ))
                        .unwrap();
                        if count > 0 {
                            while !stop.load(Ordering::SeqCst) {
                                for event in rx.try_iter() {
                                    let _ = ws
                                        .send(tungstenite::Message::Text(event.to_string().into()));
                                }
                                match ws.read() {
                                    Ok(tungstenite::Message::Text(t)) => {
                                        let e: Value = serde_json::from_str(&t).unwrap();
                                        if e["type"] == "message" {
                                            let mut out = e.clone();
                                            out["from"] = json!(device);
                                            if e["offline"] == true {
                                                let mut store = offline.lock().unwrap();
                                                let saved = store
                                                    .entry(e["to"].as_str().unwrap().to_owned())
                                                    .or_default();
                                                saved.retain(|v| {
                                                    v["from"] != device || v["id"] != e["id"]
                                                });
                                                saved.push(out.clone());
                                            }
                                            if e["offline"] == true {
                                                let _ = ws.send(tungstenite::Message::Text(
                                                    json!({"type":"queued","id":e["id"]})
                                                        .to_string()
                                                        .into(),
                                                ));
                                            }
                                            if let Some(sender) = routes
                                                .lock()
                                                .unwrap()
                                                .get(e["to"].as_str().unwrap())
                                            {
                                                let _ = sender.send(out);
                                            }
                                        } else if e["type"] == "ack" {
                                            if let Some(saved) =
                                                offline.lock().unwrap().get_mut(&device)
                                            {
                                                saved.retain(|v| {
                                                    v["from"] != e["from"] || v["id"] != e["id"]
                                                });
                                            }
                                            if let Some(sender) = routes
                                                .lock()
                                                .unwrap()
                                                .get(e["from"].as_str().unwrap())
                                            {
                                                let _ = sender
                                                    .send(json!({"type":"received","id":e["id"]}));
                                            }
                                        } else if e["type"] == "peers" {
                                            polls.fetch_add(1, Ordering::SeqCst);
                                            if ws.send(tungstenite::Message::Text(json!({"type":"peers","id":e["id"],"devices":[]}).to_string().into())).is_err(){break;}
                                        }
                                    }
                                    Err(tungstenite::Error::Io(ref e))
                                        if matches!(
                                            e.kind(),
                                            std::io::ErrorKind::WouldBlock
                                                | std::io::ErrorKind::TimedOut
                                        ) =>
                                    {
                                        continue;
                                    }
                                    _ => break,
                                }
                            }
                        }
                        routes.lock().unwrap().remove(&device);
                        live.fetch_sub(1, Ordering::SeqCst);
                    });
                    continue;
                }
                let response = (|| -> std::result::Result<Value, u16> {
                    if path == "/files" && method == "GET" {
                        return Ok(json!([]));
                    }
                    if path == "/group/create" {
                        let e = body["entry"].clone();
                        let state = unpack(&e).map_err(|_| 400u16)?;
                        verify(
                            &e,
                            super::protocol::text(&state["members"][0], "signing_key")
                                .map_err(|_| 400u16)?,
                        )
                        .map_err(|_| 400u16)?;
                        if entries.is_empty() {
                            entries.push(e);
                        } else if entries[0] != e {
                            return Err(409);
                        }
                        tokens.insert(
                            body["token_hash"].as_str().unwrap().into(),
                            state["members"][0]["device"].as_str().unwrap().into(),
                        );
                        return Ok(json!({}));
                    }
                    let bearer = auth.strip_prefix("Bearer ").map(|s| digest(s.as_bytes()));
                    let actor = bearer.as_ref().and_then(|h| tokens.get(h)).cloned();
                    if path.starts_with("/group") && actor.is_none() {
                        return Err(401);
                    }
                    if path.starts_with("/group?after=") {
                        let after = path.split('=').nth(1).unwrap().parse::<u64>().unwrap();
                        return Ok(
                            json!({"entries":entries.iter().filter(|e|unpack(e).unwrap()["revision"].as_u64().unwrap()>after).collect::<Vec<_>>(),"revision":entries.len(),"online":[]}),
                        );
                    }
                    if path == "/group/invitations" {
                        let state = unpack(entries.last().unwrap()).unwrap();
                        let own = state["members"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .find(|m| Some(m["device"].as_str().unwrap()) == actor.as_deref())
                            .unwrap();
                        if own["manager"] != true {
                            return Err(403);
                        }
                        let (id, expiry, mode) = if body["mode"] == "auto" {
                            let grant = unpack(&body["grant"]).unwrap();
                            (
                                grant["invitation"].as_str().unwrap().to_owned(),
                                grant["expires"].as_u64().unwrap(),
                                "auto",
                            )
                        } else {
                            (
                                uuid::Uuid::new_v4().simple().to_string(),
                                now() + 600,
                                "manual",
                            )
                        };
                        invites.insert(id.clone(),json!({"secret_hash":body["secret_hash"],"grant":body["grant"],"expires":expiry,"mode":mode}));
                        return Ok(json!({"id":id,"expires":expiry,"mode":mode}));
                    }
                    if path == "/group" || path == "/group/exit" {
                        let e = body.clone();
                        if entries.last() == Some(&e) {
                            return Ok(json!({}));
                        }
                        advance(entries.last().unwrap(), &e).map_err(|_| 403u16)?;
                        let state = unpack(&e).unwrap();
                        if let Some(inv) =
                            invites.get_mut(state["invitation"].as_str().unwrap_or(""))
                        {
                            inv["entry"] = e.clone();
                            if let Ok(req) = unpack(&inv["request"]) {
                                tokens.insert(
                                    req["token_hash"].as_str().unwrap().into(),
                                    req["member"]["device"].as_str().unwrap().into(),
                                );
                            }
                        }
                        entries.push(e);
                        return Ok(json!({}));
                    }
                    let parts: Vec<_> = path
                        .split('?')
                        .next()
                        .unwrap()
                        .trim_start_matches('/')
                        .split('/')
                        .collect();
                    if parts.first() == Some(&"group") && parts.get(1) == Some(&"invitations") {
                        let id = *parts.get(2).ok_or(404u16)?;
                        let inv = invites.get_mut(id).ok_or(404u16)?;
                        if method == "DELETE" {
                            inv["cancelled"] = json!(true);
                            return Ok(json!({}));
                        }
                        if parts.get(3) == Some(&"link") {
                            inv["packet"] = body["packet"].clone();
                            inv["read_hash"] = body["read_hash"].clone();
                            return Ok(json!({}));
                        }
                        return Ok(json!({"request":inv["request"]}));
                    }
                    if parts.first() == Some(&"enroll") {
                        let id = *parts.get(1).ok_or(404u16)?;
                        let inv = invites.get_mut(id).ok_or(404u16)?;
                        if inv["cancelled"] == true {
                            return Err(410);
                        }
                        if inv["expires"].as_u64().unwrap() <= now() {
                            return Err(410);
                        }
                        if parts.get(2) == Some(&"link") {
                            let token = auth.strip_prefix("InvitationLink ").ok_or(401u16)?;
                            if inv["read_hash"] != digest(token.as_bytes()) {
                                return Err(401);
                            }
                            return Ok(json!({"version":1,"packet":inv["packet"]}));
                        }
                        if method == "POST" && parts.len() == 2 {
                            let secret = auth.strip_prefix("Invitation ").ok_or(401u16)?;
                            if inv["secret_hash"] != digest(secret.as_bytes()) {
                                return Err(401);
                            }
                            let req = unpack(&body).map_err(|_| 400u16)?;
                            verify(&body, req["member"]["signing_key"].as_str().unwrap())
                                .map_err(|_| 400u16)?;
                            if inv["request"].is_object() && inv["request"] != body {
                                return Err(409);
                            }
                            inv["request"] = body;
                            return Ok(json!({}));
                        }
                        let token = auth.strip_prefix("Claim ").ok_or(401u16)?;
                        let req = unpack(&inv["request"]).map_err(|_| 404u16)?;
                        if req["token_hash"] != digest(token.as_bytes()) {
                            return Err(401);
                        }
                        if parts.get(2) == Some(&"auto") {
                            if method == "GET" {
                                let after = path.split('=').nth(1).unwrap().parse::<u64>().unwrap();
                                return Ok(
                                    json!({"entries":entries.iter().filter(|e|unpack(e).unwrap()["revision"].as_u64().unwrap()>after).collect::<Vec<_>>(),"revision":entries.len(),"entry":inv["entry"]}),
                                );
                            }
                            advance(entries.last().unwrap(), &body).map_err(|_| 403u16)?;
                            let state = unpack(&body).unwrap();
                            if state["request_hash"] != digest(&payload(&inv["request"]).unwrap()) {
                                return Err(403);
                            }
                            inv["entry"] = body.clone();
                            entries.push(body.clone());
                            tokens.insert(
                                digest(token.as_bytes()),
                                req["member"]["device"].as_str().unwrap().into(),
                            );
                            return Ok(body);
                        }
                        return Ok(json!({"entry":inv["entry"]}));
                    }
                    Err(404)
                })();
                let (status, value) = match response {
                    Ok(v) => (200, v),
                    Err(s) => (s, json!({"error":"fixture rejection"})),
                };
                let data = value.to_string();
                let _ = write!(
                    stream,
                    "HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    data.len(),
                    data
                );
            }
        });
        Self {
            url: format!("ws://{address}/relay/v1/ws"),
            connections,
            rejected,
            reject_exit,
            hold_group,
            group_entered,
            polls,
            live,
            stop,
            thread: Some(thread),
        }
    }
}
const RELAY_ACCESS: &str = "relay-access-1";
fn config(url: &str, device: &str) -> Value {
    json!({"app":"passwordvault","device":device,"url":url,"password":RELAY_ACCESS,"secret_key":hex(&sodiumoxide::randombytes::randombytes(32))})
}
/// A device that has not configured the relay yet (no URL, no access password).
fn fresh(device: &str) -> Value {
    json!({"app":"passwordvault","device":device,"secret_key":hex(&sodiumoxide::randombytes::randombytes(32))})
}
#[test]
fn group_local_http_auto_manual_lifecycle_and_failure_paths() {
    sodiumoxide::init().unwrap();
    let server = Fixture::new();
    let mut saved = json!({});
    let mut save = |v: &Value| {
        saved = v.clone();
        Ok(())
    };
    let mut mac = Groups {
        config: config(&server.url, "mac"),
        api: Http { local: true },
        save: &mut save,
        local: true,
    };
    mac.create("QA group", "Mac").unwrap();
    let initial = mac.config.clone();
    assert!(mac.create("Another", "Mac").is_err());
    let auto = mac.invite("auto").unwrap();
    assert!(auto.starts_with("common-relay://127.0.0.1:"));
    let mut save_phone = |_: &Value| Ok(());
    let mut phone = Groups {
        config: fresh("phone"),
        api: Http { local: true },
        save: &mut save_phone,
        local: true,
    };
    assert!(auto.ends_with(&format!(".{}", URL_SAFE_NO_PAD.encode(RELAY_ACCESS))));
    let bare = auto.rsplit_once('.').unwrap().0.to_owned();
    assert_eq!(phone.resolve(&bare, None).unwrap_err(), "RelayHttp401");
    assert!(phone.resolve(&bare, Some("wrong-access-1")).is_err());
    assert_eq!(phone.resolve(&bare, Some(RELAY_ACCESS)).unwrap()["password"], RELAY_ACCESS);
    let inv = phone.resolve(&auto, None).unwrap();
    assert_eq!(inv["password"], RELAY_ACCESS);
    let mut expired = inv.clone();
    expired["expires"] = json!(1);
    assert!(phone.join(expired, "Phone").is_err());
    let mut tampered = inv.clone();
    tampered["delegate_secret"] = json!("00".repeat(32));
    assert!(phone.join(tampered, "Phone").is_err());
    assert!(phone.join(inv, "Phone").unwrap());
    assert_eq!(phone.config["password"], RELAY_ACCESS);
    assert!(phone.invite("auto").is_err());
    phone.rename("phone", "Renamed Phone").unwrap();
    assert!(phone.rename("mac", "Impostor").is_err());
    mac.refresh().unwrap();
    mac.cancel().unwrap();
    assert!(phone.resolve(&auto, None).is_err());
    let manual = mac.invite("manual").unwrap();
    let mut save_tablet = |_: &Value| Ok(());
    let mut tablet = Groups {
        config: config(&server.url, "tablet"),
        api: Http { local: true },
        save: &mut save_tablet,
        local: true,
    };
    let inv = tablet.resolve(&manual, None).unwrap();
    assert!(!tablet.join(inv, "Tablet").unwrap());
    mac.pending().unwrap();
    assert_eq!(mac.code().unwrap(), tablet.code().unwrap());
    assert!(mac.approve("0000-0000-0000", false).is_err());
    let code = mac.code().unwrap();
    mac.approve(&code, true).unwrap();
    assert!(tablet.finish_join().unwrap());
    tablet.exit(false).unwrap();
    mac.remove("phone").unwrap();
    mac.exit(true).unwrap();
    assert_eq!(mac.config["exit_completed"], true);
    assert_ne!(initial["group_entry"], mac.config["group_entry"]);
}
#[test]
fn group_draft_storage_failure_prevents_network_mutation() {
    sodiumoxide::init().unwrap();
    let server = Fixture::new();
    let mut fail = |_: &Value| Err("Storage".into());
    let mut g = Groups {
        config: config(&server.url, "mac"),
        api: Http { local: true },
        save: &mut fail,
        local: true,
    };
    assert_eq!(g.create("QA", "Mac"), Err("Storage".into()));
    let draft = g.config.clone();
    let mut ok = |_: &Value| Ok(());
    let mut retry = Groups {
        config: draft.clone(),
        api: Http { local: true },
        save: &mut ok,
        local: true,
    };
    retry.create("ignored retry name", "ignored").unwrap();
    assert_eq!(retry.config["group_entry"], draft["pending_create"]);
    assert_eq!(retry.config["token"], draft["token"]);
}

#[test]
fn relay_presence_reconnects_polls_and_lock_disconnects() {
    sodiumoxide::init().unwrap();
    let server = Fixture::new();
    let directory = std::path::PathBuf::from("/tmp")
        .join(format!("pv-relay-lifecycle-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let session =
        Arc::new(vault_core::VaultSession::new(directory.to_string_lossy().into()).unwrap());
    service::core(&session, json!({"op":"create","password":TEST_PASSWORD})).unwrap();
    service::execute(
        &session,
        json!({"op":"create","endpoint":server.url,"relayPassword":RELAY_ACCESS,"name":"QA","deviceName":"Mac"}),
        true,
    )
    .unwrap();
    runtime::start(session.clone(), directory.clone(), true).unwrap();
    let wait = |condition: &dyn Fn() -> bool, seconds: u64| {
        let end = std::time::Instant::now() + std::time::Duration::from_secs(seconds);
        while !condition() && std::time::Instant::now() < end {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        assert!(condition());
    };
    wait(&|| server.connections.load(Ordering::SeqCst) >= 2, 5);
    wait(&|| server.polls.load(Ordering::SeqCst) >= 2, 7);
    assert_eq!(runtime::view(&session)["transport"], "connected");
    service::core(&session, json!({"op":"lock"})).unwrap();
    runtime::stop(&session);
    wait(&|| server.live.load(Ordering::SeqCst) == 0, 1);
    assert_eq!(runtime::view(&session)["transport"], "disconnected");
    drop(session);
    std::fs::remove_dir_all(directory).unwrap();
}
#[test]
fn relay_local_grant_ack_sync_and_local_first_revoke() {
    use base64::Engine;
    sodiumoxide::init().unwrap();
    let server = Fixture::new();
    let root =
        std::path::PathBuf::from("/tmp").join(format!("pv-relay-sync-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&root).unwrap();
    let mac =
        Arc::new(vault_core::VaultSession::new(root.join("mac").to_string_lossy().into()).unwrap());
    let phone = Arc::new(
        vault_core::VaultSession::new(root.join("phone").to_string_lossy().into()).unwrap(),
    );
    for s in [&mac, &phone] {
        service::core(s, json!({"op":"create","password":TEST_PASSWORD})).unwrap();
    }
    service::execute(
        &mac,
        json!({"op":"create","endpoint":server.url,"relayPassword":RELAY_ACCESS,"name":"QA","deviceName":"Mac"}),
        true,
    )
    .unwrap();
    let invite: Value = serde_json::from_str(
        &service::execute(&mac, json!({"op":"invite","mode":"auto"}), true).unwrap(),
    )
    .unwrap();
    service::execute(
        &phone,
        json!({"op":"join","link":invite["invitationLink"],"deviceName":"Phone"}),
        true,
    )
    .unwrap();
    let mut c = service::read(&phone).unwrap();
    c["role"] = json!("mobile");
    c["hub"] = json!("");
    let mut g = service::group(&c).unwrap();
    g["vault_authority"] = unpack(&g["group_entry"]).unwrap()["members"][0].clone();
    c["groupState"] = json!(base64::engine::general_purpose::STANDARD.encode(canonical(&g)));
    service::write(&phone, &c).unwrap();
    let peer = c["device"].as_str().unwrap().to_string();
    service::execute(&mac, json!({"op":"refresh"}), true).unwrap();
    let before = service::read(&mac).unwrap();
    assert!(before["peers"].as_object().unwrap().is_empty());
    super::access::set(&mac, &peer, true).unwrap();
    let awaiting = service::read(&mac).unwrap();
    assert_eq!(awaiting["peers"][&peer], awaiting["vaultGrants"][&peer]["key"]);
    assert_eq!(awaiting["paused"], false);
    assert_eq!(awaiting["vaultGrants"][&peer]["acknowledged"], false);
    assert_eq!(super::sync::outgoing(&mac).unwrap().len(), 1);
    // A transport receipt cannot grant permissions or resume a later local pause.
    let mut ack = super::access::message(
        &c,
        before["device"].as_str().unwrap(),
        &awaiting["vaultGrants"][&peer],
        "ack",
    );
    ack["revision"] = json!(99);
    super::access::receive(&mac, &peer, "00", &ack).unwrap();
    assert_eq!(service::read(&mac).unwrap()["vaultGrants"][&peer]["acknowledged"], false);
    assert_eq!(service::read(&mac).unwrap()["peers"], awaiting["peers"]);
    super::access::pause(&mac, true).unwrap();
    ack["revision"] = awaiting["vaultGrants"][&peer]["revision"].clone();
    let key = awaiting["vaultGrants"][&peer]["key"].as_str().unwrap();
    let mut wrong_group = ack.clone();
    wrong_group["group"] = json!("other-group");
    super::access::receive(&mac, &peer, key, &wrong_group).unwrap();
    assert_eq!(service::read(&mac).unwrap()["vaultGrants"][&peer]["acknowledged"], false);
    super::access::receive(&mac, &peer, key, &ack).unwrap();
    assert_eq!(service::read(&mac).unwrap()["paused"], true);
    assert_eq!(service::read(&mac).unwrap()["vaultGrants"][&peer]["acknowledged"], true);
    // Upgrade an old ack-gated pending grant on an explicit Mac sync action.
    let mut old_pending = service::read(&mac).unwrap();
    old_pending["peers"] = json!({});
    old_pending["vaultGrants"][&peer]["acknowledged"] = json!(false);
    service::write(&mac, &old_pending).unwrap();
    super::access::resume(&mac).unwrap();
    assert_eq!(service::read(&mac).unwrap()["paused"], false);
    assert_eq!(service::read(&mac).unwrap()["peers"][&peer], awaiting["peers"][&peer]);
    service::core(&mac,json!({"op":"save","item":{"id":"relay-fixture","type":"password","title":"QA item","password":"synthetic-secret","updatedAt":"2020-01-01T00:00:00Z"}})).unwrap();
    // Deliver data before control: no import and no receipt until authorization.
    let packet = super::sync::outgoing(&mac).unwrap().remove(0).2;
    let hub = before["device"].as_str().unwrap();
    let hub_key = g["trusted_peers"][hub].as_str().unwrap();
    assert_eq!(super::sync::receive(&phone, hub, hub_key, &packet).unwrap_err(), "VaultAccessDenied");
    let control = super::access::pending(&service::read(&mac).unwrap()).unwrap().remove(0).1;
    let mut invalid_control = control.clone();
    invalid_control["group"] = json!("other-group");
    assert!(super::access::receive(&phone, hub, hub_key, &invalid_control).unwrap().is_none());
    assert!(service::read(&phone).unwrap()["peers"].as_object().unwrap().is_empty());
    let reply = super::access::receive(&phone, hub, hub_key, &control).unwrap().unwrap();
    assert_eq!(reply["kind"], "ack");
    // Lose the first ack. Repeated control is accepted automatically and safe.
    assert_eq!(super::access::receive(&phone, hub, hub_key, &control).unwrap().unwrap(), reply);
    assert_eq!(service::read(&mac).unwrap()["vaultGrants"][&peer]["acknowledged"], false);
    super::sync::receive(&phone, hub, hub_key, &packet).unwrap();
    runtime::start(mac.clone(), root.join("mac"), true).unwrap();
    runtime::start(phone.clone(), root.join("phone"), true).unwrap();
    let wait = |f: &dyn Fn() -> bool| {
        let end = std::time::Instant::now() + std::time::Duration::from_secs(35);
        while !f() && std::time::Instant::now() < end {
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        assert!(
            f(),
            "mac={:?} phone={:?}",
            runtime::view(&mac),
            runtime::view(&phone)
        );
    };
    wait(&|| service::read(&mac).unwrap()["vaultGrants"][&peer]["acknowledged"] == true);
    wait(&|| {
        service::core(&phone, json!({"op":"list"})).unwrap()["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["id"] == "relay-fixture")
    });
    runtime::stop(&mac);
    runtime::stop(&phone);
    super::access::pause(&mac, true).unwrap();
    assert!(super::sync::outgoing(&mac).unwrap().is_empty());
    super::access::pause(&mac, false).unwrap();
    service::core(
        &mac,
        json!({"op":"devices-enable","currentPassword":TEST_PASSWORD,"confirm":true}),
    )
    .unwrap();
    service::core(&mac, json!({"op":"save","item":{"id":"format7-after","type":"secureNote","title":"Format seven relay canary"}})).unwrap();
    runtime::start(mac.clone(), root.join("mac"), true).unwrap();
    runtime::start(phone.clone(), root.join("phone"), true).unwrap();
    wait(&|| service::core(&phone, json!({"op":"list"})).unwrap()["items"].as_array().unwrap().iter().any(|i| i["id"] == "format7-after"));
    assert_eq!(service::core(&phone, json!({"op":"devices-status"})).unwrap()["formatVersion"], 7);
    assert!(service::core(&mac, json!({"op":"relay-status"})).unwrap()["capabilities"].as_array().unwrap().contains(&json!(peer)));
    assert!(service::core(&phone, json!({"op":"relay-status"})).unwrap()["capabilities"].as_array().unwrap().contains(&json!(hub)));
    runtime::stop(&mac);
    runtime::stop(&phone);
    super::access::set(&mac, &peer, false).unwrap();
    let revoked = service::read(&mac).unwrap();
    assert!(revoked["peers"].get(&peer).is_none());
    assert_eq!(revoked["vaultGrants"][&peer]["revision"], 3);
    super::access::receive(&mac, &peer, key, &ack).unwrap();
    assert!(service::read(&mac).unwrap()["peers"].get(&peer).is_none());
    assert!(
        super::sync::receive(
            &mac,
            &peer,
            revoked["vaultGrants"][&peer]["key"].as_str().unwrap(),
            b"{}"
        )
        .is_err()
    );
    let before_id = revoked["device"].clone();
    service::execute(&mac, json!({"op":"disband"}), true).unwrap();
    assert_ne!(service::read(&mac).unwrap()["device"], before_id);
    assert_eq!(
        service::core(&mac, json!({"op":"relay-status"})).unwrap()["enabled"],
        false
    );
    assert!(
        service::core(&mac, json!({"op":"list"})).unwrap()["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["id"] == "relay-fixture")
    );
    runtime::stop(&phone);
    service::execute(&mac, json!({"op":"clear-local"}), true).unwrap();
    assert_eq!(service::read(&mac).unwrap()["token"], "");
    drop(mac);
    drop(phone);
    std::thread::sleep(std::time::Duration::from_millis(300));
    std::fs::remove_dir_all(root).unwrap();
}
#[test]
fn relay_peer_chunk_router_requires_library_identity() {
    sodiumoxide::init().unwrap();
    let server = Fixture::new();
    let root =
        std::path::PathBuf::from("/tmp").join(format!("pv-relay-peer-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&root).unwrap();
    let a =
        Arc::new(vault_core::VaultSession::new(root.join("a").to_string_lossy().into()).unwrap());
    let b =
        Arc::new(vault_core::VaultSession::new(root.join("b").to_string_lossy().into()).unwrap());
    for s in [&a, &b] {
        service::core(s, json!({"op":"create","password":TEST_PASSWORD})).unwrap();
    }
    service::execute(
        &a,
        json!({"op":"create","endpoint":server.url,"relayPassword":RELAY_ACCESS,"name":"Peer QA","deviceName":"A"}),
        true,
    )
    .unwrap();
    let inv: Value = serde_json::from_str(
        &service::execute(&a, json!({"op":"invite","mode":"auto"}), true).unwrap(),
    )
    .unwrap();
    service::execute(
        &b,
        json!({"op":"join","link":inv["invitationLink"],"deviceName":"B"}),
        true,
    )
    .unwrap();
    service::execute(&a, json!({"op":"refresh"}), true).unwrap();
    let mut ac = service::read(&a).unwrap();
    let mut bc = service::read(&b).unwrap();
    let ad = ac["device"].as_str().unwrap().to_string();
    let bd = bc["device"].as_str().unwrap().to_string();
    let ag = service::group(&ac).unwrap();
    let bg = service::group(&bc).unwrap();
    let ak = ag["public_key"].as_str().unwrap().to_string();
    let bk = bg["public_key"].as_str().unwrap().to_string();
    let ai = service::core(
        &a,
        json!({"op":"relay-peer-create","device":ad,"personal":true,"transportKey":ak}),
    )
    .unwrap();
    let bi = service::core(
        &b,
        json!({"op":"relay-peer-identity","device":bd,"personal":true,"confirmPersonalSync":true}),
    )
    .unwrap();
    let lib = ai["library"].as_str().unwrap().to_string();
    service::core(&a,json!({"op":"relay-peer-authorize","library":lib,"peer":bd,"member":{"publicKey":bi["publicKey"],"transportKey":bk,"role":"editor"}})).unwrap();
    ac["peerLibrary"] = json!(lib);
    ac["peers"][&bd] = json!(bk);
    ac["paused"] = json!(false);
    service::write(&a, &ac).unwrap();
    bc["peerLibrary"] = bi["library"].clone();
    bc["peerExpectedLibrary"] = json!(lib);
    bc["peerPendingLocalLibrary"] = bi["library"].clone();
    bc["peerFounderKey"] = ai["publicKey"].clone();
    bc["peers"][&ad] = json!(ak);
    bc["paused"] = json!(false);
    service::write(&b, &bc).unwrap();
    service::core(&a,json!({"op":"save","richNotes":true,"item":{"id":"chunk-fixture","type":"secureNote","title":"Chunked note","noteFormat":"plain","note":"synthetic data ".repeat(14000)}})).unwrap();
    let preflight = super::sync::outgoing(&a).unwrap();
    assert!(
        !preflight.is_empty(),
        "peer export count is zero: frozen={}, memberKeyMatches={}",
        service::core(&a, json!({"op":"relay-peer-status","library":lib})).unwrap()["frozen"],
        service::core(&a, json!({"op":"relay-peer-status","library":lib})).unwrap()["members"][&bd]
            ["transportKey"]
            == bk
    );
    runtime::start(a.clone(), root.join("a"), true).unwrap();
    runtime::start(b.clone(), root.join("b"), true).unwrap();
    let end = std::time::Instant::now() + std::time::Duration::from_secs(35);
    let received = || {
        service::core(&b, json!({"op":"list"})).unwrap()["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["id"] == "chunk-fixture")
    };
    while !received() && std::time::Instant::now() < end {
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    assert!(
        received(),
        "a={:?},b={:?}",
        runtime::view(&a),
        runtime::view(&b)
    );
    runtime::stop(&a);
    runtime::stop(&b);
    assert!(super::sync::receive(&b, &ad, "00", b"{}").is_err());
    let data = super::sync::outgoing(&a).unwrap();
    assert!(data.iter().any(|(_, id, _)| id == &lib));
    super::access::set(&a, &bd, false).unwrap();
    assert!(service::read(&a).unwrap()["peers"].get(&bd).is_none());
    assert!(super::sync::outgoing(&a).unwrap().is_empty());
    drop(a);
    drop(b);
    std::thread::sleep(std::time::Duration::from_millis(300));
    std::fs::remove_dir_all(root).unwrap();
}

fn enrolled_fixture(server: &Fixture) -> (std::path::PathBuf, Arc<vault_core::VaultSession>) {
    let directory = std::env::temp_dir().join(format!("pv-relay-local-exit-{}", uuid::Uuid::new_v4()));
    let session = Arc::new(vault_core::VaultSession::new(directory.to_string_lossy().into()).unwrap());
    service::core(&session, json!({"op":"create","password":TEST_PASSWORD})).unwrap();
    service::execute(&session, json!({"op":"create","endpoint":server.url,"relayPassword":RELAY_ACCESS,"name":"QA","deviceName":"Mac"}), true).unwrap();
    (directory, session)
}
fn wait_exit(session: &Arc<vault_core::VaultSession>, expected: &str) {
    let until = std::time::Instant::now() + std::time::Duration::from_secs(20);
    while runtime::view(session)["exit"]["remote"] == "pending" && std::time::Instant::now() < until {
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert_eq!(runtime::view(session)["exit"]["remote"], expected);
}
#[test]
fn local_exit_is_immediate_for_success_401_and_timeout() {
    for mode in ["success", "401", "timeout"] {
        let server = Fixture::new();
        let (directory, session) = enrolled_fixture(&server);
        let before = service::read(&session).unwrap();
        super::access::initialize(&session, &before).unwrap();
        if mode == "401" { server.reject_exit.store(true, Ordering::SeqCst); }
        if mode == "timeout" { server.hold_group.store(true, Ordering::SeqCst); }
        let start = std::time::Instant::now();
        runtime::exit_local(&session, directory.clone(), true, true).unwrap();
        assert!(start.elapsed() < std::time::Duration::from_secs(1));
        let after = service::read(&session).unwrap();
        assert_ne!(after["device"], before["device"]);
        assert_eq!(after["token"], "");
        assert_eq!(after["group"], "");
        assert_eq!(after["paused"], true);
        assert_eq!(after["peers"], json!({}));
        assert!(after["groupState"].is_null());
        assert_eq!(service::core(&session, json!({"op":"relay-status"})).unwrap()["enabled"], false);
        runtime::start(session.clone(), directory.clone(), true).unwrap();
        wait_exit(&session, if mode == "success" { "confirmed" } else { "failed" });
        assert_eq!(service::read(&session).unwrap(), after);
        assert_eq!(server.connections.load(Ordering::SeqCst), 0);
        server.hold_group.store(false, Ordering::SeqCst);
        runtime::stop(&session);
        drop(session);
        std::fs::remove_dir_all(directory).unwrap();
    }
}
#[test]
fn in_flight_refresh_cannot_restore_a_locally_exited_group() {
    let server = Fixture::new();
    let (directory, session) = enrolled_fixture(&server);
    server.hold_group.store(true, Ordering::SeqCst);
    let task_session = session.clone();
    let task = std::thread::spawn(move || service::execute(&task_session, json!({"op":"refresh"}), true));
    for _ in 0..200 {
        if server.group_entered.load(Ordering::SeqCst) { break; }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(server.group_entered.load(Ordering::SeqCst));
    let start = std::time::Instant::now();
    runtime::exit_local(&session, directory.clone(), false, true).unwrap();
    assert!(start.elapsed() < std::time::Duration::from_secs(1));
    let after = service::read(&session).unwrap();
    server.hold_group.store(false, Ordering::SeqCst);
    assert_eq!(task.join().unwrap().unwrap_err(), "RelayIdentityChanged");
    wait_exit(&session, "confirmed");
    assert_eq!(service::read(&session).unwrap(), after);
    runtime::stop(&session);
    drop(session);
    std::fs::remove_dir_all(directory).unwrap();
}
#[cfg(target_os = "macos")]
#[test]
fn local_exit_write_failure_is_reported_and_retryable() {
    let server = Fixture::new();
    let (directory, session) = enrolled_fixture(&server);
    let before = service::read(&session).unwrap();
    let path = directory.join("vault/relay-private/credentials.v1.enc");
    assert!(std::process::Command::new("/usr/bin/chflags").arg("uchg").arg(&path).status().unwrap().success());
    let result = runtime::exit_local(&session, directory.clone(), false, true);
    assert!(std::process::Command::new("/usr/bin/chflags").arg("nouchg").arg(&path).status().unwrap().success());
    assert_eq!(result.unwrap_err(), "Storage");
    assert!(runtime::view(&session)["exit"].is_null());
    assert_eq!(service::read(&session).unwrap(), before);
    runtime::exit_local(&session, directory.clone(), false, true).unwrap();
    wait_exit(&session, "confirmed");
    runtime::stop(&session);
    drop(session);
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn remote_exit_and_admission_recovery_preserve_identity() {
    for op in ["leave", "disband"] {
        let server = Fixture::new();
        let directory = std::env::temp_dir().join(format!("pv-relay-exit-{}", uuid::Uuid::new_v4()));
        let session = Arc::new(vault_core::VaultSession::new(directory.to_string_lossy().into()).unwrap());
        service::core(&session, json!({"op":"create","password":TEST_PASSWORD})).unwrap();
        service::execute(&session, json!({"op":"create","endpoint":server.url,"relayPassword":RELAY_ACCESS,"name":"QA","deviceName":"Mac"}), true).unwrap();
        let original = service::read(&session).unwrap();
        let request = json!({"op":op});
        service::execute(&session, json!({"op":"update-password","relayPassword":"incorrect-access"}), true).unwrap();
        assert_eq!(service::execute(&session, request.clone(), true).unwrap_err(), "RelayHttp401");
        let failed = service::read(&session).unwrap();
        for key in ["device", "group", "token", "secret", "peers"] { assert_eq!(original[key], failed[key]); }
        assert_eq!(service::group(&original).unwrap()["group_entry"], service::group(&failed).unwrap()["group_entry"]);
        let handshake = transport::Connection::connect(&server.url, protocol::text(&failed, "token").unwrap(), Some("incorrect-access"), runtime::identity(&failed).unwrap(), true);
        assert_eq!(handshake.err().unwrap(), "RelayHttp401");
        runtime::start(session.clone(), directory.clone(), true).unwrap();
        for _ in 0..100 {
            if runtime::view(&session)["error"] == "RelayHttp401" { break; }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert_eq!(runtime::view(&session)["error"], "RelayHttp401");
        assert_eq!(runtime::view(&session)["transport"], "disconnected");
        let count = server.rejected.load(Ordering::SeqCst);
        runtime::start(session.clone(), directory.clone(), true).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1200));
        assert_eq!(server.rejected.load(Ordering::SeqCst), count);
        service::execute(&session, json!({"op":"update-password","relayPassword":RELAY_ACCESS}), true).unwrap();
        let corrected = service::read(&session).unwrap();
        assert_eq!(corrected["device"], original["device"]);
        assert_eq!(configured_password(&corrected).unwrap(), Some(RELAY_ACCESS));
        assert_eq!(configured_password(&service::group(&corrected).unwrap()).unwrap(), Some(RELAY_ACCESS));
        runtime::stop(&session);
        server.reject_exit.store(true, Ordering::SeqCst);
        assert_eq!(service::execute(&session, request.clone(), true).unwrap_err(), "RelayHttp401");
        let pending = service::group(&service::read(&session).unwrap()).unwrap()["pending_exit"].clone();
        assert!(pending.is_object());
        service::execute(&session, json!({"op":"update-password","relayPassword":RELAY_ACCESS}), true).unwrap();
        assert_eq!(service::group(&service::read(&session).unwrap()).unwrap()["pending_exit"], pending);
        server.reject_exit.store(false, Ordering::SeqCst);
        service::execute(&session, request, true).unwrap();
        let exited = service::read(&session).unwrap();
        assert_ne!(exited["device"], original["device"]);
        assert_eq!(exited["token"], "");
        assert!(service::group(&exited).unwrap().as_object().unwrap().is_empty());
        assert_eq!(service::core(&session, json!({"op":"status"})).unwrap()["unlocked"], true);
        drop(session);
        std::fs::remove_dir_all(directory).unwrap();
    }
}

#[test]
fn creation_retry_can_correct_admission_password_without_new_identity() {
    let server = Fixture::new();
    let directory = std::env::temp_dir().join(format!("pv-relay-retry-{}", uuid::Uuid::new_v4()));
    let session = vault_core::VaultSession::new(directory.to_string_lossy().into()).unwrap();
    service::core(&session, json!({"op":"create","password":TEST_PASSWORD})).unwrap();
    let mut request = json!({"op":"create","endpoint":server.url,"relayPassword":"incorrect-admission","name":"QA","deviceName":"Mac"});
    assert_eq!(service::execute(&session, request.clone(), true).unwrap_err(), "RelayHttp401");
    let before = service::group(&service::read(&session).unwrap()).unwrap();
    assert!(before["pending_create"].is_object());
    request["relayPassword"] = json!(RELAY_ACCESS);
    service::execute(&session, request, true).unwrap();
    let after = service::group(&service::read(&session).unwrap()).unwrap();
    assert_eq!(before["device"], after["device"]);
    assert_eq!(before["pending_create"], after["group_entry"]);
    assert!(after["pending_create"].is_null());
    drop(session);
    std::fs::remove_dir_all(directory).unwrap();
}
