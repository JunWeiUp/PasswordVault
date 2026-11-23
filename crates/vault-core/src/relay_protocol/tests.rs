//! Shared common-relay vectors pin byte compatibility with the libsodium-based clients.
use super::*;

fn vectors(name: &str) -> Value {
    let raw = match name {
        "group" => include_str!("../../tests/fixtures/relay-protocol/group-vectors.json"),
        "invitation" => {
            include_str!("../../tests/fixtures/relay-protocol/invitation-link-vectors.json")
        }
        _ => include_str!("../../tests/fixtures/relay-protocol/crypto-vectors.json"),
    };
    serde_json::from_str(raw).unwrap()
}

#[test]
fn group_vectors_and_failure_paths() {
    let v = vectors("group");
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

/// Re-signing each vector payload must reproduce the libsodium signature byte for byte
/// (Ed25519 is deterministic), proving the dalek port derives the same keys and signatures.
#[test]
fn signatures_match_libsodium_vectors() {
    let v = vectors("group");
    let secret = unhex(v["config"]["secret_key"].as_str().unwrap()).unwrap();
    let device = v["config"]["device"].as_str().unwrap();
    let (_, SignSecretKey(key)) = signing(&secret).unwrap();
    let mut checked = 0;
    for (name, entry) in v.as_object().unwrap() {
        if entry["signer"] != device || entry.get("payload").is_none() {
            continue;
        }
        let bytes = payload(entry).unwrap();
        assert_eq!(
            hex(&key.sign(&bytes).to_bytes()),
            entry["signature"],
            "{name}"
        );
        checked += 1;
    }
    assert!(checked >= 3, "{checked}");
}

/// A member's signing_key can never be filled in or rotated in place (owner decision).
#[test]
fn signing_key_backfill_is_rejected() {
    let v = vectors("group");
    let secret = unhex(v["config"]["secret_key"].as_str().unwrap()).unwrap();
    let device = v["config"]["device"].as_str().unwrap();
    let (_, approved_state) = (0, unpack(&v["approved"]).unwrap());
    let mut next = approved_state.clone();
    next["revision"] = json!(approved_state["revision"].as_u64().unwrap() + 1);
    next["previous"] = json!(digest(&payload(&v["approved"]).unwrap()));
    next["invitation"] = json!("");
    next["request_hash"] = json!("");
    let target = next["members"]
        .as_array()
        .unwrap()
        .iter()
        .position(|m| m["device"] != device)
        .unwrap();
    next["members"][target]["signing_key"] = json!("11".repeat(32));
    let entry = sign_value(&next, &secret, device).unwrap();
    assert!(advance(&v["approved"], &entry).is_err());
    // The same transition limited to a rename is accepted.
    let mut renamed = next.clone();
    renamed["members"][target]["signing_key"] =
        approved_state["members"][target]["signing_key"].clone();
    renamed["members"][target]["name"] = json!("Renamed device");
    assert!(advance(
        &v["approved"],
        &sign_value(&renamed, &secret, device).unwrap()
    )
    .is_ok());
}

#[test]
fn invitation_vectors_and_tamper() {
    let v = vectors("invitation");
    let key = unhex(v["key"].as_str().unwrap()).unwrap();
    let (delegate, _) =
        signing(&unhex(v["invitation"]["delegate_secret"].as_str().unwrap()).unwrap()).unwrap();
    assert_eq!(
        hex(&delegate.0),
        unpack(&v["invitation"]["grant"]).unwrap()["delegate_key"]
    );
    let nonce = unhex(v["nonce"].as_str().unwrap()).unwrap();
    let packet = seal_invitation(&v["invitation"], &key, &nonce).unwrap();
    // Re-sealing the vector plaintext with the vector nonce reproduces the libsodium packet.
    let raw = STANDARD.decode(v["packet"].as_str().unwrap()).unwrap();
    let cipher = secretbox(&key).unwrap();
    let plain = cipher.decrypt(raw[..24].into(), &raw[24..]).unwrap();
    let mut again = nonce.clone();
    again.extend(
        cipher
            .encrypt(nonce.as_slice().into(), plain.as_slice())
            .unwrap(),
    );
    assert_eq!(STANDARD.encode(again), v["packet"]);
    assert_eq!(
        open_invitation(v["packet"].as_str().unwrap(), &key).unwrap(),
        v["invitation"]
    );
    assert_eq!(read_token(&key).unwrap(), v["read_token"]);
    assert_eq!(make_link(&v["invitation"], &key, None).unwrap(), v["link"]);
    let (url, id, parsed, none) = parse_link(v["link"].as_str().unwrap()).unwrap();
    assert_eq!(url, v["invitation"]["url"]);
    assert_eq!(id, v["invitation"]["id"]);
    assert_eq!(key, parsed);
    assert_eq!(none, None);
    let access = v["access_password"].as_str().unwrap();
    assert_eq!(
        make_link(&v["invitation"], &key, Some(access)).unwrap(),
        v["link_with_password"]
    );
    let (_, _, with_key, with) = parse_link(v["link_with_password"].as_str().unwrap()).unwrap();
    assert_eq!((with_key, with.as_deref()), (key.clone(), Some(access)));
    for suffix in v["invalid_link_suffixes"].as_array().unwrap() {
        let link = format!(
            "{}{}",
            v["link"].as_str().unwrap(),
            suffix.as_str().unwrap()
        );
        assert!(parse_link(&link).is_err(), "{link}");
    }
    assert!(open_invitation(&packet, &[0; 32]).is_err());
    assert!(parse_link("common-relay://user@host/i/abc#abc").is_err());
}

#[test]
fn envelope_opens_libsodium_vectors() {
    let v = vectors("crypto");
    let bob_secret =
        BoxSecretKey::from_slice(&unhex(v["bob_secret"].as_str().unwrap()).unwrap()).unwrap();
    assert_eq!(hex(&bob_secret.public_key().0), v["bob_public"]);
    let alice =
        BoxPublicKey::from_slice(&unhex(v["alice_public"].as_str().unwrap()).unwrap()).unwrap();
    let bob = Identity {
        app: v["app"].as_str().unwrap().into(),
        group: v["group"].as_str().unwrap().into(),
        device: "bob".into(),
        secret: bob_secret,
        trusted: [("alice".into(), alice)].into(),
    };
    let id = v["id"].as_str().unwrap();
    let plain = bob
        .open("alice", "message", id, v["message"].as_str().unwrap())
        .unwrap();
    assert_eq!(plain["data"], "aGVsbG8=");
    assert!(bob
        .open(
            "alice",
            "message",
            &"0".repeat(32),
            v["message"].as_str().unwrap()
        )
        .is_err());
    let offline = bob
        .open(
            "alice",
            "message",
            id,
            v["offline_message"].as_str().unwrap(),
        )
        .unwrap();
    assert_eq!(offline["expires"], v["offline_expires"]);
}

#[test]
fn envelope_context_and_transport_policy() {
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
    assert_eq!(
        b.open("unknown", "message", "id", &body).unwrap_err().0,
        "UntrustedPeer"
    );
    let mut tampered = STANDARD.decode(&body).unwrap();
    *tampered.last_mut().unwrap() ^= 1;
    assert_eq!(
        b.open("a", "message", "id", &STANDARD.encode(tampered))
            .unwrap_err()
            .0,
        "Authentication"
    );
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
    assert_eq!(
        access_password("short").unwrap_err().0,
        "RelayPasswordInvalid"
    );
}

fn run(request: Value) -> Result<Value> {
    command(&request)
}

#[test]
fn stateless_commands_cover_the_mobile_protocol_surface() {
    let v = vectors("group");
    let secret = v["config"]["secret_key"].as_str().unwrap();
    let keys = run(json!({"op":"relay-protocol-keys","secret":secret})).unwrap();
    assert_eq!(
        keys["signingKey"],
        unpack(&v["initial"]).unwrap()["members"][0]["signing_key"]
    );
    assert_eq!(keys["publicKey"], v["config"]["public_key"]);
    assert_eq!(
        run(json!({"op":"relay-protocol-advance","current":v["initial"],"entry":v["approved"]}))
            .unwrap()["entry"],
        v["approved"]
    );
    assert!(run(json!({"op":"relay-protocol-advance","current":v["approved"],"entry":v["unauthorized_rename"]})).is_err());
    let state =
        run(json!({"op":"relay-protocol-unpack","entry":v["approved"]})).unwrap()["state"].clone();
    let device = v["config"]["device"].as_str().unwrap();
    let signed =
        run(json!({"op":"relay-protocol-sign","value":state,"secret":secret,"device":device}))
            .unwrap()["entry"]
            .clone();
    assert!(
        run(json!({"op":"relay-protocol-verify","entry":signed,"key":keys["signingKey"]})).is_ok()
    );
    assert!(
        run(json!({"op":"relay-protocol-verify","entry":signed,"key":"00".repeat(32)})).is_err()
    );

    let inv = vectors("invitation");
    let key = inv["key"].as_str().unwrap();
    let packet = run(json!({"op":"relay-protocol-seal-invitation","invitation":inv["invitation"],"key":key,"nonce":inv["nonce"]})).unwrap()["packet"].clone();
    assert_eq!(
        run(json!({"op":"relay-protocol-open-invitation","packet":packet,"key":key})).unwrap()
            ["invitation"],
        inv["invitation"]
    );
    assert_eq!(
        run(json!({"op":"relay-protocol-read-token","key":key})).unwrap()["token"],
        inv["read_token"]
    );
    let link = run(json!({"op":"relay-protocol-make-link","invitation":inv["invitation"],"key":key,"password":inv["access_password"]})).unwrap()["link"].clone();
    assert_eq!(link, inv["link_with_password"]);
    let parsed = run(json!({"op":"relay-protocol-parse-link","link":link})).unwrap();
    assert_eq!(
        (
            parsed["url"].clone(),
            parsed["key"].clone(),
            parsed["password"].clone()
        ),
        (
            inv["invitation"]["url"].clone(),
            json!(key),
            inv["access_password"].clone()
        )
    );
    // Loopback relays are only accepted when a test explicitly allows them.
    let local = json!({"id":inv["invitation"]["id"],"url":"ws://127.0.0.1:8080/relay/v1/ws"});
    assert!(run(json!({"op":"relay-protocol-make-link","invitation":local,"key":key})).is_err());
    let local_link = run(
        json!({"op":"relay-protocol-make-link","invitation":local,"key":key,"allowLocal":true}),
    )
    .unwrap()["link"]
        .clone();
    assert_eq!(
        run(json!({"op":"relay-protocol-parse-link","link":local_link,"allowLocal":true})).unwrap()
            ["url"],
        local["url"]
    );
    assert_eq!(
        run(json!({"op":"relay-protocol-parse-link","link":local_link})).unwrap()["url"],
        "wss://127.0.0.1:8080/relay/v1/ws"
    );

    let (ap, ask) = box_keypair();
    let (bp, bsk) = box_keypair();
    let scope = json!({"app":"passwordvault","group":"qa"});
    let mut seal = json!({"op":"relay-protocol-envelope-seal","device":"a","secret":hex(&ask.0),"to":"b","peerKey":hex(&bp.0),"kind":"message","id":"m1","value":{"data":"hi"}});
    let mut open = json!({"op":"relay-protocol-envelope-open","device":"b","secret":hex(&bsk.0),"from":"a","peerKey":hex(&ap.0),"kind":"message","id":"m1"});
    for request in [&mut seal, &mut open] {
        request["app"] = scope["app"].clone();
        request["group"] = scope["group"].clone();
    }
    open["body"] = run(seal).unwrap()["body"].clone();
    assert_eq!(run(open.clone()).unwrap()["value"]["data"], "hi");
    let mut wrong = open.clone();
    wrong["id"] = json!("m2");
    assert_eq!(run(wrong).unwrap_err().0, "InvalidData");
    let mut forged = open;
    forged["peerKey"] = json!(hex(&box_keypair().0 .0));
    assert_eq!(run(forged).unwrap_err().0, "Authentication");
    assert!(run(json!({"op":"relay-protocol-unknown"})).is_err());
}

#[cfg(feature = "native")]
#[test]
fn session_serves_protocol_ops_without_unlocking() {
    let dir = tempfile::tempdir().unwrap();
    let session =
        crate::VaultSession::new(dir.path().join("vault").to_string_lossy().into()).unwrap();
    let v = vectors("group");
    let request = json!({"op":"relay-protocol-keys","secret":v["config"]["secret_key"]});
    let keys: Value = serde_json::from_str(&session.command(request.to_string()).unwrap()).unwrap();
    assert_eq!(keys["publicKey"], v["config"]["public_key"]);
    assert!(matches!(
        session.command(json!({"op":"relay-protocol-not-registered"}).to_string()),
        Err(crate::VaultError::Unsupported)
    ));
    // The session-free export used by the mobile clients behaves the same way.
    let free: Value =
        serde_json::from_str(&crate::relay_protocol(request.to_string()).unwrap()).unwrap();
    assert_eq!(free, keys);
    assert!(matches!(
        crate::relay_protocol(json!({"op":"status"}).to_string()),
        Err(crate::VaultError::Unsupported)
    ));
    assert!(matches!(
        session.command(
            json!({"op":"relay-protocol-verify","entry":v["approved"],"key":"00".repeat(32)})
                .to_string()
        ),
        Err(crate::VaultError::InvalidData)
    ));
}
