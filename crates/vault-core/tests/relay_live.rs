//! End-to-end relay test against a real Common Relay server on loopback.
//! Runs when `COMMON_RELAY_BIN` points at a built `common-relay` binary (protocol v2;
//! `bash tool/test_relay_live.sh` builds one from a local source tree); skipped otherwise.
#![cfg(feature = "native")]
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    time::Duration,
};
use vault_core::relay_net::ffi::{
    relay_groups, RelayConnection, RelayError, RelayFileClient, RelayGroupStore,
};

const PASSWORD: &str = "fixture-relay-access";

struct Server {
    child: Child,
    url: String,
    _dir: tempfile::TempDir,
}
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn server(variable: &str, path: &str) -> Option<Server> {
    let bin = std::env::var(variable).ok()?;
    let dir = tempfile::tempdir().unwrap();
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let access = dir.path().join("access.sha256");
    std::fs::write(
        &access,
        format!("{}\n", hex::encode(Sha256::digest(PASSWORD.as_bytes()))),
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&access, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    let admin = dir.path().join("admin.sha256");
    std::fs::write(
        &admin,
        format!("{}\n", hex::encode(Sha256::digest(b"fixture-root-admin"))),
    )
    .unwrap();
    let mut command = Command::new(bin);
    if path == "/v2/ws" {
        command
            .arg("serve")
            .arg("--v2-admin-hash-file")
            .arg(&admin)
            .arg("--data");
    } else {
        command.args(["serve", "--data"]);
    }
    let child = command
        .arg(dir.path().join("data"))
        .args([
            "--listen",
            &format!("127.0.0.1:{port}"),
            "--self-service-apps",
            "passwordvault",
            "--access-password-file",
        ])
        .arg(&access)
        .args(["--disk-reserve", "0"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    for _ in 0..200 {
        if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return Some(Server {
                child,
                url: format!("ws://127.0.0.1:{port}{path}"),
                _dir: dir,
            });
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    let mut child = child;
    let _ = child.kill();
    let _ = child.wait();
    panic!("relay did not start");
}

#[derive(Default)]
struct Store(Mutex<Vec<String>>);
impl RelayGroupStore for Store {
    fn save(&self, config: String) -> Result<(), RelayError> {
        self.0.lock().unwrap().push(config);
        Ok(())
    }
}

fn groups(config: &Value, op: Value) -> Result<(Value, Value), RelayError> {
    let mut request = op;
    request["config"] = config.clone();
    request["allowLocal"] = json!(true);
    let reply: Value = serde_json::from_str(&relay_groups(
        request.to_string(),
        Arc::new(Store::default()),
    )?)
    .unwrap();
    Ok((reply["config"].clone(), reply["result"].clone()))
}

fn device(url: &str, name: &str) -> Value {
    let mut secret = [0u8; 32];
    getrandom::getrandom(&mut secret).unwrap();
    json!({"app":"passwordvault","url":url,"device":name,"secret_key":hex::encode(secret),"password":PASSWORD})
}

fn options(config: &Value, peers: &[&Value], journal: &std::path::Path) -> String {
    let mut trusted = serde_json::Map::new();
    for peer in peers {
        let member: Value = serde_json::from_str(
            &relay_groups(
                json!({"config":peer,"op":"member","name":""}).to_string(),
                Arc::new(Store::default()),
            )
            .unwrap(),
        )
        .unwrap();
        trusted.insert(
            peer["device"].as_str().unwrap().into(),
            member["result"]["public_key"].clone(),
        );
    }
    json!({"url":config["url"],"token":config["token"],"password":PASSWORD,"allowLocal":true,"journal":journal,
        "identity":{"app":"passwordvault","group":config["group"],"device":config["device"],"secret":config["secret_key"],"trusted":trusted}}).to_string()
}

fn next_message(c: &RelayConnection) -> Value {
    for _ in 0..100 {
        if let Some(event) = c.next_event(100).unwrap() {
            let event: Value = serde_json::from_str(&event).unwrap();
            if event["type"] == "message" {
                return event;
            }
        }
    }
    panic!("no message");
}

#[test]
fn protocol_v2_groups_messages_files_and_exit() {
    match server("COMMON_RELAY_BIN", "/v2/ws") {
        Some(server) => run(&server),
        None => eprintln!("COMMON_RELAY_BIN not set; skipping live relay test"),
    }
}

fn run(server: &Server) {
    let (a, _) = groups(
        &device(&server.url, "mac"),
        json!({"op":"create","name":"Home","deviceName":"Mac"}),
    )
    .unwrap();
    let (a, link) = groups(&a, json!({"op":"invite","mode":"auto"})).unwrap();
    let link = link.as_str().unwrap().to_owned();
    assert!(link.starts_with("common-relay://"));
    let b0 = device(&server.url, "phone");
    let (b0, invitation) = groups(&b0, json!({"op":"resolve","link":link})).unwrap();
    let (b, joined) = groups(
        &b0,
        json!({"op":"join","invitation":invitation,"name":"Phone"}),
    )
    .unwrap();
    assert_eq!(joined, true);
    assert!(
        a["issued_invitation"].is_object(),
        "the invitation is pending before the join"
    );
    let (a, state) = groups(&a, json!({"op":"refresh"})).unwrap();
    assert_eq!(state["state"]["members"].as_array().unwrap().len(), 2);
    // Once a device joined with it, the inviter's invitation retires on its own.
    assert!(a.get("issued_invitation").is_none() && a.get("pending_link").is_none());
    // The relay keeps the spent invitation (for the joiner's replay) but nobody else can use it.
    let late = device(&server.url, "late");
    let reused =
        groups(&late, json!({"op":"resolve","link":link})).and_then(|(late, invitation)| {
            groups(
                &late,
                json!({"op":"join","invitation":invitation,"name":"Late"}),
            )
        });
    assert!(
        reused.is_err(),
        "a spent invitation cannot admit another device"
    );

    let journals = tempfile::tempdir().unwrap();
    let ca = RelayConnection::connect(options(&a, &[&b], &journals.path().join("a"))).unwrap();
    let cb = RelayConnection::connect(options(&b, &[&a], &journals.path().join("b"))).unwrap();
    let peers: Value = serde_json::from_str(&ca.peers().unwrap()).unwrap();
    assert!(peers["devices"]
        .as_array()
        .unwrap()
        .iter()
        .any(|d| d["device"] == "phone"));

    let reply: Value = serde_json::from_str(
        &ca.message(
            "phone".into(),
            b"hello".to_vec(),
            true,
            Some("0123456789abcdef0123456789abcdef".into()),
        )
        .unwrap(),
    )
    .unwrap();
    assert!(
        matches!(
            reply["type"].as_str(),
            Some("stored" | "forwarded" | "received")
        ),
        "{reply}"
    );
    let event = next_message(&cb);
    assert_eq!(event["from"], "mac");
    assert_eq!(event["data"], "aGVsbG8=");
    cb.acknowledge(
        "mac".into(),
        event["id"].as_str().unwrap().into(),
        event["offline"] == true,
    )
    .unwrap();
    // Resending the same id after the receipt is served from the journal.
    let again: Value = serde_json::from_str(
        &ca.message(
            "phone".into(),
            b"hello".to_vec(),
            true,
            Some("0123456789abcdef0123456789abcdef".into()),
        )
        .unwrap(),
    )
    .unwrap();
    assert!(again["type"].is_string());

    let fa = RelayFileClient::new(options(&a, &[&b], journals.path())).unwrap();
    let fb = RelayFileClient::new(options(&b, &[&a], journals.path())).unwrap();
    let payload = vec![0x5a; 300_000];
    fa.send("phone".into(), payload.clone()).unwrap();
    let inbox: Vec<Value> = serde_json::from_str(&fb.inbox().unwrap()).unwrap();
    assert_eq!(inbox.len(), 1);
    assert_eq!(fb.receive(inbox[0].to_string()).unwrap(), payload);
    fb.acknowledge(inbox[0]["id"].as_str().unwrap().into())
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Vec<Value>>(&fb.inbox().unwrap())
            .unwrap()
            .len(),
        0
    );

    cb.disconnect();
    assert!(cb.is_closed());

    // A message from a sender this connection does not trust is surfaced (not fatal): the app
    // reconnects when the sender is in its current roster, or acknowledges it to drop it.
    ca.message(
        "phone".into(),
        b"stale".to_vec(),
        true,
        Some("fedcba9876543210fedcba9876543210".into()),
    )
    .unwrap();
    let untrusting =
        RelayConnection::connect(options(&b, &[], &journals.path().join("b"))).unwrap();
    let event = loop {
        let event: Value =
            serde_json::from_str(&untrusting.next_event(5000).unwrap().expect("event")).unwrap();
        if !matches!(
            event["type"].as_str(),
            Some("peer.up" | "peer.down" | "group.changed")
        ) {
            break event;
        }
    };
    assert_eq!(event["type"], "undecryptable");
    assert_eq!(event["from"], "mac");
    assert_eq!(event["trusted"], false);
    assert!(
        !untrusting.is_closed(),
        "an undecryptable message must not close the connection"
    );
    untrusting.disconnect();
    // Not acknowledged: a connection that trusts the sender receives it after reconnecting.
    let trusting =
        RelayConnection::connect(options(&b, &[&a], &journals.path().join("b2"))).unwrap();
    assert_eq!(next_message(&trusting)["data"], "c3RhbGU=");
    // Acknowledging an unwanted one drops it for good.
    trusting.disconnect();

    // The shared personal-sync session: a change on one vault reaches the other.
    ca.disconnect();
    mesh_sync_round_trip(&a, &b, journals.path());

    let (b, _) = groups(&b, json!({"op":"exit","disband":false})).unwrap();
    assert_eq!(b["exit_completed"], true);
    let (_a, state) = groups(&a, json!({"op":"refresh"})).unwrap();
    assert_eq!(state["state"]["members"].as_array().unwrap().len(), 1);

    // Wrong access password: the upgrade is rejected with 401, which the policy treats as stop.
    let mut wrong: Value = serde_json::from_str(&options(&a, &[], journals.path())).unwrap();
    wrong["password"] = json!("wrong-relay-access");
    let RelayError::Failed { code } = RelayConnection::connect(wrong.to_string()).err().unwrap();
    assert!(
        vault_core::relay_protocol::policy::authentication_failure(&code),
        "{code}"
    );
}

fn vault(dir: &std::path::Path) -> Arc<vault_core::VaultSession> {
    let vault = Arc::new(vault_core::VaultSession::new(dir.to_string_lossy().into()).unwrap());
    vault
        .command(json!({"op":"create","password":"Synthetic mesh fixture 24"}).to_string())
        .unwrap();
    vault
}

fn mesh_sync_round_trip(a: &Value, b: &Value, journals: &std::path::Path) {
    use vault_core::relay_net::ffi::RelayMeshSync;
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (va, vb) = (vault(da.path()), vault(db.path()));
    va.command(
        json!({"op":"save","item":{"id":"from-mac","type":"password","title":"Mac entry"}})
            .to_string(),
    )
    .unwrap();
    let sa = RelayMeshSync::connect(va.clone(), options(a, &[b], &journals.join("ma"))).unwrap();
    let sb = RelayMeshSync::connect(vb.clone(), options(b, &[a], &journals.join("mb"))).unwrap();
    let cycle: Value = serde_json::from_str(&sa.cycle(a.to_string(), false).unwrap()).unwrap();
    assert_eq!(cycle["peers"], json!(["phone"]));
    assert!(cycle["sent"].as_u64().unwrap() >= 1, "{cycle}");
    let titles = |v: &vault_core::VaultSession| -> Vec<String> {
        let list: Value =
            serde_json::from_str(&v.command(json!({"op":"list"}).to_string()).unwrap()).unwrap();
        list["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["title"].as_str().unwrap_or("").to_owned())
            .collect()
    };
    let mut changed = false;
    for _ in 0..20 {
        sb.cycle(b.to_string(), false).unwrap();
        let pumped: Value = serde_json::from_str(&sb.pump(500).unwrap()).unwrap();
        assert!(pumped["reconnect"].is_null(), "{pumped}");
        changed |= pumped["changed"] == true;
        if titles(&vb).contains(&"Mac entry".to_owned()) {
            break;
        }
    }
    assert!(changed && titles(&vb).contains(&"Mac entry".to_owned()));
    // And back: an edit on the phone reaches the Mac.
    vb.command(
        json!({"op":"save","item":{"id":"from-phone","type":"password","title":"Phone entry"}})
            .to_string(),
    )
    .unwrap();
    for _ in 0..20 {
        sb.cycle(b.to_string(), false).unwrap();
        sa.cycle(a.to_string(), false).unwrap();
        sa.pump(500).unwrap();
        if titles(&va).contains(&"Phone entry".to_owned()) {
            break;
        }
    }
    assert!(titles(&va).contains(&"Phone entry".to_owned()));
    sa.disconnect();
    sb.disconnect();
    assert!(sa.is_closed() && sb.is_closed());
}
