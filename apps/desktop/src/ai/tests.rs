use super::*;
/// Approval state is process-global; flows that wait on it must not run concurrently.
static FLOW: Mutex<()> = Mutex::new(());
#[test]
fn policy_denies_wallets_unscoped_excluded_revoked_and_disabled() {
    let token = "test-only-token";
    let mut d = json!({"settings":{"aiAccessEnabled":true,"aiAccessScopes":{"accounts":true,"devices":true,"notes":true},"aiAccessExcludedEntries":{"hidden-acc":true},"aiAccessClients":[{"id":"c","tokenHash":hash(token),"entries":{}}]}});
    let a = json!({"id":"a","type":"password","title":"Account","password":"SECRET","username":"test","note":"ordinary note"});
    assert!(allowed(&d, client(&d, token).unwrap(), &a));
    let proj = projection(&a, true).to_string();
    assert!(!proj.contains("SECRET"));
    assert!(proj.contains("ordinary note"));
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
    // Option A: enabled scope allows any non-excluded item without per-entry whitelisting,
    // while explicitly excluded entries remain hidden.
    assert!(allowed(
        &d,
        client(&d, token).unwrap(),
        &json!({"id":"other","type":"password"})
    ));
    assert!(!allowed(
        &d,
        client(&d, token).unwrap(),
        &json!({"id":"hidden-acc","type":"password"})
    ));
    assert!(!approved_file(&d, client(&d, token).unwrap(), &a, "file"));
    d["settings"]["aiAccessScopes"]["accounts"] = json!(false);
    assert!(!allowed(&d, client(&d, token).unwrap(), &a));
    d["settings"]["aiAccessScopes"]["profiles"] = json!(true);
    let identity = json!({"id":"profile","type":"identity","title":"个人资料","identity":{"firstName":"Lin","phone":"13800138000","address1":"Beijing"}});
    assert!(allowed(&d, client(&d, token).unwrap(), &identity));
    let identity_projection = projection(&identity, true).to_string();
    assert!(identity_projection.contains("Lin"));
    assert!(identity_projection.contains("13800138000"));
    assert!(identity_projection.contains("Beijing"));
    let card = json!({"id":"card-1","type":"creditCard","title":"Visa","card":{"brand":"Visa","cardholder":"Lin","number":"4111222233334444","securityCode":"999"}});
    let card_projection = projection(&card, true).to_string();
    assert!(card_projection.contains("Visa"));
    assert!(!card_projection.contains("4111222233334444"));
    assert!(!card_projection.contains("999"));
    assert_eq!(secret(&card, "number").unwrap(), "4111222233334444");
    assert_eq!(secret(&card, "securityCode").unwrap(), "999");
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
    for op in ["search", "get", "get_secret", "ask_user", "execute"] {
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
        created: None,
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
        created: None,
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
        created: None,
    };
    assert!(approval_decision(&p).is_none());
}
#[test]
fn encrypted_session_pair_grant_approval_revoke_and_audit() {
    let _flow = FLOW.lock().unwrap_or_else(|e| e.into_inner());
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
        request(&s, json!({"op":"search"})).unwrap_err(),
        "Disabled"
    );
    control(
        &s,
        json!({"op":"configure","aiAccessEnabled":true,"aiAccessScopes":{"accounts":true}}),
    )
    .unwrap();
    let pair = control(&s, json!({"op":"pair","name":"test client"})).unwrap();
    let token = pair["token"].clone();
    let cid = pair["clientId"].clone();
    // Pairing is a UI-only control operation; the socket never accepts it.
    assert_eq!(request(&s, json!({"op":"pair","token":token})).unwrap_err(), "ReadOnlyUnsupportedOperation");
    // Option A: enabled scope allows search & non-secret get directly without per-entry whitelisting,
    // while passwords are never leaked and missing entries fail closed.
    let found = request(&s, json!({"op":"search","query":"AI test","token":token})).unwrap();
    assert_eq!(found.as_array().unwrap().len(), 1);
    assert_eq!(
        request(&s, json!({"op":"get","id":"missing","token":token})).unwrap_err(),
        "UnscopedOrMissing"
    );
    assert!(
        !request(
            &s,
            json!({"op":"get","id":"ai-test-account","token":token})
        )
        .unwrap()
        .to_string()
        .contains("test-only-sensitive-value")
    );
    // Explicitly excluding an entry hides it from search and get.
    control(&s, json!({"op":"configure","aiAccessExcludedEntries":{"ai-test-account":true}})).unwrap();
    assert_eq!(
        request(&s, json!({"op":"get","id":"ai-test-account","token":token})).unwrap_err(),
        "UnscopedOrMissing"
    );
    control(&s, json!({"op":"configure","aiAccessExcludedEntries":{}})).unwrap();
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
    assert_eq!(
        request(
            &s,
            json!({"op":"get","id":"ai-test-note","fileId":fid,"token":token})
        )
        .unwrap_err(),
        "UnclassifiedOrDeniedFile"
    );
    control(&s,json!({"op":"configure","aiAccessOrdinaryFiles":{"ai-test-note":{fid:true},"ai-test-account":{fid:true}}})).unwrap();
    assert_eq!(
        request(&s, json!({"op":"get","id":"ai-test-note","token":token})).unwrap()["files"][0],
        fid
    );
    let chunk=request(&s,json!({"op":"get","id":"ai-test-note","fileId":fid,"offset":1,"limit":2,"token":token})).unwrap();
    assert_eq!(chunk["text"], "好a");
    assert_eq!(chunk["nextOffset"], 3);
    assert_eq!(chunk["eof"], false);
    assert!(
        request(
            &s,
            json!({"op":"get","id":"ai-test-account","fileId":fid,"token":token})
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
    let pair = control(&s, json!({"op":"pair","name":"second client"})).unwrap();
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
    // Password request asks the user and can start a bounded lease when approved.
    let worker = ask(true);
    answer(json!({"allow":true,"leaseSeconds":LEASE_SECONDS})).unwrap();
    let out = worker.join().unwrap().unwrap();
    assert_eq!(out["value"], "test-only-sensitive-value");
    assert_eq!(out["approval"], "leaseStarted");
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
        request(&s, json!({"op":"search","token":token})).unwrap_err(),
        "RevokedOrUnknownClient"
    );
    let audit = doc(&s).unwrap()["settings"]["aiAccessAudit"].to_string();
    assert!(!audit.contains("test-only-sensitive-value"));
    assert!(!audit.contains(token.as_str().unwrap()));
    core(&s, json!({"op":"lock"})).unwrap();
    assert_eq!(
        request(&s, json!({"op":"search","token":token})).unwrap_err(),
        "Locked"
    );
    drop(s);
    std::fs::remove_dir_all(dir).unwrap();
}
#[test]
fn device_projection_protects_secrets_and_shows_ordinary_metadata() {
    let i = json!({"type":"device","id":"d","title":"Server","device":{"host":"example.invalid","password":"secret-password","privateKey":"secret-key","notes":"plain-notes","services":[{"id":"s","name":"web","path":"/admin"}],"commands":[{"id":"1","text":"private-command"},{"id":"2","text":"ordinary-command","secret":false}]}});
    let out = projection(&i, true).to_string();
    for secret in [
        "secret-password",
        "secret-key",
        "private-command",
    ] {
        assert!(!out.contains(secret));
    }
    assert!(out.contains("ordinary-command"));
    assert!(out.contains("example.invalid"));
    assert!(out.contains("plain-notes"));
    assert!(out.contains("/admin"));
    assert_eq!(secret(&i, "password").unwrap(), "secret-password");
    assert!(secret(&i, "device").is_err());
    // Passwords, private keys and private commands are released only through get_secret.
    assert_eq!(secret(&i, "command:1").unwrap(), "private-command");
    assert!(secret(&i, "command:2").is_err());
    let fields = projection(&i, true)["secretFields"].to_string();
    for f in ["command:1", "privateKey"] {
        assert!(fields.contains(f), "{f} missing from {fields}");
    }
    assert!(!fields.contains("command:2"));
}

