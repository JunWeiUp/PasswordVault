use super::{protocol::*, transport::*, *};
fn vectors() -> Value {
    serde_json::from_str(include_str!(
        "../../../../crates/vault-core/tests/fixtures/relay-protocol/group-vectors.json"
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
        "../../../../crates/vault-core/tests/fixtures/relay-protocol/invitation-link-vectors.json"
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
    let (ap, ask) = box_keypair();
    let (bp, bsk) = box_keypair();
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
        let (_, secret) = box_keypair();
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
    let session = crate::session::VaultSession::new(directory.to_string_lossy().into()).unwrap();
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
#[test]
fn local_v2_websocket_hello_presence_and_message_translation() {
    use std::net::TcpListener;
    use tungstenite::{
        Message, accept_hdr,
        handshake::server::{Request, Response},
    };
    sodiumoxide::init().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (_, secret) = box_keypair();
    let server = std::thread::spawn(move || {
        let (socket, _) = listener.accept().unwrap();
        socket
            .set_read_timeout(Some(std::time::Duration::from_secs(3)))
            .unwrap();
        let mut socket = accept_hdr(socket, |req: &Request, response: Response| {
            assert_eq!(req.headers()["authorization"], "Bearer synthetic-token");
            assert_eq!(req.headers()["relay-access"], "synthetic-access");
            assert!(req.headers().get("sec-websocket-protocol").is_none());
            Ok(response)
        })
        .unwrap();
        // Exact v2 server hello frame (from = device ID, no spaces array)
        socket
            .send(Message::Text(
                json!({"type":"hello","from":"mac"}).to_string().into(),
            ))
            .unwrap();
        // Receive translated presence query and answer with v2 presence event
        let raw = socket.read().unwrap();
        let req: Value = serde_json::from_str(raw.to_text().unwrap()).unwrap();
        assert_eq!(req["type"], "presence");
        assert_eq!(req["space"], "qa");
        let rid = req["id"].as_str().unwrap().to_owned();
        socket
            .send(Message::Text(
                json!({"type":"presence","space":"qa","id":rid,"peers":["mac","phone"]})
                    .to_string()
                    .into(),
            ))
            .unwrap();
        let _ = socket.read();
    });
    let identity = Identity {
        app: "passwordvault".into(),
        group: "qa".into(),
        device: "mac".into(),
        secret,
        trusted: Default::default(),
    };
    let mut conn = Connection::connect(
        &format!("ws://{address}/v2/ws"),
        "synthetic-token",
        Some("synthetic-access"),
        identity,
        true,
    )
    .unwrap();
    conn.send(json!({"type":"peers","id":"p1"})).unwrap();
    let ev = conn.read_wire().unwrap();
    assert_eq!(ev["type"], "peers");
    assert_eq!(ev["id"], "p1");
    assert_eq!(ev["devices"].as_array().unwrap().len(), 2);
    drop(conn);
    server.join().unwrap();
}
/// The core RustCrypto port must interoperate with libsodium clients in both directions.
#[test]
fn core_protocol_interoperates_with_libsodium() {
    use base64::{Engine, engine::general_purpose::STANDARD};
    use sodiumoxide::crypto::{box_, secretbox, sign};
    sodiumoxide::init().unwrap();
    // Envelope: core seals -> libsodium opens, libsodium seals -> core opens.
    let (sp, ss) = box_::gen_keypair();
    let (cp, cs) = box_keypair();
    let core = Identity {
        app: "passwordvault".into(),
        group: "qa".into(),
        device: "core".into(),
        secret: cs,
        trusted: [("sodium".into(), BoxPublicKey(sp.0))].into(),
    };
    let body = STANDARD
        .decode(
            core.seal("sodium", "message", "id", json!({"data":"x"}))
                .unwrap(),
        )
        .unwrap();
    let nonce = box_::Nonce::from_slice(&body[..24]).unwrap();
    let plain = box_::open(&body[24..], &nonce, &box_::PublicKey(cp.0), &ss).unwrap();
    let opened: Value = serde_json::from_slice(&plain).unwrap();
    assert_eq!(opened["value"]["data"], "x");
    assert_eq!(
        opened["context"],
        json!([1, "passwordvault", "qa", "core", "sodium", "message", "id"])
    );
    let reply = json!({"context":[1,"passwordvault","qa","sodium","core","message","id"],"value":{"data":"y"}});
    let nonce = box_::gen_nonce();
    let mut raw = nonce.0.to_vec();
    raw.extend(box_::seal(
        reply.to_string().as_bytes(),
        &nonce,
        &box_::PublicKey(cp.0),
        &ss,
    ));
    assert_eq!(
        core.open("sodium", "message", "id", &STANDARD.encode(raw))
            .unwrap()["data"],
        "y"
    );
    // Invitation secretbox: both directions.
    let key = secretbox::gen_key();
    let nonce = secretbox::gen_nonce();
    let invitation = json!({"id":"00".repeat(16),"url":"wss://relay.example/relay/v1/ws"});
    let packet = STANDARD
        .decode(seal_invitation(&invitation, &key.0, &nonce.0).unwrap())
        .unwrap();
    let plain = secretbox::open(&packet[24..], &nonce, &key).unwrap();
    assert_eq!(
        serde_json::from_slice::<Value>(&plain).unwrap()["invitation"],
        invitation
    );
    let mut sodium_packet = nonce.0.to_vec();
    sodium_packet.extend(secretbox::seal(&plain, &nonce, &key));
    assert_eq!(
        open_invitation(&STANDARD.encode(sodium_packet), &key.0).unwrap(),
        invitation
    );
    // Group signatures: core signs -> libsodium verifies with the derived public key.
    let secret = [7u8; 32];
    let (public, _) = signing(&secret).unwrap();
    let entry = sign_value(&json!({"version":1}), &secret, "core").unwrap();
    let sig =
        sign::Signature::from_bytes(&unhex(entry["signature"].as_str().unwrap()).unwrap()).unwrap();
    let pk = sign::PublicKey::from_slice(&public.0).unwrap();
    assert!(sign::verify_detached(&sig, &payload(&entry).unwrap(), &pk));
    let mut seed_input = b"common-relay/group-signing/v1\0".to_vec();
    seed_input.extend(secret);
    let seed =
        sign::Seed::from_slice(&sodiumoxide::crypto::hash::sha256::hash(&seed_input).0).unwrap();
    assert_eq!(sign::keypair_from_seed(&seed).0.0, public.0);
}
