//! One cancellable relay owner per vault. Stop never waits for the network/control mutex.
use super::{
    Result, invalid,
    protocol::*,
    service,
    transport::{Connection, Identity},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    net::{Shutdown, TcpStream},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use vault_core::VaultSession;
pub struct Run {
    directory: std::path::PathBuf,
    stop: AtomicBool,
    pub socket: Mutex<Option<TcpStream>>,
    view: Mutex<Value>,
}
impl Run {
    pub fn stopped(&self) -> bool {
        self.stop.load(Ordering::SeqCst)
    }
    fn changed(&self) {
        if let Ok(mut v) = self.view.lock() {
            let n = v["updates"].as_u64().unwrap_or(0) + 1;
            v["updates"] = json!(n);
        }
    }
    fn set(&self, status: &str, online: Value, error: &str) {
        if let Ok(mut v) = self.view.lock() {
            let updates = v["updates"].clone();
            *v = json!({"transport":status,"online":online,"error":error,"updates":updates});
        }
    }
    pub fn disconnect(&self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Ok(mut socket) = self.socket.lock() {
            if let Some(socket) = socket.take() {
                let _ = socket.shutdown(Shutdown::Both);
            }
        }
        self.set("disconnected", json!([]), "");
    }
    fn wait(&self, duration: Duration) {
        let until = Instant::now() + duration;
        while !self.stopped() && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}
fn runs() -> &'static Mutex<HashMap<usize, Arc<Run>>> {
    static RUNS: OnceLock<Mutex<HashMap<usize, Arc<Run>>>> = OnceLock::new();
    RUNS.get_or_init(Default::default)
}
pub fn stop(s: &Arc<VaultSession>) {
    if let Ok(mut map) = runs().lock() {
        if let Some(run) = map.remove(&(Arc::as_ptr(s) as usize)) {
            run.disconnect();
        }
    }
}
pub fn view(s: &Arc<VaultSession>) -> Value {
    runs()
        .lock()
        .ok()
        .and_then(|m| m.get(&(Arc::as_ptr(s) as usize)).cloned())
        .and_then(|r| r.view.lock().ok().map(|v| v.clone()))
        .unwrap_or(json!({"transport":"disconnected","online":[]}))
}
pub fn exit_local(s: &Arc<VaultSession>, directory: std::path::PathBuf, disband: bool, local: bool) -> Result<String> {
    stop(s);
    let (display, remote) = service::exit_local(s)?;
    let notice = Arc::new(Run {
        directory, stop: AtomicBool::new(true), socket: Mutex::new(None),
        view: Mutex::new(json!({"transport":"disconnected","online":[],"exit":{"disband":disband,"remote":"pending"}})),
    });
    runs().lock().map_err(|_| "Storage")?.insert(Arc::as_ptr(s) as usize, notice.clone());
    // The worker owns only the old in-memory snapshot, never a vault/session or
    // persistence callback. It cannot restore membership, even after a late reply.
    std::thread::spawn(move || {
        let result = service::notify_exit(remote, disband, local);
        if let Ok(mut view) = notice.view.lock() {
            view["exit"]["remote"] = json!(if result.is_ok() { "confirmed" } else { "failed" });
        }
    });
    Ok(display)
}

pub fn authentication_failure(error: &str) -> bool {
    matches!(error, "RelayHttp401" | "RelayHttp403")
}
pub fn block_authentication(s: &Arc<VaultSession>, directory: std::path::PathBuf, error: &str) {
    let run = Arc::new(Run {
        directory, stop: AtomicBool::new(true), socket: Mutex::new(None),
        view: Mutex::new(json!({"transport":"disconnected","online":[],"error":error})),
    });
    if let Ok(mut map) = runs().lock() {
        let key = Arc::as_ptr(s) as usize;
        if map.get(&key).is_some_and(|r| r.view.lock().is_ok_and(|v| v["exit"].is_object())) { return; }
        map.insert(key, run);
    }
}
pub fn start(s: Arc<VaultSession>, directory: std::path::PathBuf, local: bool) -> Result<()> {
    if service::core(&s, json!({"op":"status"}))?["unlocked"] != true {
        return Err("Locked".into());
    }
    let mut map = runs().lock().map_err(|_| "Storage")?;
    let key = Arc::as_ptr(&s) as usize;
    // An automatic connect must not restart rejected credentials. Explicit actions
    // remove this entry through stop() before starting a new attempt.
    if map.get(&key).is_some_and(|r| !r.stopped() || r.view.lock().is_ok_and(|v| v["exit"].is_object() || authentication_failure(v["error"].as_str().unwrap_or("")))) {
        return Ok(());
    }
    let run = Arc::new(Run {
        directory,
        stop: AtomicBool::new(false),
        socket: Mutex::new(None),
        view: Mutex::new(json!({"transport":"disconnected","online":[]})),
    });
    map.insert(key, run.clone());
    std::thread::spawn(move || {
        let mut backoff = 1;
        while !run.stopped() {
            let result = connected(&s, &run, local);
            if run.stopped() {
                break;
            }
            match result {
                Err(ref e) if e == "Locked" || e == "NotEnrolled" || e == "GroupAccessRevoked" || authentication_failure(e) => {
                    run.set(
                        "disconnected",
                        json!([]),
                        if e == "NotEnrolled" { "" } else { e },
                    );
                    break;
                }
                Err(e) => run.set("reconnecting", json!([]), &e),
                Ok(()) => {
                    backoff = 1;
                }
            }
            if let Ok(mut slot) = run.socket.lock() {
                if let Some(socket) = slot.take() {
                    let _ = socket.shutdown(Shutdown::Both);
                }
            }
            run.wait(Duration::from_secs(backoff));
            backoff = (backoff * 2).min(30);
        }
        if let Ok(mut slot) = run.socket.lock() {
            if let Some(socket) = slot.take() { let _ = socket.shutdown(Shutdown::Both); }
        }
        run.stop.store(true, Ordering::SeqCst);
    });
    Ok(())
}
pub fn identity(c: &Value) -> Result<Identity> {
    let g = service::group(c)?;
    let raw = zeroize::Zeroizing::new(
        STANDARD
            .decode(text(c, "secret")?)
            .map_err(|_| "InvalidData")?,
    );
    let secret = sodiumoxide::crypto::box_::SecretKey::from_slice(&raw).ok_or("InvalidData")?;
    let mut trusted = BTreeMap::new();
    for (id, key) in g["trusted_peers"].as_object().ok_or("InvalidData")? {
        trusted.insert(
            id.clone(),
            sodiumoxide::crypto::box_::PublicKey::from_slice(&unhex(
                key.as_str().ok_or("InvalidData")?,
            )?)
            .ok_or("InvalidData")?,
        );
    }
    Ok(Identity {
        app: "passwordvault".into(),
        group: text(c, "group")?.into(),
        device: text(c, "device")?.into(),
        secret,
        trusted,
    })
}
fn delivery_signature(c: &Value, peer: &str, hash: &str, hour: u64) -> String {
    let grant = &c["vaultGrants"][peer];
    // A packet may arrive before the control grant and be discarded without an
    // application receipt. Re-issue it once the grant is applied, with a new ID.
    // Revision also prevents a revoke/regrant from reusing an old completed ID.
    format!("{hash}:{hour}:{}:{}:{}", grant["revision"], grant["acknowledged"], c["capabilityReady"][peer])
}
fn connected(s: &Arc<VaultSession>, run: &Run, local: bool) -> Result<()> {
    let c = service::read(s)?;
    if service::group(&c)?["group_entry"].is_null() {
        return Err("NotEnrolled".into());
    }
    service::execute(s, json!({"op":"refresh"}), local)?;
    super::journal::cleanup(s, &run.directory)?;
    let mut c = service::read(s)?;
    if run.stopped() {
        return Err("Locked".into());
    }
    run.set("connecting", json!([]), "");
    let mut connection = Connection::connect_controlled(
        text(&c, "endpoint")?,
        text(&c, "token")?,
        super::protocol::configured_password(&c)?,
        identity(&c)?,
        local,
        Some(run),
    )?;
    if run.stopped() {
        return Err("Locked".into());
    }
    connection.poll_timeout()?;
    run.set("connected", json!([]), "");
    let mut next = Instant::now();
    let mut peers_request = String::new();
    let mut peers_deadline = Instant::now();
    let mut sent = HashMap::<String, String>::new();
    let mut queue =
        std::collections::VecDeque::<(String, String, zeroize::Zeroizing<Vec<u8>>)>::new();
    let mut pending: Option<(String, Instant)> = None;
    while !run.stopped() {
        if Instant::now() >= next {
            if service::core(s, json!({"op":"status"}))?["unlocked"] != true {
                return Err("Locked".into());
            }
            let old_group = service::group(&c)?;
            service::execute(s, json!({"op":"refresh"}), local)?;
            c = service::read(s)?;
            if service::group(&c)?["group_entry"] != old_group["group_entry"] {
                return Ok(());
            }
            if peers_request.is_empty() {
                peers_request = uuid::Uuid::new_v4().simple().to_string();
                connection.send(json!({"type":"peers","id":peers_request}))?;
                peers_deadline = Instant::now() + Duration::from_secs(15);
            }
            for (peer, control) in super::access::pending(&c)? {
                connection.send_online(&peer, &canonical(&control))?;
            }
            for (peer, control) in super::access::capability_challenges(s, &c)? {
                connection.send_online(&peer, &canonical(&control))?;
            }
            if queue.is_empty()
                && pending.is_none()
                && c["paused"] != true
                && c["peers"].as_object().is_some_and(|p| !p.is_empty())
            {
                match super::sync::outgoing(s) {
                    Err(e) if e == "DevicesSyncBlocked" => {
                        if let Ok(mut view) = run.view.lock() {
                            view["error"] = json!(e);
                        }
                    }
                    Err(e) => return Err(e),
                    Ok(packets) => {
                        for (peer, library, data) in packets {
                            let data = zeroize::Zeroizing::new(data);
                            let route = format!("{peer}:{library}");
                            let hash = digest(&data);
                            let signature = delivery_signature(&c, &peer, &hash, super::groups::now() / 3600);
                            if sent.get(&route) == Some(&signature) {
                                continue;
                            }
                            let id =
                                digest(format!("{route}{signature}").as_bytes())[..32].to_string();
                            if data.len() <= 128 * 1024 {
                                queue.push_back((peer.clone(), id, data));
                            } else if !library.is_empty() {
                                if data.len() > 48 * 1024 * 1024 {
                                    return Err("RelayFileTooLarge".into());
                                }
                                let count = data.len().div_ceil(65536);
                                for (index, part) in data.chunks(65536).enumerate() {
                                    let id =
                                        digest(format!("{route}{signature}:{index}").as_bytes())
                                            [..32]
                                            .to_string();
                                    queue.push_back((peer.clone(),id,zeroize::Zeroizing::new(canonical(&json!({"protocol":"peer-v2-chunk","library":library,"transfer":&hash[..32],"index":index,"count":count,"total":data.len(),"digest":hash,"data":STANDARD.encode(part)})))));
                                }
                            } else {
                                let check = || {
                                    if run.stopped() {
                                        Err("Locked".into())
                                    } else {
                                        Ok(())
                                    }
                                };
                                let files = super::files::Files::new(
                                    text(&c, "endpoint")?,
                                    text(&c, "token")?,
                                    super::protocol::configured_password(&c)?,
                                    local,
                                    &check,
                                )?;
                                let (descriptor, cipher) =
                                    super::files::prepare(&connection.identity, &peer, &data)?;
                                files.upload(&descriptor, &cipher)?;
                            }
                            sent.insert(route, signature);
                        }
                        let check = || {
                            if run.stopped() {
                                Err("Locked".into())
                            } else {
                                Ok(())
                            }
                        };
                        let files = super::files::Files::new(
                            text(&c, "endpoint")?,
                            text(&c, "token")?,
                            super::protocol::configured_password(&c)?,
                            local,
                            &check,
                        )?;
                        for descriptor in files.inbox()? {
                            let from = text(&descriptor, "from")?;
                            let key = c["peers"][from].as_str().ok_or("VaultAccessDenied")?;
                            let cipher = files.download(&descriptor)?;
                            let plain = super::files::decrypt(
                                &connection.identity,
                                from,
                                &descriptor,
                                &cipher,
                            )?;
                            super::sync::receive(s, from, key, &plain)?;
                            files.acknowledge(text(&descriptor, "id")?)?;
                            run.changed();
                            sent.clear();
                        }
                    }
                }
            }
            next = Instant::now() + Duration::from_secs(5);
        }
        if !peers_request.is_empty() && Instant::now() > peers_deadline {
            return Err("RelayPresenceTimeout".into());
        }
        if pending
            .as_ref()
            .is_some_and(|(_, deadline)| Instant::now() > *deadline)
        {
            return Err("RelayMessageTimeout".into());
        }
        if pending.is_none() {
            if let Some((peer, id, data)) = queue.pop_front() {
                c = service::read(s)?;
                let key = connection
                    .identity
                    .trusted
                    .get(&peer)
                    .map(|k| hex(&k.0))
                    .ok_or("VaultAccessDenied")?;
                if c["paused"] == true || c["peers"][&peer] != key {
                    return Err("VaultAccessDenied".into());
                }
                if let Some(event) = super::journal::prepare(
                    s,
                    &run.directory,
                    &connection.identity,
                    &peer,
                    &id,
                    &data,
                )? {
                    connection.send(event)?;
                    pending = Some((id, Instant::now() + Duration::from_secs(45)));
                }
            }
        }
        match connection.read_wire() {
            Err(e) if e == "Timeout" => continue,
            Err(e) => return Err(e),
            Ok(event) => {
                if event["id"] == peers_request && event["type"] == "peers" {
                    let online: Vec<_> = event["devices"]
                        .as_array()
                        .ok_or("InvalidData")?
                        .iter()
                        .filter(|d| d["app"] == "passwordvault" && d["group"] == c["group"])
                        .filter_map(|d| d["device"].as_str().map(str::to_owned))
                        .collect();
                    run.set("connected", json!(online), "");
                    peers_request.clear();
                } else if event["type"] == "group.changed" {
                    return Ok(());
                } else if event["type"] == "received" {
                    let id = text(&event, "id")?;
                    super::journal::complete(s, &run.directory, id)?;
                    if pending.as_ref().is_some_and(|(p, _)| p == id) {
                        pending = None;
                    }
                } else if event["type"] == "error"
                    && pending.as_ref().is_some_and(|(p, _)| event["id"] == *p)
                {
                    return Err("RelayDeliveryRejected".into());
                } else if event["type"] == "queued" || event["type"] == "sent" {
                    if pending.as_ref().is_some_and(|(id, _)| event["id"] == *id) {
                        pending = None;
                    }
                } else if event["type"] == "message" {
                    let from = text(&event, "from")?;
                    let id = text(&event, "id")?;
                    let plain =
                        connection
                            .identity
                            .open(from, "message", id, text(&event, "body")?)?;
                    let key = connection
                        .identity
                        .trusted
                        .get(from)
                        .map(|k| hex(&k.0))
                        .ok_or("VaultAccessDenied")?;
                    let expired = plain["expires"]
                        .as_u64()
                        .is_some_and(|e| e <= super::groups::now());
                    if event["offline"] == true && !plain["expires"].is_u64() {
                        return invalid();
                    }
                    if !expired && !super::journal::seen(s, &run.directory, from, id)? {
                        let data = zeroize::Zeroizing::new(
                            STANDARD
                                .decode(text(&plain, "data")?)
                                .map_err(|_| "InvalidData")?,
                        );
                        let value: Value =
                            serde_json::from_slice(&data).map_err(|_| "InvalidData")?;
                        if value["format"] == super::access::FORMAT {
                            if let Some(reply) = super::access::receive(s, from, &key, &value)? {
                                connection.send_online(from, &canonical(&reply))?;
                            }
                            run.changed();
                        } else if value["format"] == super::access::CAPABILITIES_FORMAT {
                            if let Some(reply) = super::access::receive_capabilities(s, from, &key, &value)? {
                                connection.send_online(from, &canonical(&reply))?;
                            }
                            // A proof can release previously gated data without user action.
                            sent.clear();
                            run.changed();
                        } else {
                            match super::sync::receive(s, from, &key, &data) {
                                Ok(()) => {
                                    run.changed();
                                    sent.clear();
                                }
                                Err(e) if e == "DevicesSyncBlocked" => {
                                    if let Ok(mut view) = run.view.lock() {
                                        view["error"] = json!(e);
                                    }
                                    continue;
                                }
                                Err(e) => return Err(e),
                            }
                        }
                        super::journal::acknowledge(s, &run.directory, from, id)?;
                    }
                    connection.send(json!({"type":"ack","id":id,"from":from}))?;
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn data_delivery_retries_after_authorization_and_regrant() {
        let mut c = json!({"vaultGrants":{"phone":{"revision":1,"acknowledged":false}}});
        let before = delivery_signature(&c, "phone", "snapshot", 1);
        assert_eq!(before, delivery_signature(&c, "phone", "snapshot", 1));
        c["vaultGrants"]["phone"]["acknowledged"] = json!(true);
        let delivered = delivery_signature(&c, "phone", "snapshot", 1);
        assert_ne!(before, delivered, "data discarded before control needs a fresh delivery ID");
        c["vaultGrants"]["phone"]["revision"] = json!(3);
        assert_ne!(delivered, delivery_signature(&c, "phone", "snapshot", 1));
    }
    #[test]
    fn relay_stop_interrupts_socket_without_control_lock() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (mut server, _) = listener.accept().unwrap();
        server
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let r = Run {
            directory: "/tmp".into(),
            stop: AtomicBool::new(false),
            socket: Mutex::new(Some(client)),
            view: Mutex::new(json!({})),
        };
        let _control = service::CONTROL.lock().unwrap();
        r.disconnect();
        let mut byte = [0];
        assert_eq!(std::io::Read::read(&mut server, &mut byte).unwrap(), 0);
        assert!(r.stopped());
        assert_eq!(r.view.lock().unwrap()["transport"], "disconnected");
    }
}
