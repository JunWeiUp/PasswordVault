//! The durable group state machine lives in the common-relay Rust SDK
//! (`common_relay::Groups`). This adapter keeps vault-core's string error codes
//! (`InvalidData`, `RelayHttp409`, `ApprovalPending`, `LastManager`, ...) and its
//! string-coded transport trait, so desktop, Android and iOS callers stay unchanged.
use crate::relay_net::code;
use serde_json::Value;

/// Errors are relay error codes (`InvalidData`, `RelayHttp409`, `ApprovalPending`, ...).
pub type Result<T> = std::result::Result<T, String>;

pub use common_relay::unix_now as now;

/// Group HTTP transport with string error codes (see [`crate::relay_net::http::Http`]).
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

/// A vault-core error code as an SDK error (inverse of `relay_net::code`).
fn sdk_error(code: String) -> common_relay::Error {
    match code.strip_prefix("RelayHttp").and_then(|s| s.parse().ok()) {
        Some(status) => common_relay::Error::Http(status),
        None => common_relay::Error::Relay(code),
    }
}

struct Bridge<'b, A: Api>(&'b A);
impl<A: Api> common_relay::GroupApi for Bridge<'_, A> {
    fn call(
        &self,
        c: &Value,
        method: &str,
        path: &str,
        body: Option<Value>,
        auth: Option<String>,
    ) -> common_relay::Result<Value> {
        self.0.call(c, method, path, body, auth).map_err(sdk_error)
    }
}

pub struct Groups<'a, A: Api> {
    pub config: Value,
    pub api: A,
    pub save: &'a mut dyn FnMut(&Value) -> Result<()>,
    pub local: bool,
}

impl<A: Api> Groups<'_, A> {
    fn with<T>(
        &mut self,
        f: impl FnOnce(&mut common_relay::Groups<'_, Bridge<'_, A>>) -> common_relay::Result<T>,
    ) -> Result<T> {
        let Groups {
            config,
            api,
            save,
            local,
        } = self;
        let mut save = |c: &Value| save(c).map_err(sdk_error);
        let mut inner = common_relay::Groups {
            config: std::mem::take(config),
            api: Bridge(api),
            save: &mut save,
            local: *local,
        };
        let result = f(&mut inner);
        *config = inner.config;
        result.map_err(code)
    }
    pub fn member(&mut self, name: &str) -> Result<Value> {
        self.with(|g| g.member(name))
    }
    pub fn refresh(&mut self) -> Result<Value> {
        self.with(|g| g.refresh())
    }
    pub fn create(&mut self, title: &str, device_name: &str) -> Result<()> {
        self.with(|g| g.create(title, device_name))
    }
    pub fn invite(&mut self, mode: &str) -> Result<String> {
        self.with(|g| g.invite(mode))
    }
    pub fn publish(&mut self) -> Result<String> {
        self.with(|g| g.publish())
    }
    pub fn resolve(&mut self, link: &str, typed: Option<&str>) -> Result<Value> {
        self.with(|g| g.resolve(link, typed))
    }
    pub fn resolve_with(
        &mut self,
        link: &str,
        typed: Option<&str>,
        override_password: Option<&str>,
    ) -> Result<Value> {
        self.with(|g| g.resolve_with(link, typed, override_password))
    }
    pub fn join(&mut self, inv: Value, name: &str) -> Result<bool> {
        self.with(|g| g.join(inv, name))
    }
    pub fn finish_join(&mut self) -> Result<bool> {
        self.with(|g| g.finish_join())
    }
    pub fn pending(&mut self) -> Result<()> {
        self.with(|g| g.pending())
    }
    pub fn code(&mut self) -> Result<String> {
        self.with(|g| g.code())
    }
    pub fn approve(&mut self, code: &str, manager: bool) -> Result<()> {
        self.with(|g| g.approve(code, manager))
    }
    pub fn cancel(&mut self) -> Result<()> {
        self.with(|g| g.cancel())
    }
    pub fn rename(&mut self, device: &str, name: &str) -> Result<()> {
        self.with(|g| g.rename(device, name))
    }
    pub fn remove(&mut self, device: &str) -> Result<()> {
        self.with(|g| g.remove(device))
    }
    pub fn check_exit(&mut self, disband: bool) -> Result<()> {
        self.with(|g| g.check_exit(disband))
    }
    pub fn exit(&mut self, disband: bool) -> Result<()> {
        self.with(|g| g.exit(disband))
    }
}
