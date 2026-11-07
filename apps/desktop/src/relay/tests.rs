use super::{protocol::*, transport::*, *};
fn vectors() -> Value {
    serde_json::from_str(include_str!(
        "../../../../vendor/common-relay/protocol/group-vectors.json"
    ))
    .unwrap()
}
#[test]
fn group_vectors_and_failure_paths() {
    sodiumoxide::init().unwrap();
    let v = vectors();
    let (derived, _) =
        signing(&unhex(v["config"]["secret_key"].as_str().unwrap()).unwrap()).unwrap();
    assert_eq!(
        hex(&derived.0),
        unpack(&v["initial"]).unwrap()["members"][0]["signing_key"]
    );
    for (old, next) in [
        ("initial", "approved"),
        ("approved", "removed"),
        ("approved", "left"),
        ("approved", "disbanded"),
        ("approved", "renamed"),
    ] {
        assert!(advance(&v[old], &v[next]).is_ok(), "{next}");
    }
    for key in ["unauthorized_disband", "unauthorized_rename"] {
        assert!(advance(&v["approved"], &v[key]).is_err(), "{key}");
    }
    assert!(advance(&v["initial"], &v["auto_admission"]["approved"]).is_ok());
    for case in v["auto_admission"]["invalid"].as_array().unwrap() {
        assert!(
            advance(&v["initial"], &case["entry"]).is_err(),
            "{}",
            case["case"]
        );
    }
    for case in v["strict_payload"]["valid"].as_array().unwrap() {
        assert!(
            advance(&v["approved"], &case["entry"]).is_ok(),
            "{}",
            case["case"]
        );
    }
    for case in v["strict_payload"]["invalid"].as_array().unwrap() {
        assert!(unpack(&case["entry"]).is_err(), "{}", case["case"]);
    }
    for case in v["strict_payload"]["invalid_auto"].as_array().unwrap() {
        assert!(
            advance(&v["initial"], &case["entry"]).is_err(),
            "{}",
            case["case"]
        );
    }
    let mut corrupt = v["approved"].clone();
    corrupt["signature"] = json!("00".repeat(64));
    assert!(advance(&v["initial"], &corrupt).is_err());
    assert!(advance(&v["approved"], &v["approved"]).is_err());
}
#[test]
fn invitation_vectors_and_tamper() {
    sodiumoxide::init().unwrap();
    let v: Value = serde_json::from_str(include_str!(
        "../../../../vendor/common-relay/protocol/invitation-link-vectors.json"
    ))
    .unwrap();
    let key = unhex(v["key"].as_str().unwrap()).unwrap();
    let (delegate, _) =
        signing(&unhex(v["invitation"]["delegate_secret"].as_str().unwrap()).unwrap()).unwrap();
    assert_eq!(
        hex(&delegate.0),
        unpack(&v["invitation"]["grant"]).unwrap()["delegate_key"]
    );
    let nonce = unhex(v["nonce"].as_str().unwrap()).unwrap();
    let packet = seal_invitation(&v["invitation"], &key, &nonce).unwrap();
    assert_eq!(
        open_invitation(v["packet"].as_str().unwrap(), &key).unwrap(),
        v["invitation"]
    );
    assert_eq!(open_invitation(&packet, &key).unwrap(), v["invitation"]);
    assert_eq!(read_token(&key).unwrap(), v["read_token"]);
    assert_eq!(make_link(&v["invitation"], &key, None).unwrap(), v["link"]);
    let (url, id, parsed, none) = parse_link(v["link"].as_str().unwrap()).unwrap();
    assert_eq!(url, v["invitation"]["url"]);
    assert_eq!(id, v["invitation"]["id"]);
    assert_eq!(key, parsed);
    assert_eq!(none, None);
    // The server access password may ride in the fragment as `#key.<base64url>`.
    let access = v["access_password"].as_str().unwrap();
    assert_eq!(make_link(&v["invitation"], &key, Some(access)).unwrap(), v["link_with_password"]);
    let (_, _, with_key, with) = parse_link(v["link_with_password"].as_str().unwrap()).unwrap();
    assert_eq!((with_key, with.as_deref()), (key.clone(), Some(access)));
    for suffix in v["invalid_link_suffixes"].as_array().unwrap() {
        let link = format!("{}{}", v["link"].as_str().unwrap(), suffix.as_str().unwrap());
        assert!(parse_link(&link).is_err(), "{link}");
    }
    assert!(open_invitation(&packet, &[0; 32]).is_err());
    assert!(parse_link("common-relay://user@host/i/abc#abc").is_err());
}
#[test]
fn envelope_context_and_transport_policy() {
    sodiumoxide::init().unwrap();
    let (ap, ask) = sodiumoxide::crypto::box_::gen_keypair();
    let (bp, bsk) = sodiumoxide::crypto::box_::gen_keypair();
    let a = Identity {
        app: "passwordvault".into(),
        group: "qa".into(),
        device: "a".into(),
        secret: ask,
        trusted: [("b".into(), bp)].into(),
    };
    let b = Identity {
        app: "passwordvault".into(),
        group: "qa".into(),
        device: "b".into(),
        secret: bsk,
        trusted: [("a".into(), ap)].into(),
    };
    let body = a
        .seal("b", "message", "id", json!({"data":"test"}))
        .unwrap();
    assert_eq!(b.open("a", "message", "id", &body).unwrap()["data"], "test");
    assert!(b.open("a", "message", "other", &body).is_err());
    assert!(b.open("a", "stream.open", "id", &body).is_err());
    assert!(b.open("unknown", "message", "id", &body).is_err());
    for url in [
        "ws://example.invalid/relay/v1/ws",
        "wss://user@example.invalid/relay/v1/ws",
        "wss://example.invalid/relay/v1/ws?token=x",
        "wss://example.invalid/other",
    ] {
        assert!(endpoint(url, false).is_err());
    }
    assert!(endpoint("ws://127.0.0.1:1234/relay/v1/ws", true).is_ok());
    assert!(endpoint("ws://127.0.0.1:1234/relay/v1/ws", false).is_err());
}
#[test]
fn local_websocket_welcome_and_identity_rejection() {
    use std::net::TcpListener;
    use tungstenite::{
        Message, accept_hdr,
        handshake::server::{Request, Response},
    };
    sodiumoxide::init().unwrap();
    for mismatch in [false, true] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (_, secret) = sodiumoxide::crypto::box_::gen_keypair();
        let public = hex(&secret.public_key().0);
        let server = std::thread::spawn(move || {
            let (socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(std::time::Duration::from_secs(3)))
                .unwrap();
            let mut socket = accept_hdr(socket, |req: &Request, mut response: Response| {
                assert_eq!(req.headers()["authorization"], "Bearer synthetic-token");
                assert_eq!(req.headers()["relay-access"], "synthetic-access");
                response
                    .headers_mut()
                    .insert("Sec-WebSocket-Protocol", "common-relay.v1".parse().unwrap());
                Ok(response)
            })
            .unwrap();
            socket.send(Message::Text(json!({"version":1,"identity":{"app":"passwordvault","group":"qa","device":if mismatch {"impostor"} else {"mac"},"public_key":public}}).to_string().into())).unwrap();
            let _ = socket.read();
        });
        let identity = Identity {
            app: "passwordvault".into(),
            group: "qa".into(),
            device: "mac".into(),
            secret,
            trusted: Default::default(),
        };
        let connected = Connection::connect(
            &format!("ws://{address}/relay/v1/ws"),
            "synthetic-token",
            Some("synthetic-access"),
            identity,
            true,
        );
        assert_eq!(connected.is_err(), mismatch);
        drop(connected);
        server.join().unwrap();
    }
}
#[test]
fn credentials_stay_encrypted_and_summary_is_lock_gated() {
    use base64::Engine;
    let directory = std::path::PathBuf::from("/tmp")
        .join(format!("pv-relay-credentials-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let session = vault_core::VaultSession::new(directory.to_string_lossy().into()).unwrap();
    session
        .command(json!({"op":"create","password":"synthetic-relay-test-password"}).to_string())
        .unwrap();
    let v = vectors();
    let config = json!({"device":"mac","secret":"synthetic-private-canary","token":"synthetic-token-canary","groupState":base64::engine::general_purpose::STANDARD.encode(json!({"secret_key":"synthetic-private-canary","group_entry":v["initial"]}).to_string())});
    session
        .command(json!({"op":"relay-credentials-write","data":config.to_string()}).to_string())
        .unwrap();
    let summary = read_summary(&session).unwrap();
    assert!(!summary.contains("canary"));
    assert!(!summary.contains("secret_key"));
    let disk = std::fs::read(directory.join("vault/relay-private/credentials.v1.enc")).unwrap();
    assert!(!String::from_utf8_lossy(&disk).contains("canary"));
    session.command(json!({"op":"lock"}).to_string()).unwrap();
    assert!(read_summary(&session).is_err());
    drop(session);
    std::fs::remove_dir_all(directory).unwrap();
}
