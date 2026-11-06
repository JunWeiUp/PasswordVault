//! Durable group enrollment. Every retryable draft is saved before its HTTP mutation.
use super::{Result, invalid, protocol::*, transport::endpoint};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    io::Read,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn random() -> String {
    hex(&sodiumoxide::randombytes::randombytes(32))
}
fn name(s: &str) -> Result<&str> {
    let s = s.trim();
    if s.is_empty() || s.len() > 128 {
        return invalid();
    }
    Ok(s)
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
pub struct Http {
    pub local: bool,
}
impl Api for Http {
    fn call(
        &self,
        c: &Value,
        method: &str,
        path: &str,
        body: Option<Value>,
        auth: Option<String>,
    ) -> Result<Value> {
        let mut url = endpoint(text(c, "url")?, self.local)?;
        url.set_scheme(if url.scheme() == "wss" {
            "https"
        } else {
            "http"
        })
        .map_err(|_| "InvalidData")?;
        let base = format!(
            "{}://{}{}",
            url.scheme(),
            &url[url::Position::BeforeHost..url::Position::AfterPort],
            "/relay/v1"
        );
        if !path.starts_with('/') || path.contains('#') || path.contains("..") {
            return invalid();
        }
        let client = reqwest::blocking::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|_| "RelayConnection")?;
        let mut request = client
            .request(
                method.parse().map_err(|_| "InvalidData")?,
                format!("{base}{path}"),
            )
            .header(
                "Authorization",
                auth.unwrap_or_else(|| format!("Bearer {}", c["token"].as_str().unwrap_or(""))),
            );
        if let Some(password) = configured_password(c)? {
            request = request.header(ACCESS_HEADER, password);
        }
        if let Some(body) = body {
            request = request
                .header("Content-Type", "application/json")
                .body(canonical(&body));
        }
        let response = request.send().map_err(|_| "RelayConnection")?;
        let status = response.status().as_u16();
        if status != 200 {
            return Err(format!("RelayHttp{status}"));
        }
        let mut bytes = zeroize::Zeroizing::new(Vec::new());
        response
            .take(3 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "RelayConnection")?;
        if bytes.len() > 3 * 1024 * 1024 {
            return invalid();
        }
        let value: Value = serde_json::from_slice(&bytes).map_err(|_| "InvalidData")?;
        if !value.is_object() {
            return invalid();
        }
        Ok(value)
    }
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
        sign_value(
            v,
            &unhex(text(&self.config, "secret_key")?)?,
            text(&self.config, "device")?,
        )
    }
    pub fn member(&self, n: &str) -> Result<Value> {
        let raw = unhex(text(&self.config, "secret_key")?)?;
        let sk = sodiumoxide::crypto::box_::SecretKey::from_slice(&raw).ok_or("InvalidData")?;
        let (pk, _) = signing(&raw)?;
        Ok(
            json!({"device":self.config["device"],"name":n,"public_key":hex(&sk.public_key().0),"signing_key":hex(&pk.0),"manager":false}),
        )
    }
    fn state(&self) -> Result<Value> {
        unpack(&self.config["group_entry"])
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
    fn publish(&mut self) -> Result<String> {
        let inv = &self.config["issued_invitation"];
        if let Some(link) = inv["short_link"].as_str() {
            return Ok(link.into());
        }
        // Keep packet/key stable across response loss and retries.
        if self.config.get("pending_link").is_none() {
            let key = sodiumoxide::randombytes::randombytes(32);
            let nonce = sodiumoxide::randombytes::randombytes(24);
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
        let (mut url, id, key, link_password) = parse_link(link.trim())?;
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
            None if self.config["url"] == url => configured_password(&self.config)?.map(str::to_owned),
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
            || inv["expires"].as_u64().unwrap_or(0) <= now()
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
            || inv["expires"].as_u64().unwrap_or(0) <= now()
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
        self.refresh()?;
        self.manager()?;
        let req = unpack(&self.config["join_request"])?;
        let inv = &self.config["issued_invitation"];
        if inv["expires"].as_u64().unwrap_or(0) <= now() || req["invitation"] != inv["id"] {
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
        self.change(state)?;
        erase(&mut self.config, "issued_invitation");
        erase(&mut self.config, "join_request");
        self.persist()
    }
    pub fn cancel(&mut self) -> Result<()> {
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
            let mut state = self.state()?;
            if disband {
                self.manager()?;
            }
            let own = self.config["device"].clone();
            let members = state["members"].as_array_mut().ok_or("InvalidData")?;
            members.retain(|m| !disband && m["device"] != own);
            if members.is_empty() {
                state["closed"] = json!(true);
            }
            state["invitation"] = json!("");
            state["request_hash"] = json!("");
            state["revision"] = json!(state["revision"].as_u64().ok_or("InvalidData")? + 1);
            state["previous"] = json!(digest(&payload(&self.config["group_entry"])?));
            let e = self.sign(&state)?;
            advance(&self.config["group_entry"], &e)?;
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
