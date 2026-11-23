//! End-to-end relay test against a real Common Relay server on loopback.
//! Runs when `COMMON_RELAY_BIN` points at a built (protocol v2) `common-relay` binary, and
//! also over `/relay/v1/ws` when `COMMON_RELAY_V1_BIN` points at a pre-v2-only build
//! (`bash tool/test_relay_live.sh` builds both from a local source tree); skipped otherwise.
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

#[test]
fn protocol_v1_groups_messages_files_and_exit() {
    match server("COMMON_RELAY_V1_BIN", "/relay/v1/ws") {
        Some(server) => run(&server),
        None => eprintln!("COMMON_RELAY_V1_BIN not set; skipping v1 live relay test"),
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
    let (a, state) = groups(&a, json!({"op":"refresh"})).unwrap();
    assert_eq!(state["state"]["members"].as_array().unwrap().len(), 2);

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

    // A message from a sender the receiver no longer trusts (e.g. a removed member) is
    // acknowledged and dropped; it must not fail the connection or be redelivered forever.
    ca.message(
        "phone".into(),
        b"stale".to_vec(),
        true,
        Some("fedcba9876543210fedcba9876543210".into()),
    )
    .unwrap();
    let untrusting =
        RelayConnection::connect(options(&b, &[], &journals.path().join("b"))).unwrap();
    std::thread::sleep(Duration::from_millis(1500));
    assert!(
        !untrusting.is_closed(),
        "an undecryptable message must not close the connection"
    );
    assert!(untrusting.peers().is_ok());
    untrusting.disconnect();
    let trusting =
        RelayConnection::connect(options(&b, &[&a], &journals.path().join("b2"))).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_millis(1500);
    while std::time::Instant::now() < deadline {
        if let Some(event) = trusting.next_event(100).unwrap() {
            let event: Value = serde_json::from_str(&event).unwrap();
            assert_ne!(
                event["type"], "message",
                "a dropped message must not be redelivered"
            );
        }
    }
    trusting.disconnect();
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
