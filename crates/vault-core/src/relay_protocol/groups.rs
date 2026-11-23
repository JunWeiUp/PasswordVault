//! Durable group enrollment state machine (create, invite, join, approve, rename, remove,
//! exit). Every retryable draft is saved before its HTTP mutation. Transport is injected via
//! [`Api`], so desktop (reqwest) and future mobile callers share the same rules.
use super::*;
use base64::engine::general_purpose::STANDARD;
use std::time::{SystemTime, UNIX_EPOCH};

/// Errors are relay error codes (`InvalidData`, `RelayHttp409`, `ApprovalPending`, ...).
pub type Result<T> = std::result::Result<T, String>;
fn invalid<T>() -> Result<T> {
    Err("InvalidData".into())
}
fn random_bytes(n: usize) -> Vec<u8> {
    let mut bytes = vec![0u8; n];
    getrandom::getrandom(&mut bytes).expect("system randomness");
    bytes
}
pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn random() -> String {
    hex(&random_bytes(32))
}
fn name(s: &str) -> Result<&str> {
    let s = s.trim();
    if s.is_empty() || s.len() > 128 {
        return invalid();
    }
    Ok(s)
}
/// Unix seconds from an integer or fractional JSON number (older clients sent floats).
fn seconds(v: &Value) -> u64 {
    v.as_u64()
        .or_else(|| v.as_f64().filter(|f| *f >= 0.0).map(|f| f as u64))
        .unwrap_or(0)
}
fn erase(v: &mut Value, key: &str) {
    v.as_object_mut().unwrap().remove(key);
}
pub trait Api {
    fn call(
        &self,
        c: &Value,
        method: &str,
        path: &str,
        body: Option<Value>,
        auth: Option<String>,
    ) -> Result<Value>;
}
pub struct Groups<'a, A: Api> {
    pub config: Value,
    pub api: A,
    pub save: &'a mut dyn FnMut(&Value) -> Result<()>,
    pub local: bool,
}
impl<A: Api> Groups<'_, A> {
    fn persist(&mut self) -> Result<()> {
        (self.save)(&self.config)
    }
    fn call(&self, m: &str, p: &str, b: Option<Value>, a: Option<String>) -> Result<Value> {
        self.api.call(&self.config, m, p, b, a)
    }
    fn sign(&self, v: &Value) -> Result<Value> {
        Ok(sign_value(
            v,
            &unhex(text(&self.config, "secret_key")?)?,
            text(&self.config, "device")?,
        )?)
    }
    pub fn member(&self, n: &str) -> Result<Value> {
        let raw = unhex(text(&self.config, "secret_key")?)?;
        let sk = BoxSecretKey::from_slice(&raw).ok_or("InvalidData")?;
        let (pk, _) = signing(&raw)?;
        Ok(
            json!({"device":self.config["device"],"name":n,"public_key":hex(&sk.public_key().0),"signing_key":hex(&pk.0),"manager":false}),
        )
    }
    fn state(&self) -> Result<Value> {
        Ok(unpack(&self.config["group_entry"])?)
    }
    fn accept(&mut self, e: Value) -> Result<()> {
        let state = unpack(&e)?;
        valid_state(&state)?;
        if state["app"] != self.config["app"] || state["group"] != self.config["group"] {
            return invalid();
        }
        let mut peers = serde_json::Map::new();
        for m in state["members"].as_array().ok_or("InvalidData")? {
            if m["device"] != self.config["device"] {
                peers.insert(text(m, "device")?.into(), m["public_key"].clone());
            }
        }
        self.config["group_entry"] = e;
        self.config["trusted_peers"] = Value::Object(peers);
        self.config["public_key"] = self.member("")?["public_key"].clone();
        Ok(())
    }
    pub fn refresh(&mut self) -> Result<Value> {
        let mut current = self.config["group_entry"].clone();
        for _ in 0..4096 {
            let old = unpack(&current)?;
            let reply = self.call(
                "GET",
                &format!("/group?after={}", old["revision"]),
                None,
                None,
            )?;
            let entries = reply["entries"].as_array().ok_or("InvalidData")?;
            let online = reply["online"].clone();
            for e in entries {
                current = advance(&current, e)?;
                // Record the exact signed approval observed on the verified chain,
                // even when later changes are returned in the same history page.
                if self.config["pending_approval"]["entry"] == *e {
                    self.config["pending_approval"]["committed"] = json!(true);
                }
            }
            let revision = unpack(&current)?["revision"]
                .as_u64()
                .ok_or("InvalidData")?;
            if entries.is_empty() || revision >= reply["revision"].as_u64().ok_or("InvalidData")? {
                self.accept(current)?;
                self.persist()?;
                return Ok(json!({"state":self.state()?,"online":online}));
            }
            if revision <= old["revision"].as_u64().unwrap_or(0) {
                return invalid();
            }
        }
        invalid()
    }
    pub fn create(&mut self, title: &str, device_name: &str) -> Result<()> {
        if self.config.get("group_entry").is_some() || self.config.get("pending_join").is_some() {
            return invalid();
        }
        if self.config.get("pending_create").is_none() {
            if self.config.get("group").is_some() {
                return invalid();
            }
            let title = name(title)?;
            let device_name = name(device_name)?;
            self.config["group"] = json!(format!("g-{}", &random()[..32]));
            self.config["token"] = json!(random());
            let mut own = self.member(device_name)?;
            own["manager"] = json!(true);
            self.config["pending_create"]=self.sign(&json!({"version":1,"app":self.config["app"],"group":self.config["group"],"name":title,"revision":1,"previous":"","members":[own],"invitation":"","request_hash":""}))?;
            self.persist()?;
        }
        let e = self.config["pending_create"].clone();
        self.call(
            "POST",
            "/group/create",
            Some(json!({"entry":e,"token_hash":digest(text(&self.config,"token")?.as_bytes())})),
            None,
        )?;
        self.accept(e)?;
        erase(&mut self.config, "pending_create");
        self.persist()
    }
    fn manager(&self) -> Result<Value> {
        let state = self.state()?;
        let own = state["members"]
            .as_array()
            .ok_or("InvalidData")?
            .iter()
            .find(|m| m["device"] == self.config["device"])
            .ok_or("InvalidData")?;
        if own["manager"] != true {
            return Err("ManagerRequired".into());
        }
        Ok(own.clone())
    }
    pub fn invite(&mut self, mode: &str) -> Result<String> {
        if self.config["pending_approval"].is_object() {
            return Err("ApprovalPending".into());
        }
        if mode != "auto" && mode != "manual" {
            return invalid();
        }
        self.refresh()?;
        let own = self.manager()?;
        if self.config["issued_invitation"]["expires"]
            .as_u64()
            .unwrap_or(0)
            > now()
        {
            return self.publish();
        }
        let secret = random();
        let mut body = json!({"secret_hash":digest(secret.as_bytes())});
        let mut inv = json!({});
        if mode == "auto" {
            let delegate = random();
            let (key, _) = signing(&unhex(&delegate)?)?;
            let grant=self.sign(&json!({"version":1,"purpose":"common-relay/admission/v1","mode":"auto","app":self.config["app"],"group":self.config["group"],"invitation":&random()[..32],"expires":now()+600,"secret_hash":body["secret_hash"],"delegate_key":hex(&key.0),"anchor_revision":self.state()?["revision"],"anchor_hash":digest(&payload(&self.config["group_entry"])?) }))?;
            body["mode"] = json!(mode);
            body["grant"] = grant.clone();
            inv["grant"] = grant;
            inv["delegate_secret"] = json!(delegate);
        }
        let result = self.call("POST", "/group/invitations", Some(body), None)?;
        if mode == "auto" {
            let grant = unpack(&inv["grant"])?;
            if result["mode"] != mode
                || result["id"] != grant["invitation"]
                || result["expires"] != grant["expires"]
            {
                return invalid();
            }
        }
        if unhex(text(&result, "id")?)?.len() != 16
            || result["expires"].as_u64().unwrap_or(0) <= now()
        {
            return invalid();
        }
        for (k,v) in json!({"version":1,"mode":mode,"url":self.config["url"],"app":self.config["app"],"group":self.config["group"],"id":result["id"],"expires":result["expires"],"secret":secret,"manager":own}).as_object().unwrap(){inv[k]=v.clone();}
        self.config["issued_invitation"] = inv;
        erase(&mut self.config, "join_request");
        self.persist()?;
        self.publish()
    }
    /// Publishes (or returns) the short link for the issued invitation; idempotent.
    pub fn publish(&mut self) -> Result<String> {
        let inv = &self.config["issued_invitation"];
        if let Some(link) = inv["short_link"].as_str() {
            return Ok(link.into());
        }
        // Keep packet/key stable across response loss and retries.
        if self.config.get("pending_link").is_none() {
            let key = random_bytes(32);
            let nonce = random_bytes(24);
            self.config["pending_link"] =
                json!({"key":STANDARD.encode(&key),"packet":seal_invitation(inv,&key,&nonce)?});
            self.persist()?;
        }
        let key = STANDARD
            .decode(text(&self.config["pending_link"], "key")?)
            .map_err(|_| "InvalidData")?;
        let id = text(&self.config["issued_invitation"], "id")?;
        self.call("POST",&format!("/group/invitations/{id}/link"),Some(json!({"read_hash":digest(read_token(&key)?.as_bytes()),"packet":self.config["pending_link"]["packet"]})),None)?;
        let mut inv = self.config["issued_invitation"].clone();
        if self.local {
            let original = text(&inv, "url")?.to_owned();
            inv["url"] = json!(original.replacen("ws:", "wss:", 1));
        }
        let link = make_link(&inv, &key, configured_password(&self.config)?)?;
        self.config["issued_invitation"]["short_link"] = json!(link);
        erase(&mut self.config, "pending_link");
        self.persist()?;
        Ok(link)
    }
    /// Resolves a short link. The access password comes from the link, else the user's typed
    /// password, else our own password only for our own relay; an explicit one is returned
    /// in the invitation so `join` can keep it.
    pub fn resolve(&self, link: &str, typed: Option<&str>) -> Result<Value> {
        self.resolve_with(link, typed, None)
    }
    /// Like [`Self::resolve`]; an explicit `override_password` (the user corrected it) wins
    /// over the link's password, and an empty override is rejected before any request.
    pub fn resolve_with(
        &self,
        link: &str,
        typed: Option<&str>,
        override_password: Option<&str>,
    ) -> Result<Value> {
        let (mut url, id, key, mut link_password) = parse_link(link.trim())?;
        if let Some(p) = override_password {
            link_password = Some(access_password(p)?.to_owned());
        }
        if self.local
            && url::Url::parse(&url).map_err(|_| "InvalidData")?.host_str() == Some("127.0.0.1")
        {
            url = url.replacen("wss:", "ws:", 1);
        }
        let explicit = match (link_password, typed) {
            (Some(p), _) => Some(p),
            (None, Some(p)) => Some(access_password(p)?.to_owned()),
            (None, None) => None,
        };
        let password = match &explicit {
            Some(p) => Some(p.clone()),
            None if self.config["url"] == url => {
                configured_password(&self.config)?.map(str::to_owned)
            }
            None => None,
        };
        let result = self.api.call(
            &json!({"url":url,"password":password}),
            "GET",
            &format!("/enroll/{id}/link"),
            None,
            Some(format!("InvitationLink {}", read_token(&key)?)),
        )?;
        if result["version"] != 1 {
            return invalid();
        }
        let mut inv = open_invitation(text(&result, "packet")?, &key)?;
        if inv["version"] != 1
            || inv["url"] != url
            || inv["id"] != id
            || inv["app"] != self.config["app"]
            || seconds(&inv["expires"]) <= now()
        {
            return invalid();
        }
        if let Some(p) = explicit {
            inv["password"] = json!(p);
        }
        Ok(inv)
    }
    fn grant(&self, inv: &Value) -> Result<Value> {
        let e = &inv["grant"];
        let m = &inv["manager"];
        let g = unpack(e)?;
        verify(e, text(m, "signing_key")?)?;
        if e.get("authorization").is_some()
            || m["manager"] != true
            || e["signer"] != m["device"]
            || g["version"] != 1
            || g["purpose"] != "common-relay/admission/v1"
            || g["mode"] != "auto"
            || g["app"] != inv["app"]
            || g["group"] != inv["group"]
            || g["invitation"] != inv["id"]
            || g["expires"] != inv["expires"]
            || g["secret_hash"] != digest(text(inv, "secret")?.as_bytes())
            || g["anchor_revision"].as_u64().unwrap_or(0) < 1
            || unhex(text(&g, "anchor_hash")?)?.len() != 32
        {
            return invalid();
        }
        let (key, _) = signing(&unhex(text(inv, "delegate_secret")?)?)?;
        if g["delegate_key"] != hex(&key.0) {
            return invalid();
        }
        Ok(g)
    }
    pub fn join(&mut self, inv: Value, n: &str) -> Result<bool> {
        if self.config.get("group_entry").is_some() || self.config.get("pending_create").is_some() {
            return invalid();
        }
        if inv["version"] != 1
            || inv["app"] != self.config["app"]
            || seconds(&inv["expires"]) <= now()
        {
            return invalid();
        }
        endpoint(text(&inv, "url")?, self.local)?;
        if inv["mode"] == "auto" {
            self.grant(&inv)?;
        } else if inv["mode"] != "manual" && !inv["mode"].is_null() {
            return invalid();
        }
        if self.config.get("pending_join").is_some() {
            if self.config["pending_join"]["invitation"] != inv {
                return Err("AnotherJoinPending".into());
            }
        } else {
            self.config["url"] = inv["url"].clone();
            self.config["group"] = inv["group"].clone();
            if let Some(p) = inv.get("password").and_then(Value::as_str) {
                self.config["password"] = json!(access_password(p)?);
            }
            self.config["token"] = json!(random());
            let req=self.sign(&json!({"version":1,"app":self.config["app"],"group":self.config["group"],"invitation":inv["id"],"member":self.member(name(n)?)?,"token_hash":digest(text(&self.config,"token")?.as_bytes())}))?;
            self.config["pending_join"] = json!({"invitation":inv,"request":req});
            self.persist()?;
        }
        self.call(
            "POST",
            &format!("/enroll/{}", text(&inv, "id")?),
            Some(self.config["pending_join"]["request"].clone()),
            Some(format!("Invitation {}", text(&inv, "secret")?)),
        )?;
        self.finish_join()
    }
    pub fn finish_join(&mut self) -> Result<bool> {
        let pending = self.config["pending_join"].clone();
        let inv = &pending["invitation"];
        let request = &pending["request"];
        let req = unpack(request)?;
        let id = text(inv, "id")?;
        let auth = Some(format!("Claim {}", text(&self.config, "token")?));
        let e = if inv["mode"] == "auto" {
            let grant = self.grant(inv)?;
            let anchor = grant["anchor_revision"].as_u64().ok_or("InvalidData")?;
            let mut after = anchor - 1;
            let mut current: Option<Value> = None;
            let mut result = json!({});
            for _ in 0..4096 {
                result = self.call(
                    "GET",
                    &format!("/enroll/{id}/auto?after={after}"),
                    None,
                    auth.clone(),
                )?;
                let entries = result["entries"].as_array().ok_or("InvalidData")?;
                let latest = result["revision"].as_u64().ok_or("InvalidData")?;
                if entries.is_empty() || latest < anchor || latest > 4096 {
                    return invalid();
                }
                for e in entries {
                    current = Some(if let Some(old) = current {
                        advance(&old, e)?
                    } else {
                        let state = unpack(e)?;
                        if state["app"] != inv["app"]
                            || state["group"] != inv["group"]
                            || digest(&payload(e)?) != grant["anchor_hash"]
                            || state["revision"] != anchor
                        {
                            return invalid();
                        }
                        e.clone()
                    });
                }
                let revision = unpack(current.as_ref().ok_or("InvalidData")?)?["revision"]
                    .as_u64()
                    .ok_or("InvalidData")?;
                if revision <= after || revision > latest {
                    return invalid();
                }
                after = revision;
                if after == latest {
                    break;
                }
            }
            let current = current.ok_or("InvalidData")?;
            if result["entry"].is_object() {
                if result["entry"] != current {
                    return invalid();
                }
                current
            } else {
                let mut state = unpack(&current)?;
                state["members"]
                    .as_array_mut()
                    .ok_or("InvalidData")?
                    .push(req["member"].clone());
                state["revision"] = json!(after + 1);
                state["previous"] = json!(digest(&payload(&current)?));
                state["invitation"] = inv["id"].clone();
                state["request_hash"] = json!(digest(&payload(request)?));
                let mut e = sign_value(
                    &state,
                    &unhex(text(inv, "delegate_secret")?)?,
                    text(&inv["manager"], "device")?,
                )?;
                e["authorization"] = inv["grant"].clone();
                advance(&current, &e)?;
                self.config["pending_join"]["auto_entry"] = e.clone();
                self.persist()?;
                let reply =
                    self.call("POST", &format!("/enroll/{id}/auto"), Some(e.clone()), auth)?;
                if reply != e {
                    return invalid();
                }
                e
            }
        } else {
            let result = self.call("GET", &format!("/enroll/{id}"), None, auth)?;
            if result["entry"].is_null() {
                return Ok(false);
            }
            let e = result["entry"].clone();
            if e.get("authorization").is_some() {
                return invalid();
            }
            verify(&e, text(&inv["manager"], "signing_key")?)?;
            e
        };
        let state = unpack(&e)?;
        let own = state["members"]
            .as_array()
            .ok_or("InvalidData")?
            .iter()
            .find(|m| m["device"] == self.config["device"])
            .ok_or("InvalidData")?;
        let mut expected = req["member"].clone();
        if inv["mode"] != "auto" {
            expected["manager"] = own["manager"].clone();
        }
        if state["app"] != self.config["app"]
            || state["group"] != self.config["group"]
            || state["closed"] == true
            || e["signer"] != inv["manager"]["device"]
            || state["invitation"] != inv["id"]
            || state["request_hash"] != digest(&payload(request)?)
            || *own != expected
            || (inv["mode"] == "auto" && e["authorization"] != inv["grant"])
        {
            return invalid();
        }
        self.accept(e)?;
        erase(&mut self.config, "pending_join");
        self.persist()?;
        Ok(true)
    }
    pub fn pending(&mut self) -> Result<()> {
        if self.config["pending_approval"].is_object() {
            return Ok(());
        }
        let inv = &self.config["issued_invitation"];
        if inv["mode"] == "auto" {
            return invalid();
        }
        let result = self.call(
            "GET",
            &format!("/group/invitations/{}", text(inv, "id")?),
            None,
            None,
        )?;
        if result["request"].is_null() {
            erase(&mut self.config, "join_request");
        } else {
            let e = &result["request"];
            let req = unpack(e)?;
            if req["app"] != self.config["app"]
                || req["group"] != self.config["group"]
                || req["invitation"] != inv["id"]
                || e["signer"] != req["member"]["device"]
            {
                return invalid();
            }
            verify(e, text(&req["member"], "signing_key")?)?;
            self.config["join_request"] = e.clone();
        }
        self.persist()
    }
    pub fn code(&self) -> Result<String> {
        let req = if self.config["pending_join"].is_object() {
            &self.config["pending_join"]["request"]
        } else {
            &self.config["join_request"]
        };
        let h = digest(&payload(req)?)[..12].to_uppercase();
        Ok(format!("{}-{}-{}", &h[..4], &h[4..8], &h[8..12]))
    }
    fn change(&mut self, mut state: Value) -> Result<()> {
        let old = &self.config["group_entry"];
        state["revision"] = json!(state["revision"].as_u64().ok_or("InvalidData")? + 1);
        state["previous"] = json!(digest(&payload(old)?));
        let e = self.sign(&state)?;
        advance(old, &e)?;
        self.call("PUT", "/group", Some(e.clone()), None)?;
        self.accept(e)?;
        self.persist()
    }
    pub fn approve(&mut self, code: &str, manager: bool) -> Result<()> {
        if code != self.code()? {
            return Err("VerificationCodeMismatch".into());
        }
        if self.config["pending_approval"].is_object() {
            if self.config["pending_approval"]["manager"] != manager {
                return invalid();
            }
            return self.finish_approval();
        }
        self.refresh()?;
        self.manager()?;
        let req = unpack(&self.config["join_request"])?;
        let inv = &self.config["issued_invitation"];
        if seconds(&inv["expires"]) <= now() || req["invitation"] != inv["id"] {
            return invalid();
        }
        verify(
            &self.config["join_request"],
            text(&req["member"], "signing_key")?,
        )?;
        let mut m = req["member"].clone();
        m["manager"] = json!(manager);
        let mut state = self.state()?;
        let members = state["members"].as_array_mut().ok_or("InvalidData")?;
        members.retain(|v| v["device"] != m["device"]);
        members.push(m);
        state["invitation"] = inv["id"].clone();
        state["request_hash"] = json!(digest(&payload(&self.config["join_request"])?));
        state["revision"] = json!(state["revision"].as_u64().ok_or("InvalidData")? + 1);
        state["previous"] = json!(digest(&payload(&self.config["group_entry"])?));
        let entry = self.sign(&state)?;
        advance(&self.config["group_entry"], &entry)?;
        self.config["pending_approval"] =
            json!({"entry":entry,"manager":manager,"committed":false});
        self.persist()?; // Persist the exact user-confirmed request before PUT.
        self.finish_approval()
    }
    fn finish_approval(&mut self) -> Result<()> {
        let entry = self.config["pending_approval"]["entry"].clone();
        self.refresh()?;
        if self.config["pending_approval"]["committed"] != true {
            let candidate = unpack(&entry)?;
            let current = self.state()?;
            if current["revision"].as_u64().ok_or("InvalidData")?
                >= candidate["revision"].as_u64().ok_or("InvalidData")?
            {
                // A different signed entry occupies this revision. Never rebase
                // an old confirmation onto another request or changed identity.
                return Err("ApprovalConflict".into());
            }
            advance(&self.config["group_entry"], &entry)?;
            self.call("PUT", "/group", Some(entry.clone()), None)?;
            self.accept(entry.clone())?;
            self.config["pending_approval"]["committed"] = json!(true);
            self.persist()?;
        }
        // A separate access transaction may resume after this membership commit.
        self.config["approval_receipt"] = entry;
        erase(&mut self.config, "pending_approval");
        erase(&mut self.config, "issued_invitation");
        erase(&mut self.config, "join_request");
        self.persist()
    }
    pub fn cancel(&mut self) -> Result<()> {
        if self.config["pending_approval"].is_object() {
            self.refresh()?;
            if self.config["pending_approval"]["committed"] == true {
                // Membership is already committed. Complete its local receipt;
                // the access intent has been cancelled separately by the caller.
                self.finish_approval()?;
            } else {
                let candidate = unpack(&self.config["pending_approval"]["entry"])?;
                if self.state()?["revision"].as_u64().ok_or("InvalidData")?
                    < candidate["revision"].as_u64().ok_or("InvalidData")?
                {
                    return Err("ApprovalPending".into());
                }
                // A verified different entry has occupied the candidate's slot.
                erase(&mut self.config, "pending_approval");
                self.persist()?;
            }
        }
        if self.config["issued_invitation"].is_null() {
            return Ok(());
        }
        self.call(
            "DELETE",
            &format!(
                "/group/invitations/{}",
                text(&self.config["issued_invitation"], "id")?
            ),
            None,
            None,
        )?;
        for k in ["issued_invitation", "pending_link", "join_request"] {
            erase(&mut self.config, k);
        }
        self.persist()
    }
    pub fn rename(&mut self, device: &str, n: &str) -> Result<()> {
        let n = name(n)?;
        self.refresh()?;
        let mut state = self.state()?;
        let m = state["members"]
            .as_array_mut()
            .ok_or("InvalidData")?
            .iter_mut()
            .find(|m| m["device"] == device)
            .ok_or("InvalidData")?;
        if m["name"] == n {
            return Ok(());
        }
        m["name"] = json!(n);
        state["invitation"] = json!("");
        state["request_hash"] = json!("");
        self.change(state)
    }
    pub fn remove(&mut self, device: &str) -> Result<()> {
        if self.config["device"] == device {
            return invalid();
        }
        self.refresh()?;
        self.manager()?;
        let mut state = self.state()?;
        state["members"]
            .as_array_mut()
            .ok_or("InvalidData")?
            .retain(|m| m["device"] != device);
        state["invitation"] = json!("");
        state["request_hash"] = json!("");
        self.change(state)
    }
    /// The signed exit (or disband) entry for the current verified state, checked against
    /// the chain rules. Fails when the exit is not allowed (e.g. the last manager leaving
    /// other members behind, or a non-manager disbanding).
    fn exit_entry(&self, disband: bool) -> Result<Value> {
        let mut state = self.state()?;
        if disband {
            self.manager()?;
        }
        let own = self.config["device"].clone();
        let members = state["members"].as_array_mut().ok_or("InvalidData")?;
        members.retain(|m| !disband && m["device"] != own);
        if members.is_empty() {
            state["closed"] = json!(true);
        } else if !members.iter().any(|m| m["manager"] == true) {
            return Err("LastManager".into());
        }
        state["invitation"] = json!("");
        state["request_hash"] = json!("");
        state["revision"] = json!(state["revision"].as_u64().ok_or("InvalidData")? + 1);
        state["previous"] = json!(digest(&payload(&self.config["group_entry"])?));
        let e = self.sign(&state)?;
        advance(&self.config["group_entry"], &e)?;
        Ok(e)
    }
    /// Offline pre-check so a client can clear local state first (owner policy) only when the
    /// signed exit it will send afterwards is valid. Uses the locally verified state.
    pub fn check_exit(&self, disband: bool) -> Result<()> {
        if self.config["exit_completed"] == true || self.config.get("group_entry").is_none() {
            return Ok(());
        }
        self.exit_entry(disband).map(|_| ())
    }
    pub fn exit(&mut self, disband: bool) -> Result<()> {
        if self.config["exit_completed"] == true {
            return Ok(());
        }
        if self.config.get("pending_exit").is_some() {
            if self.config["exit_disband"] != disband {
                return invalid();
            }
        } else {
            self.refresh()?;
            let e = self.exit_entry(disband)?;
            self.config["pending_exit"] = e;
            self.config["exit_disband"] = json!(disband);
            self.persist()?;
        }
        let e = self.config["pending_exit"].clone();
        match self.call("POST", "/group/exit", Some(e.clone()), None) {
            Ok(_) => {}
            Err(e) => {
                if e == "RelayHttp409" {
                    erase(&mut self.config, "pending_exit");
                    self.persist()?;
                }
                return Err(e);
            }
        }
        self.accept(e)?;
        erase(&mut self.config, "pending_exit");
        self.config["exit_completed"] = json!(true);
        self.persist()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// In-memory relay: accepts writes and serves the verified chain back.
    #[derive(Default)]
    struct Relay {
        entries: RefCell<Vec<Value>>,
        calls: RefCell<Vec<String>>,
    }
    impl Api for &Relay {
        fn call(
            &self,
            _c: &Value,
            method: &str,
            path: &str,
            body: Option<Value>,
            _a: Option<String>,
        ) -> Result<Value> {
            self.calls.borrow_mut().push(format!("{method} {path}"));
            let mut entries = self.entries.borrow_mut();
            match (method, path.split('?').next().unwrap_or("")) {
                ("POST", "/group/create") => entries.push(body.unwrap()["entry"].clone()),
                ("PUT", "/group") | ("POST", "/group/exit") => entries.push(body.unwrap()),
                ("GET", "/group") => {
                    let after: u64 = path.rsplit('=').next().unwrap().parse().unwrap();
                    let newer: Vec<Value> = entries.iter().skip(after as usize).cloned().collect();
                    return Ok(json!({"entries": newer, "revision": entries.len(), "online": []}));
                }
                _ => return Err("RelayHttp404".into()),
            }
            Ok(json!({}))
        }
    }

    #[test]
    fn create_rename_and_exit_run_against_an_injected_transport() {
        let relay = Relay::default();
        let mut saved = Vec::new();
        let mut save = |c: &Value| {
            saved.push(c.clone());
            Ok(())
        };
        let mut groups = Groups {
            config: json!({"app":"passwordvault","url":"wss://relay.example/relay/v1/ws","device":"mac","secret_key":hex(&random_bytes(32))}),
            api: &relay,
            save: &mut save,
            local: false,
        };
        groups.create("Home", "Mac").unwrap();
        assert!(groups.config["pending_create"].is_null());
        groups.rename("mac", "MacBook").unwrap();
        assert_eq!(
            unpack(&groups.config["group_entry"]).unwrap()["members"][0]["name"],
            "MacBook"
        );
        assert!(groups.create("Again", "Mac").is_err(), "already enrolled");
        groups.exit(true).unwrap();
        assert_eq!(groups.config["exit_completed"], true);
        let closed = unpack(&groups.config["group_entry"]).unwrap();
        assert_eq!(closed["closed"], true);
        assert_eq!(closed["revision"], 3);
        assert_eq!(relay.calls.borrow()[0], "POST /group/create");
        drop(groups);
        // The draft is persisted before the HTTP mutation that commits it.
        assert!(saved[0]["pending_create"].is_object());
    }
}
