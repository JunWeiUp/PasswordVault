use super::*;
#[test]
fn policy_denies_wallets_unscoped_revoked_and_disabled() {
    let token = "test-only-token";
    let mut d = json!({"settings":{"aiAccessEnabled":true,"aiAccessScopes":{"accounts":true,"devices":true,"notes":true},"aiAccessClients":[{"id":"c","tokenHash":hash(token),"entries":{"a":true,"w":true}}]}});
    let a =
        json!({"id":"a","type":"password","title":"Account","password":"SECRET","username":"test"});
    assert!(allowed(&d, client(&d, token).unwrap(), &a));
    assert!(!projection(&a, true).to_string().contains("SECRET"));
    for t in ["crypto", "totp"] {
        assert!(!allowed(
            &d,
            client(&d, token).unwrap(),
            &json!({"id":"w","type":t})
        ));
    }
    for t in ["creditCard", "identity"] {
        assert!(!allowed(
            &d,
            client(&d, token).unwrap(),
            &json!({"id":"w","type":t})
        ));
    }
    assert!(!allowed(
        &d,
        client(&d, token).unwrap(),
        &json!({"id":"other","type":"password"})
    ));
    assert!(!approved_file(&d, client(&d, token).unwrap(), &a, "file"));
    d["settings"]["aiAccessScopes"]["accounts"] = json!(false);
    assert!(!allowed(&d, client(&d, token).unwrap(), &a));
    d["settings"]["aiAccessScopes"]["profiles"] = json!(true);
    d["settings"]["aiAccessClients"][0]["entries"]["profile"] = json!(true);
    let identity = json!({"id":"profile","type":"identity","title":"个人资料","identity":{"firstName":"Lin","phone":"SECRET_PHONE","address1":"SECRET_ADDRESS"}});
    assert!(allowed(&d, client(&d, token).unwrap(), &identity));
    let identity_projection = projection(&identity, true).to_string();
    assert!(identity_projection.contains("Lin"));
    assert!(!identity_projection.contains("SECRET_PHONE"));
    assert_eq!(secret(&identity, "phone").unwrap(), "SECRET_PHONE");
    let custom = json!({"id":"custom-item","type":"identity","title":"Custom","customFields":[
        {"id":"public","label":"会员号","kind":"text","value":"PV-2048"},
        {"id":"private","label":"门禁码","kind":"concealed","value":"SECRET_DOOR"}
    ]});
    let custom_projection = projection(&custom, true).to_string();
    assert!(custom_projection.contains("PV-2048"));
    assert!(!custom_projection.contains("SECRET_DOOR"));
    assert_eq!(secret(&custom, "custom:private").unwrap(), "SECRET_DOOR");
    assert!(secret(&custom, "custom:public").is_err());
    d["settings"]["aiAccessClients"] = json!([]);
    assert!(client(&d, token).is_err());
    d["settings"]["aiAccessEnabled"] = json!(false);
    assert_eq!(client(&d, token).unwrap_err(), "Disabled");
}
#[test]
fn locked_core_denies_all_operations() {
    let dir = std::env::temp_dir().join(format!("pv-ai-test-{}", id()));
    std::fs::create_dir_all(&dir).unwrap();
    let s = VaultSession::new(dir.to_string_lossy().into()).unwrap();
    for op in [
        "search_entries",
        "get_entry",
        "list_files",
        "read_file",
        "get_secret",
        "execute",
        "pair",
    ] {
        assert!(request(&s, json!({"op":op,"token":"test"})).is_err());
    }
    drop(s);
    std::fs::remove_dir_all(dir).unwrap();
}
#[test]
fn approval_deadline_and_denial_are_fail_closed() {
    let p = Pending {
        view: json!({}),
        expires: Instant::now() - Duration::from_secs(1),
        answer: Some(true),
        lease: None,
    };
    assert_eq!(
        approval_decision(&p).unwrap().unwrap_err(),
        "ApprovalTimeout"
    );
    let p = Pending {
        view: json!({}),
        expires: Instant::now() + Duration::from_secs(1),
        answer: Some(false),
        lease: None,
    };
    assert_eq!(
        approval_decision(&p).unwrap().unwrap_err(),
        "ApprovalDenied"
    );
    let p = Pending {
        view: json!({}),
        expires: Instant::now() + Duration::from_secs(1),
        answer: None,
        lease: None,
    };
    assert!(approval_decision(&p).is_none());
}
#[test]
fn encrypted_session_pair_grant_approval_revoke_and_audit() {
    let dir = std::env::temp_dir().join(format!("pv-ai-flow-{}", id()));
    std::fs::create_dir_all(&dir).unwrap();
    let s = Arc::new(VaultSession::new(dir.to_string_lossy().into()).unwrap());
    core(
        &s,
        json!({"op":"create","password":"synthetic-ai-test-password"}),
    )
    .unwrap();
    core(&s,json!({"op":"save","item":{"id":"ai-test-account","type":"password","title":"AI test account","username":"test","password":"test-only-sensitive-value","note":"","tags":[],"isDeleted":false}})).unwrap();
    assert_eq!(
        request(&s, json!({"op":"search_entries"})).unwrap_err(),
        "Disabled"
    );
    control(
        &s,
        json!({"op":"configure","aiAccessEnabled":true,"aiAccessScopes":{"accounts":true}}),
    )
    .unwrap();
    let code = control(&s, json!({"op":"pair","name":"test client"})).unwrap()["code"].clone();
    let pair = request(&s, json!({"op":"pair","code":code})).unwrap();
    let token = pair["token"].clone();
    let cid = pair["clientId"].clone();
    assert!(request(&s, json!({"op":"pair","code":code})).is_err());
    // An ungranted entry in an enabled scope asks the user; denying keeps it ungranted.
    let (session, t) = (s.clone(), token.clone());
    let worker = std::thread::spawn(move || {
        request(&session, json!({"op":"get_entry","id":"ai-test-account","token":t}))
    });
    let deadline = Instant::now() + Duration::from_secs(5);
    let rid = loop {
        if let Some(p) = state().pending.values().find(|p| p.view["kind"] == "grant") {
            break p.view["requestId"].clone();
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    };
    control(&s, json!({"op":"approve","requestId":rid,"allow":false})).unwrap();
    assert_eq!(worker.join().unwrap().unwrap_err(), "ApprovalDenied");
    // Unknown entries and disabled scopes still fail closed without asking.
    assert_eq!(
        request(&s, json!({"op":"get_entry","id":"missing","token":token})).unwrap_err(),
        "UnscopedOrMissing"
    );
    control(
        &s,
        json!({"op":"grant","clientId":cid,"entries":{"ai-test-account":true},"files":{}}),
    )
    .unwrap();
    assert!(
        !request(
            &s,
            json!({"op":"get_entry","id":"ai-test-account","token":token})
        )
        .unwrap()
        .to_string()
        .contains("test-only-sensitive-value")
    );
    assert_eq!(
        request(&s, json!({"op":"execute","token":token})).unwrap_err(),
        "ReadOnlyUnsupportedOperation"
    );
    core(&s,json!({"op":"save","richNotes":true,"item":{"id":"ai-test-note","type":"secureNote","title":"File owner","note":"","tags":[],"isDeleted":false}})).unwrap();
    let file: Value = serde_json::from_str(
        &s.import_note_attachment(
            "ai-test-note".into(),
            "ordinary.txt".into(),
            "text/plain".into(),
            "你好abc".as_bytes().to_vec(),
        )
        .unwrap(),
    )
    .unwrap();
    let fid = file["id"].as_str().unwrap();
    control(
        &s,
        json!({"op":"configure","aiAccessScopes":{"accounts":true,"notes":true}}),
    )
    .unwrap();
    control(&s,json!({"op":"grant","clientId":cid,"entries":{"ai-test-account":true,"ai-test-note":true},"files":{"ai-test-note":true,"ai-test-account":true}})).unwrap();
    assert_eq!(
        request(
            &s,
            json!({"op":"read_file","id":"ai-test-note","fileId":fid,"token":token})
        )
        .unwrap_err(),
        "UnclassifiedOrDeniedFile"
    );
    control(&s,json!({"op":"configure","aiAccessOrdinaryFiles":{"ai-test-note":{fid:true},"ai-test-account":{fid:true}}})).unwrap();
    assert_eq!(
        request(
            &s,
            json!({"op":"list_files","id":"ai-test-note","token":token})
        )
        .unwrap()[0]["id"],
        fid
    );
    let chunk=request(&s,json!({"op":"read_file","id":"ai-test-note","fileId":fid,"offset":1,"limit":2,"token":token})).unwrap();
    assert_eq!(chunk["text"], "好a");
    assert_eq!(chunk["nextOffset"], 3);
    assert_eq!(chunk["eof"], false);
    assert!(
        request(
            &s,
            json!({"op":"read_file","id":"ai-test-account","fileId":fid,"token":token})
        )
        .is_err()
    );
    for mode in ["deny", "allow", "timeout", "revoke"] {
        let (session, t) = (s.clone(), token.clone());
        let worker = std::thread::spawn(move || {
            request(
                &session,
                json!({"op":"get_secret","id":"ai-test-account","field":"password","token":t}),
            )
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        let rid = loop {
            if let Some(p) = state()
                .pending
                .values()
                .find(|p| p.view["item"] == "AI test account")
            {
                break p.view["requestId"].clone();
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        };
        match mode {
            "timeout" => {
                state()
                    .pending
                    .get_mut(rid.as_str().unwrap())
                    .unwrap()
                    .expires = Instant::now() - Duration::from_secs(1)
            }
            "revoke" => {
                control(&s, json!({"op":"revoke","clientId":cid})).unwrap();
            }
            _ => {
                control(
                    &s,
                    json!({"op":"approve","requestId":rid,"allow":mode=="allow"}),
                )
                .unwrap();
            }
        }
        let result = worker.join().unwrap();
        if mode == "allow" {
            // Default delivery is the clipboard: the value never reaches the client.
            let out = result.unwrap();
            assert_eq!(out["delivered"], "clipboard");
            assert!(!out.to_string().contains("test-only-sensitive-value"));
            assert_eq!(clipboard::LAST.lock().unwrap().take().as_deref(), Some("test-only-sensitive-value"));
        } else {
            assert_eq!(
                result.unwrap_err(),
                if mode == "timeout" {
                    "ApprovalTimeout"
                } else {
                    "ApprovalDenied"
                }
            )
        }
        assert!(control(&s, json!({"op":"approve","requestId":rid,"allow":true})).is_err());
    }
    // Revoked above: pair again for the convenience paths.
    let code = control(&s, json!({"op":"pair","name":"second client"})).unwrap()["code"].clone();
    let pair = request(&s, json!({"op":"pair","code":code})).unwrap();
    let (token, cid) = (pair["token"].clone(), pair["clientId"].clone());
    let answer = |body: Value| {
        let deadline = Instant::now() + Duration::from_secs(5);
        let rid = loop {
            if let Some(p) = state().pending.values().find(|p| p.view["item"] == "AI test account") {
                break p.view["requestId"].clone();
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        };
        let mut body = body;
        body["op"] = json!("approve");
        body["requestId"] = rid;
        control(&s, body)
    };
    let ask = |reveal: bool| {
        let (session, t) = (s.clone(), token.clone());
        std::thread::spawn(move || {
            let mut r = json!({"op":"get_secret","id":"ai-test-account","field":"password","token":t});
            if reveal { r["delivery"] = json!("reveal"); }
            request(&session, r)
        })
    };
    // An ungranted entry asks once and joins the client's list when approved.
    let worker = ask(true);
    answer(json!({"allow":true,"leaseSeconds":LEASE_SECONDS})).unwrap();
    let out = worker.join().unwrap().unwrap();
    assert_eq!(out["value"], "test-only-sensitive-value");
    assert_eq!(out["approval"], "leaseStarted");
    assert_eq!(doc(&s).unwrap()["settings"]["aiAccessClients"][0]["entries"]["ai-test-account"], true);
    // The lease answers repeat reads without a sheet; reveal leases also cover the clipboard.
    let out = request(&s, json!({"op":"get_secret","id":"ai-test-account","field":"password","token":token,"delivery":"reveal"})).unwrap();
    assert_eq!(out["approval"], "lease");
    let out = request(&s, json!({"op":"get_secret","id":"ai-test-account","field":"password","token":token})).unwrap();
    assert_eq!(out["delivered"], "clipboard");
    assert!(doc(&s).unwrap()["settings"]["aiAccessAudit"].to_string().contains("AllowedByLease"));
    assert_eq!(control(&s, json!({"op":"status"})).unwrap()["leases"].as_array().unwrap().len(), 1);
    // Ending leases (and locking) brings the approval sheet back; "until lock" is refused for passwords.
    control(&s, json!({"op":"end_leases"})).unwrap();
    let worker = ask(false);
    assert_eq!(answer(json!({"allow":true,"leaseSeconds":0})).unwrap_err(), "InvalidData");
    assert_eq!(answer(json!({"allow":true,"leaseSeconds":LEASE_SECONDS})).unwrap()["ok"], true);
    assert_eq!(worker.join().unwrap().unwrap()["approval"], "leaseStarted");
    // A clipboard-only lease does not cover a reveal request.
    let worker = ask(true);
    answer(json!({"allow":false})).unwrap();
    assert_eq!(worker.join().unwrap().unwrap_err(), "ApprovalDenied");
    Ai::cancel_pending();
    assert!(state().leases.is_empty());
    control(&s, json!({"op":"revoke","clientId":cid})).unwrap();
    assert_eq!(
        request(&s, json!({"op":"search_entries","token":token})).unwrap_err(),
        "RevokedOrUnknownClient"
    );
    let audit = doc(&s).unwrap()["settings"]["aiAccessAudit"].to_string();
    assert!(!audit.contains("test-only-sensitive-value"));
    assert!(!audit.contains(token.as_str().unwrap()));
    core(&s, json!({"op":"lock"})).unwrap();
    assert_eq!(
        request(&s, json!({"op":"search_entries","token":token})).unwrap_err(),
        "Locked"
    );
    drop(s);
    std::fs::remove_dir_all(dir).unwrap();
}
#[test]
fn device_projection_never_includes_unclassified_content() {
    let i = json!({"type":"device","id":"d","title":"Server","device":{"host":"example.invalid","password":"secret-password","privateKey":"secret-key","notes":"secret-notes","services":[{"id":"s","name":"web","path":"secret-node-link"}],"commands":[{"id":"1","text":"private-command"},{"id":"2","text":"ordinary-command","secret":false}]}});
    let out = projection(&i, true).to_string();
    for secret in [
        "secret-password",
        "secret-key",
        "secret-notes",
        "secret-node-link",
        "private-command",
    ] {
        assert!(!out.contains(secret));
    }
    assert!(out.contains("ordinary-command"));
    assert!(out.contains("example.invalid"));
    assert_eq!(secret(&i, "password").unwrap(), "secret-password");
    assert!(secret(&i, "device").is_err());
}

#[test]
fn account_website_strips_embedded_credentials() {
    let i = json!({"type":"password","id":"a","title":"A","url":"https://user:password@example.invalid/path?token=secret#private"});
    assert_eq!(projection(&i, true)["url"], "https://example.invalid/path");
    assert!(
        projection(
            &json!({"type":"password","url":"file:///private/file"}),
            true
        )
        .get("url")
        .is_none()
    );
}

#[test]
fn status_returns_only_policy_metadata_and_redacts_tokens() {
    let directory=std::path::PathBuf::from("/tmp").join(format!("pv-status-metadata-{}",id()));
    std::fs::create_dir_all(&directory).unwrap();
    let session=VaultSession::new(directory.to_string_lossy().into()).unwrap();
    core(&session,json!({"op":"create","password":"fixture"})).unwrap();
    core(&session,json!({"op":"save","item":{"id":"note","type":"secureNote","title":"unrelated-canary","note":"private-note-body".repeat(10000)}})).unwrap();
    save(&session,json!({"aiAccessEnabled":false,"aiAccessClients":[{"id":"fixture","tokenHash":"token-canary"}],"noteCategories":["category-canary"]})).unwrap();
    session.release_idle_document().unwrap();
    let value=control(&session,json!({"op":"status"})).unwrap();
    assert_eq!(value["settings"]["aiAccessEnabled"],false);
    let serialized=value.to_string();
    for canary in ["unrelated-canary","private-note-body","token-canary","category-canary"] {assert!(!serialized.contains(canary));}
    drop(session);std::fs::remove_dir_all(directory).unwrap();
}
