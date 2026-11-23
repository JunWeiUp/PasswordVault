//! Shared common-relay vectors pin byte compatibility with the libsodium-based clients.
use super::*;

fn vectors(name: &str) -> Value {
    let raw = match name {
        "group" => include_str!("../../../../vendor/common-relay/protocol/group-vectors.json"),
        "invitation" => {
            include_str!("../../../../vendor/common-relay/protocol/invitation-link-vectors.json")
        }
        _ => include_str!("../../../../vendor/common-relay/protocol/crypto-vectors.json"),
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