#[test]
fn summaries_and_details_stay_compact() {
    let account = json!({"id":"a","type":"password","title":"GitHub","username":"octo","url":"","tags":[],
        "customFields":[{"id":"c1","label":"会员号","kind":"text","value":"PV-2048"},{"id":"c2","label":"PIN","kind":"concealed","value":"SECRET_PIN"}]});
    let summary = projection(&account, false);
    assert_eq!(summary, json!({"id":"a","type":"password","title":"GitHub","sub":"octo"}));
    let detail = projection(&account, true);
    assert!(detail.get("url").is_none(), "empty values are dropped");
    assert_eq!(detail["fields"], json!([{"label":"会员号","value":"PV-2048"}]));
    assert_eq!(detail["secretFields"], json!([{"field":"custom:c2","label":"PIN"}]));
    assert!(!detail.to_string().contains("SECRET_PIN"));
    assert!(!detail.to_string().contains("dataOnly"));
    let note = json!({"id":"n","type":"secureNote","title":"N","note":"plain body","noteFormat":"rich-v1",
        "noteDocument":{"type":"doc","content":[]}});
    let detail = projection(&note, true);
    assert_eq!(detail["note"], "plain body");
    assert!(detail.get("noteDocument").is_none());
}

#[test]
fn ask_user_saves_a_new_account_and_grants_it() {
    let _flow = FLOW.lock().unwrap_or_else(|e| e.into_inner());
    let dir = std::env::temp_dir().join(format!("pv-ai-ask-{}", id()));
    std::fs::create_dir_all(&dir).unwrap();
    let s = Arc::new(VaultSession::new(dir.to_string_lossy().into()).unwrap());
    core(&s, json!({"op":"create","password":"ask-user fixture"})).unwrap();
    control(&s, json!({"op":"configure","aiAccessEnabled":true,"aiAccessScopes":{"notes":true}})).unwrap();
    let token = control(&s, json!({"op":"pair","name":"ask client"})).unwrap()["token"].clone();
    // Without the accounts scope, the request fails closed without a sheet.
    assert_eq!(request(&s, json!({"op":"ask_user","title":"Shop","token":token})).unwrap_err(), "UnscopedOrMissing");
    control(&s, json!({"op":"configure","aiAccessScopes":{"accounts":true}})).unwrap();
    let wait = || {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(p) = state().pending.values().find(|p| p.view["kind"] == "create") {
                break p.view.clone();
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
    };
    let ask = |reveal: bool| {
        let (session, t) = (s.clone(), token.clone());
        std::thread::spawn(move || {
            let mut r = json!({"op":"ask_user","title":"Shop","url":"https://shop.example","username":"me","purpose":"登录","token":t});
            if reveal { r["delivery"] = json!("reveal"); }
            request(&session, r)
        })
    };
    // Cancel: nothing is saved or granted.
    let worker = ask(true);
    let view = wait();
    assert_eq!(view["item"], "Shop");
    assert_eq!(view["url"], "https://shop.example");
    control(&s, json!({"op":"approve","requestId":view["requestId"],"allow":false})).unwrap();
    assert_eq!(worker.join().unwrap().unwrap_err(), "ApprovalDenied");
    // Allow without a saved entry is refused.
    let worker = ask(true);
    let view = wait();
    assert_eq!(control(&s, json!({"op":"approve","requestId":view["requestId"],"allow":true})).unwrap_err(), "InvalidData");
    // The UI saves the account, then approves with its id.
    core(&s, json!({"op":"save","item":{"id":"new-shop","type":"password","title":"Shop","username":"me","password":"typed-by-user","url":"https://shop.example","note":"","tags":[],"isDeleted":false}})).unwrap();
    control(&s, json!({"op":"approve","requestId":view["requestId"],"allow":true,"entryId":"new-shop"})).unwrap();
    let out = worker.join().unwrap().unwrap();
    assert_eq!(out["id"], "new-shop");
    assert_eq!(out["password"], "typed-by-user");
    let d = doc(&s).unwrap();
    assert_eq!(d["settings"]["aiAccessClients"][0]["entries"]["new-shop"], true);
    assert!(!d["settings"]["aiAccessAudit"].to_string().contains("typed-by-user"));
    drop(s);
    std::fs::remove_dir_all(dir).unwrap();
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

#[test]
fn add_saves_new_entries_without_approval_and_never_touches_existing_ones() {
    let _flow = FLOW.lock().unwrap_or_else(|e| e.into_inner());
    let dir = std::env::temp_dir().join(format!("pv-ai-add-{}", id()));
    std::fs::create_dir_all(&dir).unwrap();
    let s = Arc::new(VaultSession::new(dir.to_string_lossy().into()).unwrap());
    core(&s, json!({"op":"create","password":"add fixture"})).unwrap();
    core(&s, json!({"op":"save","item":{"id":"keep","type":"password","title":"Keep","username":"old","note":"","tags":[],"isDeleted":false}})).unwrap();
    // Unknown clients cannot write, even with AI access disabled.
    assert!(request(&s, json!({"op":"add","type":"account","title":"X","token":"nope"})).is_err());
    control(&s, json!({"op":"configure","aiAccessEnabled":true})).unwrap();
    let token = control(&s, json!({"op":"pair","name":"add client"})).unwrap()["token"].clone();
    let before = state().changes;
    // No scope or approval is needed; a supplied id cannot overwrite an existing record.
    let out = request(&s, json!({"op":"add","type":"account","title":"Selkies","id":"keep","username":"admin","password":"basic-auth-value","url":"https://selkies.example","token":token})).unwrap();
    assert_eq!(out["added"], true);
    assert_ne!(out["id"], "keep");
    assert!(state().changes > before);
    let d = doc(&s).unwrap();
    let keep = d["items"].as_array().unwrap().iter().find(|i| i["id"] == "keep").unwrap();
    assert_eq!(keep["username"], "old");
    let added = d["items"].as_array().unwrap().iter().find(|i| i["id"] == out["id"]).unwrap();
    assert_eq!(added["password"], "basic-auth-value");
    assert_eq!(added["url"], "https://selkies.example");
    assert_eq!(d["settings"]["aiAccessClients"][0]["entries"][out["id"].as_str().unwrap()], true);
    assert!(!d["settings"]["aiAccessAudit"].to_string().contains("basic-auth-value"));
    assert!(d["settings"]["aiAccessAudit"].to_string().contains("\"add\""));
    // Other types keep only whitelisted fields.
    let note = request(&s, json!({"op":"add","type":"note","title":"部署说明","note":"步骤 1","token":token})).unwrap();
    let card = request(&s, json!({"op":"add","type":"card","title":"Card","card":{"number":"4111","evil":"x"},"token":token})).unwrap();
    let d = doc(&s).unwrap();
    let find = |id: &Value| d["items"].as_array().unwrap().iter().find(|i| &i["id"] == id).unwrap().clone();
    assert_eq!(find(&note["id"])["type"], "secureNote");
    assert_eq!(find(&note["id"])["note"], "步骤 1");
    assert_eq!(find(&card["id"])["card"], json!({"number":"4111"}));
    assert_eq!(request(&s, json!({"op":"add","type":"crypto","title":"W","token":token})).unwrap_err(), "UnsupportedType");
    assert_eq!(request(&s, json!({"op":"add","type":"account","title":" ","token":token})).unwrap_err(), "MissingTitle");
    assert_eq!(request(&s, json!({"op":"add","type":"totp","title":"T","token":token})).unwrap_err(), "MissingSecret");
    let device = request(&s, json!({"op":"add","type":"device","title":"Box","device":{"host":"10.0.0.2"},"token":token}));
    let device_ok = device.is_ok();
    if core(&s, json!({"op":"devices-status"})).unwrap()["enabled"] != true {
        assert_eq!(device.unwrap_err(), "DevicesNotEnabled");
    }
    // The eleventh write within a minute is refused and nothing more is saved.
    let saved = |s: &VaultSession| doc(s).unwrap()["items"].as_array().unwrap().len();
    let mut ok = 3 + usize::from(device_ok);
    while ok < ADD_LIMIT {
        request(&s, json!({"op":"add","type":"note","title":format!("n{ok}"),"token":token})).unwrap();
        ok += 1;
    }
    let count = saved(&s);
    assert_eq!(request(&s, json!({"op":"add","type":"note","title":"burst","token":token})).unwrap_err(), "RateLimited");
    assert_eq!(saved(&s), count);
    state().adds.clear();
    core(&s, json!({"op":"lock"})).unwrap();
    assert_eq!(request(&s, json!({"op":"add","type":"account","title":"Late","token":token})).unwrap_err(), "Locked");
    drop(s);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn new_device_entries_keep_commands_private_by_default() {
    let item = new_item(&json!({"type":"device","title":"Box","device":{"host":"h","privateKey":"k","services":[{"name":"web","kind":"browser","remotePort":8080,"path":"/x"}],"commands":[{"title":"start","text":"run"},{"title":"ls","text":"ls","secret":false}]}})).unwrap();
    let d = &item["device"];
    assert_eq!(d["authMethod"], "key");
    assert_eq!(d["port"], 22);
    assert_eq!(d["services"][0]["localPort"], 8080);
    assert_eq!(d["commands"][0]["secret"], true);
    assert_eq!(d["commands"][1]["secret"], false);
}

#[test]
fn add_is_limited_to_ten_entries_per_minute_per_client() {
    let mut st = State::default();
    let start = Instant::now();
    for _ in 0..ADD_LIMIT {
        reserve_add(&mut st, "a", start).unwrap();
    }
    assert_eq!(reserve_add(&mut st, "a", start).unwrap_err(), "RateLimited");
    // Other clients have their own budget, and slots free up after the window.
    reserve_add(&mut st, "b", start).unwrap();
    reserve_add(&mut st, "a", start + ADD_WINDOW).unwrap();
}

#[test]
fn note_mcp_auto_save_enforces_whitelist_optimistic_lock_and_records_history() {
    let _flow = FLOW.lock().unwrap_or_else(|e| e.into_inner());
    state().note_writes.clear();
    let dir = std::env::temp_dir().join(format!("pv-ai-notes-{}", id()));
    std::fs::create_dir_all(&dir).unwrap();
    let s = Arc::new(VaultSession::new(dir.to_string_lossy().into()).unwrap());
    core(&s, json!({"op":"create","password":"synthetic-ai-note-password"})).unwrap();
    // Private note outside whitelist and a password entry (must NEVER be writable via note_update).
    core(&s, json!({"op":"save","item":{"id":"priv-note","type":"secureNote","title":"私密备忘","category":"家庭","note":"private"}})).unwrap();
    core(&s, json!({"op":"save","item":{"id":"acc-1","type":"password","title":"GitHub","username":"lin","password":"SECRET"}})).unwrap();
    control(&s, json!({
        "op":"configure",
        "aiAccessEnabled":true,
        "aiAccessScopes":{"accounts":true,"notes":true},
        "aiAccessNoteAutoWrite":true,
        "aiAccessNoteWritableCategories":["个人档案/财务与持仓","个人档案/健康记录"]
    })).unwrap();
    let token = control(&s, json!({"op":"pair","name":"Claude Code"})).unwrap()["token"].clone();

    // Creating in an unauthorized category fails closed.
    assert_eq!(
        request(&s, json!({"op":"note_update","createIfMissing":true,"title":"越权","category":"家庭","mode":"replace","content":"bad","summary":"try","token":token})).unwrap_err(),
        "NoteWriteDenied"
    );
    // Updating a private note or credential fails closed.
    assert_eq!(
        request(&s, json!({"op":"note_update","id":"priv-note","mode":"append","content":"x","summary":"try","token":token})).unwrap_err(),
        "NoteWriteDenied"
    );
    assert_eq!(
        request(&s, json!({"op":"note_update","id":"acc-1","mode":"replace","content":"x","summary":"try","token":token})).unwrap_err(),
        "UnscopedOrMissing"
    );
    // Missing summary is rejected.
    assert_eq!(
        request(&s, json!({"op":"note_update","createIfMissing":true,"title":"持仓","category":"个人档案/财务与持仓","mode":"replace","content":"x","summary":"   ","token":token})).unwrap_err(),
        "MissingSummary"
    );

    // Create a portfolio note in an authorized category without approval popup!
    let created = request(&s, json!({
        "op":"note_update",
        "createIfMissing":true,
        "slug":"finance/portfolio",
        "title":"当前持仓情况",
        "category":"个人档案/财务与持仓",
        "tags":["美股"],
        "properties":[{"key":"类型","value":"持仓状态"},{"key":"参考总值","value":"¥1,200,000"}],
        "mode":"replace",
        "content":"## 当前仓位\n\n| 标的 | 数量 |\n| --- | ---: |\n| VOO | 80 股 |\n\n## 调仓记录\n- 2026-10-01：建仓",
        "summary":"初始化持仓主文档",
        "token":token
    })).unwrap();
    assert_eq!(created["created"], true);
    let ver1 = created["versionHash"].as_str().unwrap().to_string();

    // note_list returns authorized writableCategories even before notes exist, and finds notes by prefix/alias/property without leaking private notes.
    let list = request(&s, json!({"op":"note_list","categoryPrefix":"个人档案","propertyKey":"类型","token":token})).unwrap();
    assert_eq!(list["autoWriteEnabled"], true);
    assert_eq!(list["writableCategories"], json!(["个人档案/财务与持仓","个人档案/健康记录"]));
    let arr = list["notes"].as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["slug"], "finance/portfolio");
    assert_eq!(arr[0]["writable"], true);
    let by_alias = request(&s, json!({"op":"note_list","category":"个人档案/财务与持仓","token":token})).unwrap();
    assert_eq!(by_alias["notes"].as_array().unwrap().len(), 1);

    // note_read supports slug lookup and section extraction.
    let sec = request(&s, json!({"op":"note_read","slug":"finance/portfolio","section":"当前仓位","token":token})).unwrap();
    assert!(sec["markdown"].as_str().unwrap().contains("VOO"));
    assert!(!sec["markdown"].as_str().unwrap().contains("2026-10-01"));

    // Stale expectedVersion on replace_section returns VersionConflict!
    assert_eq!(
        request(&s, json!({
            "op":"note_update","slug":"finance/portfolio","mode":"replace_section","section":"当前仓位",
            "expectedVersion":"stale-hash","content":"| 标的 | 数量 |\n| --- | ---: |\n| VOO | 90 股 |",
            "summary":"过期写入","token":token
        })).unwrap_err(),
        "VersionConflict"
    );

    // Valid replace_section updates only that section and keeps 调仓记录 intact.
    let upd = request(&s, json!({
        "op":"note_update","slug":"finance/portfolio","mode":"replace_section","section":"当前仓位",
        "expectedVersion":ver1,"content":"| 标的 | 数量 |\n| --- | ---: |\n| VOO | 90 股 |",
        "properties":[{"key":"类型","value":"持仓状态"},{"key":"参考总值","value":"¥1,280,000"}],
        "summary":"定投加仓 VOO 10 股","token":token
    })).unwrap();
    assert_eq!(upd["created"], false);
    let after = request(&s, json!({"op":"note_read","slug":"finance/portfolio","token":token})).unwrap();
    let md = after["markdown"].as_str().unwrap();
    assert!(md.contains("90 股"));
    assert!(md.contains("2026-10-01"));

    // Append a new bullet under 调仓记录 without needing full body replacement.
    request(&s, json!({
        "op":"note_update","slug":"finance/portfolio","mode":"append","section":"调仓记录",
        "content":"- 2026-11-19：定投加仓 VOO 10 股",
        "summary":"记录 11 月调仓日志","token":token
    })).unwrap();
    let hist = request(&s, json!({"op":"note_history","slug":"finance/portfolio","token":token})).unwrap();
    let revs = hist["revisions"].as_array().unwrap();
    assert_eq!(revs.len(), 3);
    assert_eq!(revs[0]["actorType"], "ai");
    assert_eq!(revs[0]["summary"], "记录 11 月调仓日志");

    // Agent can also read any historical snapshot as Markdown!
    let oldest_id = revs[2]["id"].as_str().unwrap();
    let snap = request(&s, json!({"op":"note_history","slug":"finance/portfolio","revisionId":oldest_id,"token":token})).unwrap();
    assert!(snap["markdown"].as_str().unwrap().contains("80 股"));
    assert!(!snap["markdown"].as_str().unwrap().contains("90 股"));

    // Split table stored the note body cleanly.
    assert_eq!(core(&s, json!({"op":"note-bodies-status"})).unwrap()["count"], 2);

    drop(s);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn note_attach_and_read_asset_enforce_whitelist_opt_in_and_keep_originals() {
    use std::io::Write;
    let _flow = FLOW.lock().unwrap_or_else(|e| e.into_inner());
    state().note_writes.clear();
    let dir = std::env::temp_dir().join(format!("pv-ai-assets-{}", id()));
    std::fs::create_dir_all(&dir).unwrap();
    let s = Arc::new(VaultSession::new(dir.join("vault").to_string_lossy().into()).unwrap());
    core(&s, json!({"op":"create","password":"synthetic-ai-asset-password"})).unwrap();
    core(&s, json!({"op":"save","item":{"id":"priv","type":"secureNote","title":"私密","category":"家庭","note":"private"}})).unwrap();
    core(&s, json!({"op":"save","item":{"id":"pub","type":"secureNote","slug":"finance/portfolio","title":"持仓","category":"个人档案/财务与持仓","note":"## 凭证"}})).unwrap();
    control(&s, json!({
        "op":"configure",
        "aiAccessEnabled":true,
        "aiAccessScopes":{"notes":true,"noteAssets":true},
        "aiAccessNoteAutoWrite":true,
        "aiAccessNoteWritableCategories":["个人档案/财务与持仓"]
    })).unwrap();
    let token = control(&s, json!({"op":"pair","name":"Claude Code"})).unwrap()["token"].clone();

    // Create a synthetic DOCX file on disk.
    let docx_path = dir.join("statement-2026.docx");
    {
        let f = std::fs::File::create(&docx_path).unwrap();
        let mut zw = zip::ZipWriter::new(f);
        zw.start_file("word/document.xml", zip::write::SimpleFileOptions::default()).unwrap();
        zw.write_all(r#"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>2026年第四季度对账单 净值 178420 USD</w:t></w:r></w:p></w:body></w:document>"#.as_bytes()).unwrap();
        zw.finish().unwrap();
    }

    // Cannot attach to non-writable category.
    assert_eq!(
        request(&s, json!({"op":"note_attach","id":"priv","path":docx_path,"summary":"bad","token":token})).unwrap_err(),
        "NoteWriteDenied"
    );

    // Attach into writable note by slug: encrypts into blobs/, inserts clean pv-asset:// link, keeps original file intact!
    let attached = request(&s, json!({
        "op":"note_attach",
        "slug":"finance/portfolio",
        "path":docx_path,
        "section":"凭证",
        "summary":"归档 Q4 对账单 Word 文档",
        "token":token
    })).unwrap();
    let aid = attached["attachmentId"].as_str().unwrap().to_string();
    assert!(docx_path.is_file(), "original file must never be deleted");
    assert_eq!(attached["markdownLink"], format!("[statement-2026.docx](pv-asset://{aid})"));

    // note_read exposes clean pv-asset:// link and attachments[] with aiReadable: false by default.
    let read_out = request(&s, json!({"op":"note_read","slug":"finance/portfolio","token":token})).unwrap();
    assert!(read_out["markdown"].as_str().unwrap().contains(&format!("pv-asset://{aid}")));
    assert_eq!(read_out["attachments"][0]["id"], aid);
    assert_eq!(read_out["attachments"][0]["aiReadable"], false);

    // note_read_asset fails closed until user toggles AI 可读文本 on that specific attachment.
    assert_eq!(
        request(&s, json!({"op":"note_read_asset","slug":"finance/portfolio","attachmentId":aid,"token":token})).unwrap_err(),
        "AssetTextDenied"
    );
    control(&s, json!({"op":"configure","aiAccessNoteAssetText":{"pub":{aid.clone():true}}})).unwrap();
    let text_out = request(&s, json!({"op":"note_read_asset","slug":"finance/portfolio","attachmentId":aid,"token":token})).unwrap();
    assert!(text_out["text"].as_str().unwrap().contains("178420 USD"));
    assert_eq!(text_out["eof"], true);

    // Subsequent note_update keeps the clean pv-asset:// attachment valid!
    let ver = read_out["versionHash"].as_str().unwrap().to_string();
    request(&s, json!({
        "op":"note_update",
        "slug":"finance/portfolio",
        "mode":"append",
        "expectedVersion":ver,
        "content":"已核对对账单无误。",
        "summary":"追加核对结论",
        "token":token
    })).unwrap();
    let after = request(&s, json!({"op":"note_read","slug":"finance/portfolio","token":token})).unwrap();
    assert!(after["markdown"].as_str().unwrap().contains(&format!("pv-asset://{aid}")));
    assert!(after["markdown"].as_str().unwrap().contains("已核对对账单无误"));

    // Turning off noteAssets scope blocks both note_read_asset and note_attach immediately.
    control(&s, json!({"op":"configure","aiAccessScopes":{"notes":true,"noteAssets":false}})).unwrap();
    assert_eq!(
        request(&s, json!({"op":"note_read_asset","slug":"finance/portfolio","attachmentId":aid,"token":token})).unwrap_err(),
        "AssetAccessDisabled"
    );

    drop(s);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn tools_schema_json_is_valid_and_complete() {
    let raw = include_str!("tools.schema.json");
    let doc: Value = serde_json::from_str(raw).expect("tools.schema.json must parse");
    assert!(doc["instructions"].as_str().is_some_and(|s| s.len() > 50));
    let tools = doc["tools"].as_array().expect("tools array");
    assert_eq!(tools.len(), 11);
    let names: Vec<&str> = tools
        .iter()
        .map(|t| {
            assert!(t["uiSummary"].as_str().is_some_and(|s| !s.is_empty()));
            assert!(t["description"].as_str().is_some_and(|s| !s.is_empty()));
            assert!(t["inputSchema"].is_object());
            t["name"].as_str().unwrap()
        })
        .collect();
    for expected in [
        "note_list",
        "note_read",
        "note_update",
        "note_attach",
        "note_read_asset",
        "note_history",
        "search",
        "get",
        "get_secret",
        "add",
        "ask_user",
    ] {
        assert!(names.contains(&expected), "missing tool {expected}");
    }
}

#[test]
fn paired_client_pause_fingerprint_telemetry_and_batch_revoke() {
    let _flow = FLOW.lock().unwrap_or_else(|e| e.into_inner());
    let dir = std::env::temp_dir().join(format!("pv-ai-clients-{}", id()));
    std::fs::create_dir_all(&dir).unwrap();
    let s = Arc::new(VaultSession::new(dir.to_string_lossy().into()).unwrap());
    core(&s, json!({"op":"create","password":"synthetic-ai-clients-pw"})).unwrap();
    core(&s, json!({"op":"save","item":{"id":"acc-1","type":"password","title":"GitHub","username":"lin","password":"SECRET"}})).unwrap();
    control(&s, json!({
        "op":"configure",
        "aiAccessEnabled":true,
        "aiAccessScopes":{"accounts":true}
    })).unwrap();

    // Two clients with the EXACT same name must get distinct non-secret fingerprints.
    let p1 = control(&s, json!({"op":"pair","name":"Claude Code"})).unwrap();
    let p2 = control(&s, json!({"op":"pair","name":"Claude Code"})).unwrap();
    let p3 = control(&s, json!({"op":"pair","name":"本机 AI 客户端"})).unwrap();
    let cid1 = p1["clientId"].as_str().unwrap().to_string();
    let cid2 = p2["clientId"].as_str().unwrap().to_string();
    let cid3 = p3["clientId"].as_str().unwrap().to_string();
    let tok1 = p1["token"].as_str().unwrap().to_string();
    assert_ne!(p1["fingerprint"], p2["fingerprint"]);
    assert!(p1["fingerprint"].as_str().unwrap().contains('…'));

    // Status exposes fingerprint and strips tokenHash.
    let st = control(&s, json!({"op":"status"})).unwrap();
    let cs = st["settings"]["aiAccessClients"].as_array().unwrap();
    assert_eq!(cs.len(), 3);
    for c in cs {
        assert!(c.get("tokenHash").is_none());
        assert!(c["fingerprint"].as_str().is_some_and(|fp| fp.contains('…')));
        assert!(c["createdUnix"].as_u64().is_some_and(|t| t > 0));
    }

    // Active client call updates callCount, lastUsedUnix, and lastOp.
    let found = request(&s, json!({"op":"search","query":"GitHub","token":tok1})).unwrap();
    assert_eq!(found.as_array().unwrap().len(), 1);
    let st = control(&s, json!({"op":"status"})).unwrap();
    let c1 = st["settings"]["aiAccessClients"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == cid1)
        .unwrap();
    assert_eq!(c1["callCount"], 1);
    assert_eq!(c1["lastOp"], "search");
    assert!(c1["lastUsedUnix"].as_u64().is_some_and(|t| t > 0));

    // Pausing rejects requests with ClientPaused and drops leases for that client while keeping token.
    state().leases.push(Lease {
        client: cid1.clone(),
        entry: "acc-1".into(),
        field: "password".into(),
        reveal: false,
        expires: Some(Instant::now() + Duration::from_secs(60)),
    });
    control(&s, json!({"op":"set_paused","clientId":cid1,"paused":true})).unwrap();
    assert!(state().leases.iter().all(|l| l.client != cid1));
    assert_eq!(
        request(&s, json!({"op":"search","query":"GitHub","token":tok1})).unwrap_err(),
        "ClientPaused"
    );
    // Resuming immediately restores the same token without re-pairing!
    control(&s, json!({"op":"set_paused","clientId":cid1,"paused":false})).unwrap();
    assert!(request(&s, json!({"op":"search","query":"GitHub","token":tok1})).is_ok());

    // Batch revoke removes targeted unused clients atomically while preserving active client.
    let rev = control(&s, json!({"op":"revoke_many","clientIds":[cid2, cid3]})).unwrap();
    assert_eq!(rev["removed"], 2);
    let st = control(&s, json!({"op":"status"})).unwrap();
    let remaining = st["settings"]["aiAccessClients"].as_array().unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0]["id"], cid1);

    drop(s);
    std::fs::remove_dir_all(dir).unwrap();
}
