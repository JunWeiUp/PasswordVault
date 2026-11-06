//! Authenticated, causal replication. Relay membership never grants library access.
//! State is confidential and must be persisted encrypted by the host.
use crate::{new_id, random_bytes, Result, VaultError};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use zeroize::Zeroize;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum LibraryRole {
    Admin,
    Editor,
    Reader,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Member {
    pub public_key: String,
    #[serde(default)]
    pub transport_key: String,
    pub role: LibraryRole,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Control {
    pub library: String,
    pub generation: u64,
    pub parent: String,
    pub author: String,
    pub members: BTreeMap<String, Member>,
    pub checkpoint: BTreeMap<String, String>,
    pub signature: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Operation {
    pub library: String,
    pub id: String,
    pub generation: u64,
    pub author: String,
    pub key: String,
    pub captured_at: u64,
    pub parents: BTreeSet<String>,
    pub value: Value,
    pub signature: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PeerPacket {
    pub version: u32,
    pub library: String,
    pub controls: Vec<Control>,
    pub operations: Vec<Operation>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerReplica {
    pub library: String,
    pub device: String,
    secret: [u8; 32],
    pub controls: Vec<Control>,
    pub operations: BTreeMap<String, Operation>,
    #[serde(default)]
    pub frozen: bool,
}
impl Drop for PeerReplica {
    fn drop(&mut self) {
        self.secret.zeroize();
    }
}
fn bytes<T: Serialize>(v: &T) -> Result<Vec<u8>> {
    serde_json::to_vec(v).map_err(|_| VaultError::InvalidData)
}
fn digest<T: Serialize>(v: &T) -> Result<String> {
    Ok(hex::encode(Sha256::digest(bytes(v)?)))
}
fn control_body(c: &Control) -> Result<Vec<u8>> {
    bytes(&(
        "PasswordVault-control-v2",
        &c.library,
        c.generation,
        &c.parent,
        &c.author,
        &c.members,
        &c.checkpoint,
    ))
}
fn normalized_value(mut value: Value) -> Result<Value> {
    fn visit(value: &mut Value, depth: usize) -> Result<()> {
        if depth > 64 {
            return Err(VaultError::InvalidData);
        }
        match value {
            Value::Number(number) => {
                const SAFE: f64 = 9_007_199_254_740_991.0;
                if number.as_u64().is_some_and(|n| n > 9_007_199_254_740_991)
                    || number
                        .as_i64()
                        .is_some_and(|n| n.unsigned_abs() > 9_007_199_254_740_991)
                {
                    return Err(VaultError::InvalidData);
                }
                let n = number.as_f64().ok_or(VaultError::InvalidData)?;
                if !n.is_finite() || n.abs() > SAFE {
                    return Err(VaultError::InvalidData);
                }
                // JSONValue/JSONEncoder/JSON.stringify erase 1.0 vs 1 and -0 vs 0.
                if n.fract() == 0.0 {
                    *value = serde_json::json!(n as i64);
                }
            }
            Value::Array(values) => {
                for child in values {
                    visit(child, depth + 1)?;
                }
            }
            Value::Object(values) => {
                for child in values.values_mut() {
                    visit(child, depth + 1)?;
                }
            }
            _ => {}
        }
        Ok(())
    }
    visit(&mut value, 0)?;
    Ok(value)
}
fn operation_digest(operation: &Operation) -> Result<String> {
    let mut canonical = operation.clone();
    canonical.value = normalized_value(canonical.value)?;
    digest(&canonical)
}
fn op_body(o: &Operation) -> Result<Vec<u8>> {
    bytes(&(
        "PasswordVault-operation-v2",
        &o.library,
        &o.id,
        o.generation,
        &o.author,
        &o.key,
        o.captured_at,
        &o.parents,
        &normalized_value(o.value.clone())?,
    ))
}
fn verify(public: &str, message: &[u8], signature: &str) -> Result<()> {
    let public: [u8; 32] = hex::decode(public)
        .map_err(|_| VaultError::Authentication)?
        .try_into()
        .map_err(|_| VaultError::Authentication)?;
    let signature =
        Signature::from_slice(&hex::decode(signature).map_err(|_| VaultError::Authentication)?)
            .map_err(|_| VaultError::Authentication)?;
    VerifyingKey::from_bytes(&public)
        .map_err(|_| VaultError::Authentication)?
        .verify_strict(message, &signature)
        .map_err(|_| VaultError::Authentication)
}
fn operation_order(
    incoming: &BTreeMap<String, Operation>,
    known: &BTreeMap<String, Operation>,
) -> Result<Vec<String>> {
    let mut remaining: BTreeMap<String, usize> = BTreeMap::new();
    let mut followers: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut ready = BTreeSet::new();
    for (id, operation) in incoming {
        let mut count = 0;
        for parent in &operation.parents {
            let ancestor = known
                .get(parent)
                .or_else(|| incoming.get(parent))
                .ok_or(VaultError::InvalidData)?;
            if ancestor.key != operation.key || ancestor.generation > operation.generation {
                return Err(VaultError::Authentication);
            }
            if !known.contains_key(parent) {
                count += 1;
                followers
                    .entry(parent.clone())
                    .or_default()
                    .push(id.clone());
            }
        }
        remaining.insert(id.clone(), count);
        if count == 0 {
            ready.insert(id.clone());
        }
    }
    let mut order = Vec::with_capacity(incoming.len());
    while let Some(id) = ready.pop_first() {
        order.push(id.clone());
        if let Some(children) = followers.remove(&id) {
            for child in children {
                let count = remaining.get_mut(&child).ok_or(VaultError::InvalidData)?;
                *count -= 1;
                if *count == 0 {
                    ready.insert(child);
                }
            }
        }
    }
    if order.len() != incoming.len() {
        return Err(VaultError::InvalidData);
    }
    Ok(order)
}
impl PeerReplica {
    pub fn identity(device: String) -> Result<Self> {
        if device.is_empty() || device.len() > 128 {
            return Err(VaultError::InvalidData);
        }
        Ok(Self {
            library: String::new(),
            device,
            secret: random_bytes(),
            controls: vec![],
            operations: BTreeMap::new(),
            frozen: false,
        })
    }
    pub fn public_key(&self) -> String {
        hex::encode(
            SigningKey::from_bytes(&self.secret)
                .verifying_key()
                .as_bytes(),
        )
    }
    pub fn create(device: String) -> Result<Self> {
        let mut s = Self::identity(device)?;
        s.library = new_id();
        let mut members = BTreeMap::new();
        members.insert(
            s.device.clone(),
            Member {
                public_key: s.public_key(),
                transport_key: String::new(),
                role: LibraryRole::Admin,
            },
        );
        s.append_control(members)?;
        Ok(s)
    }
    /// Restore authenticated backup data into a NEW independent library and identity.
    /// No old administrator, device credential or permission is impersonated.
    pub fn recover_copy(packet: &PeerPacket, device: String) -> Result<Self> {
        let mut checked = Self::identity("backup-validation".into())?;
        checked.library = packet.library.clone();
        checked.accept(packet, true)?;
        let mut result = Self::create(device)?;
        let mut waiting = std::mem::take(&mut checked.operations);
        let mut ids: BTreeMap<String, String> = BTreeMap::new();
        for old_id in operation_order(&waiting, &BTreeMap::new())? {
            let old = waiting.remove(&old_id).unwrap();
            let id = new_id();
            let mut operation = Operation {
                library: result.library.clone(),
                id: id.clone(),
                generation: 1,
                author: result.device.clone(),
                key: old.key,
                captured_at: old.captured_at,
                parents: old.parents.iter().map(|p| ids[p].clone()).collect(),
                value: old.value,
                signature: String::new(),
            };
            operation.signature = hex::encode(
                SigningKey::from_bytes(&result.secret)
                    .sign(&op_body(&operation)?)
                    .to_bytes(),
            );
            result.operations.insert(id.clone(), operation);
            ids.insert(old_id, id);
        }
        Ok(result)
    }
    /// Immutable, founder-signed enrollment scope. Missing scope is never sufficient
    /// to merge a new device's personal records into a library.
    pub fn scope(&self) -> Result<Option<bool>> {
        let mut scopes = self
            .operations
            .values()
            .filter(|o| o.key == "library-scope");
        let Some(scope) = scopes.next() else {
            return Ok(None);
        };
        if scopes.next().is_some()
            || !scope.parents.is_empty()
            || self
                .controls
                .first()
                .is_none_or(|c| scope.author != c.author)
        {
            return Err(VaultError::Authentication);
        }
        Ok(Some(scope.value.as_bool().ok_or(VaultError::InvalidData)?))
    }
    pub fn generation(&self) -> u64 {
        self.controls.last().map_or(0, |c| c.generation)
    }
    pub fn members(&self) -> Result<&BTreeMap<String, Member>> {
        self.controls
            .last()
            .map(|c| &c.members)
            .ok_or(VaultError::Authentication)
    }
    pub fn has_local_access(&self) -> bool {
        self.members().is_ok_and(|members| {
            members
                .get(&self.device)
                .is_some_and(|m| m.public_key == self.public_key())
        })
    }
    pub fn require_write_access(&self) -> Result<()> {
        self.writable()
    }
    fn writable(&self) -> Result<()> {
        if !self.has_local_access()
            || self.frozen
            || !matches!(
                self.members()?.get(&self.device).map(|m| &m.role),
                Some(LibraryRole::Admin | LibraryRole::Editor)
            )
        {
            return Err(VaultError::Authentication);
        }
        Ok(())
    }
    fn append_control(&mut self, members: BTreeMap<String, Member>) -> Result<()> {
        if self.controls.len() >= 10000 {
            return Err(VaultError::Unsupported);
        }
        if !members.values().any(|m| m.role == LibraryRole::Admin) || members.len() > 256 {
            return Err(VaultError::InvalidData);
        }
        for (id, m) in &members {
            if id.is_empty()
                || id.len() > 128
                || hex::decode(&m.public_key).map_or(true, |b| b.len() != 32)
            {
                return Err(VaultError::InvalidData);
            }
        }
        let mut c = Control {
            library: self.library.clone(),
            generation: self.generation() + 1,
            parent: self
                .controls
                .last()
                .map(digest)
                .transpose()?
                .unwrap_or_default(),
            author: self.device.clone(),
            members,
            checkpoint: self
                .operations
                .iter()
                .map(|(id, o)| Ok((id.clone(), operation_digest(o)?)))
                .collect::<Result<_>>()?,
            signature: String::new(),
        };
        c.signature = hex::encode(
            SigningKey::from_bytes(&self.secret)
                .sign(&control_body(&c)?)
                .to_bytes(),
        );
        self.controls.push(c);
        Ok(())
    }
    pub fn authorize(&mut self, device: String, member: Option<Member>) -> Result<()> {
        if !self.has_local_access()
            || self.frozen
            || self.members()?.get(&self.device).map(|m| &m.role) != Some(&LibraryRole::Admin)
        {
            return Err(VaultError::Authentication);
        }
        let mut members = self.members()?.clone();
        if let Some(member) = member {
            members.insert(device, member);
        } else {
            members.remove(&device);
        }
        self.append_control(members)
    }
    /// Explicit out-of-band approval of the library and founding administrator key.
    pub fn join(&mut self, packet: &PeerPacket, library: &str, founder_key: &str) -> Result<()> {
        if !self.controls.is_empty() || packet.library != library {
            return Err(VaultError::Authentication);
        }
        let first = packet.controls.first().ok_or(VaultError::InvalidData)?;
        if first.generation != 1
            || !first.parent.is_empty()
            || first.members.len() != 1
            || first
                .members
                .get(&first.author)
                .map(|m| (&m.public_key, &m.role))
                != Some((&founder_key.to_owned(), &LibraryRole::Admin))
        {
            return Err(VaultError::Authentication);
        }
        let mut next = self.clone();
        next.library = library.into();
        next.accept(packet, true)?;
        if next
            .members()?
            .get(&next.device)
            .map(|m| m.public_key.as_str())
            != Some(next.public_key().as_str())
        {
            return Err(VaultError::Authentication);
        }
        *self = next;
        Ok(())
    }
    pub fn write(&mut self, key: String, value: Value) -> Result<String> {
        self.write_with_parents(key, value, false)
    }
    /// Preserve pre-enrollment local data as a concurrent branch, never silently overwrite it.
    pub fn import_local(&mut self, key: String, value: Value) -> Result<String> {
        self.write_with_parents(key, value, true)
    }
    fn write_with_parents(
        &mut self,
        key: String,
        value: Value,
        concurrent: bool,
    ) -> Result<String> {
        self.writable()?;
        let value = normalized_value(value)?;
        if key == "library-scope"
            && (!self.operations.is_empty()
                || !value.is_boolean()
                || self
                    .controls
                    .first()
                    .is_none_or(|c| c.author != self.device))
        {
            return Err(VaultError::Authentication);
        }
        if key.is_empty() || key.len() > 512 || bytes(&value)?.len() > 16 * 1024 * 1024 {
            return Err(VaultError::InvalidData);
        }
        let mut o = Operation {
            library: self.library.clone(),
            id: new_id(),
            generation: self.generation(),
            author: self.device.clone(),
            captured_at: web_time::SystemTime::now()
                .duration_since(web_time::UNIX_EPOCH)
                .map_err(|_| VaultError::InvalidData)?
                .as_millis() as u64,
            parents: if concurrent {
                BTreeSet::new()
            } else {
                self.heads(&key).into_iter().map(|o| o.id.clone()).collect()
            },
            key,
            value,
            signature: String::new(),
        };
        o.signature = hex::encode(
            SigningKey::from_bytes(&self.secret)
                .sign(&op_body(&o)?)
                .to_bytes(),
        );
        let id = o.id.clone();
        self.operations.insert(id.clone(), o);
        Ok(id)
    }
    /// A draft may follow this device's own autosaves, but must not silently absorb
    /// revisions authored by another device since the draft was read.
    pub fn edit_base_matches(&self, key: &str, base: Option<&Value>) -> bool {
        let heads = self.heads(key);
        if heads.is_empty() {
            return base.is_none_or(|v| v.as_array().is_some_and(|a| a.is_empty()));
        }
        let Some(base) = base.and_then(Value::as_array) else {
            return false;
        };
        let mut stops = BTreeSet::new();
        for id in base {
            let Some(id) = id.as_str() else {
                return false;
            };
            if self.operations.get(id).is_none_or(|o| o.key != key) {
                return false;
            }
            stops.insert(id);
        }
        if stops.is_empty() {
            return false;
        }
        let mut stack: Vec<_> = heads.iter().map(|o| o.id.as_str()).collect();
        let mut visited = BTreeSet::new();
        while let Some(id) = stack.pop() {
            if stops.contains(id) || !visited.insert(id) {
                continue;
            }
            let Some(operation) = self.operations.get(id) else {
                return false;
            };
            if operation.author != self.device {
                return false;
            }
            stack.extend(operation.parents.iter().map(String::as_str));
        }
        true
    }
    pub fn heads(&self, key: &str) -> Vec<&Operation> {
        let retired: BTreeSet<_> = self
            .operations
            .values()
            .flat_map(|o| o.parents.iter())
            .collect();
        self.operations
            .values()
            .filter(|o| o.key == key && !retired.contains(&o.id))
            .collect()
    }
    fn head_groups(&self) -> BTreeMap<String, Vec<&Operation>> {
        let retired: BTreeSet<_> = self
            .operations
            .values()
            .flat_map(|o| o.parents.iter())
            .collect();
        let mut groups: BTreeMap<String, Vec<&Operation>> = BTreeMap::new();
        for operation in self.operations.values() {
            if !retired.contains(&operation.id) {
                groups
                    .entry(operation.key.clone())
                    .or_default()
                    .push(operation);
            }
        }
        groups
    }
    pub fn conflicts(&self) -> BTreeMap<String, Vec<&Operation>> {
        self.head_groups()
            .into_iter()
            .filter(|(_, heads)| heads.len() > 1)
            .collect()
    }
    pub fn resolved(&self) -> BTreeMap<String, Value> {
        self.head_groups()
            .into_iter()
            .filter_map(|(key, heads)| (heads.len() == 1).then(|| (key, heads[0].value.clone())))
            .collect()
    }
    pub fn export(&self, peer: &str) -> Result<PeerPacket> {
        if !self.has_local_access()
            || self.frozen
            || !self.members()?.contains_key(peer)
            || !self.members()?.contains_key(&self.device)
        {
            return Err(VaultError::Authentication);
        }
        Ok(PeerPacket {
            version: 2,
            library: self.library.clone(),
            controls: self.controls.clone(),
            operations: self.operations.values().cloned().collect(),
        })
    }
    pub fn receive(&mut self, packet: &PeerPacket) -> Result<()> {
        let mut next = self.clone();
        match next.accept(packet, false) {
            Ok(()) => {
                *self = next;
                Ok(())
            }
            Err(e) => {
                if next.frozen {
                    self.frozen = true;
                }
                Err(e)
            }
        }
    }
    fn accept(&mut self, packet: &PeerPacket, joining: bool) -> Result<()> {
        if self.frozen
            || packet.version != 2
            || packet.library != self.library
            || packet.controls.is_empty()
            || packet.controls.len() > 10000
            || packet.operations.len() > 100000
        {
            return Err(VaultError::Authentication);
        }
        for c in &packet.controls {
            if c.library != self.library || c.generation == 0 || c.generation > 10000 {
                return Err(VaultError::Authentication);
            }
            let index = (c.generation - 1) as usize;
            if index > self.controls.len() {
                return Err(VaultError::InvalidData);
            }
            let prior = if index == 0 {
                None
            } else {
                self.controls.get(index - 1)
            };
            let members = prior.map_or(&c.members, |p| &p.members);
            let author = members.get(&c.author).ok_or(VaultError::Authentication)?;
            if author.role != LibraryRole::Admin
                || c.parent != prior.map(digest).transpose()?.unwrap_or_default()
                || !c.members.values().any(|m| m.role == LibraryRole::Admin)
            {
                return Err(VaultError::Authentication);
            }
            verify(&author.public_key, &control_body(c)?, &c.signature)?;
            if let Some(known) = self.controls.get(index) {
                if digest(known)? != digest(c)? {
                    self.frozen = true;
                    return Err(VaultError::Authentication);
                }
            } else {
                self.controls.push(c.clone());
            }
        }
        if !joining && !self.members()?.contains_key(&self.device) {
            return Ok(());
        }
        let mut incoming = BTreeMap::new();
        for o in &packet.operations {
            if let Some(old) = self.operations.get(&o.id) {
                if operation_digest(old)? != operation_digest(o)? {
                    return Err(VaultError::Authentication);
                }
                continue;
            }
            if o.library != self.library
                || o.id.len() != 32
                || !o.id.bytes().all(|b| b.is_ascii_hexdigit())
                || o.key.is_empty()
                || o.key.len() > 512
                || bytes(&o.value)?.len() > 16 * 1024 * 1024
                || o.parents.contains(&o.id)
                || o.captured_at > 9_007_199_254_740_991
                || o.generation == 0
                || o.generation > self.generation()
            {
                return Err(VaultError::Authentication);
            }
            let old = self
                .controls
                .get((o.generation - 1) as usize)
                .and_then(|c| c.members.get(&o.author))
                .ok_or(VaultError::Authentication)?;
            let current = self.members()?.get(&o.author);
            let checkpointed = self.controls.iter().skip(o.generation as usize).any(|c| {
                c.checkpoint
                    .get(&o.id)
                    .is_some_and(|h| operation_digest(o).is_ok_and(|d| &d == h))
            });
            // Unknown old writes from revoked/downgraded identities are never replayed.
            if old.role == LibraryRole::Reader
                || (!checkpointed
                    && current.is_none_or(|m| {
                        m.role == LibraryRole::Reader || old.public_key != m.public_key
                    }))
            {
                return Err(VaultError::Authentication);
            }
            verify(&old.public_key, &op_body(o)?, &o.signature)?;
            let mut canonical = o.clone();
            canonical.value = normalized_value(canonical.value)?;
            if incoming.insert(o.id.clone(), canonical).is_some() {
                return Err(VaultError::InvalidData);
            }
        }
        // One dependency traversal, rather than repeatedly scanning a long linear history.
        for id in operation_order(&incoming, &self.operations)? {
            let operation = incoming.remove(&id).ok_or(VaultError::InvalidData)?;
            self.operations.insert(id, operation);
        }
        self.scope()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn pair() -> (PeerReplica, PeerReplica) {
        let mut a = PeerReplica::create("mac".into()).unwrap();
        let mut b = PeerReplica::identity("phone-a".into()).unwrap();
        a.authorize(
            b.device.clone(),
            Some(Member {
                transport_key: String::new(),
                public_key: b.public_key(),
                role: LibraryRole::Editor,
            }),
        )
        .unwrap();
        b.join(&a.export(&b.device).unwrap(), &a.library, &a.public_key())
            .unwrap();
        (a, b)
    }
    #[test]
    fn two_phones_sync_without_mac_and_keep_conflicts() {
        let (mut mac, mut a) = pair();
        let mut b = PeerReplica::identity("phone-b".into()).unwrap();
        mac.authorize(
            b.device.clone(),
            Some(Member {
                transport_key: String::new(),
                public_key: b.public_key(),
                role: LibraryRole::Editor,
            }),
        )
        .unwrap();
        a.receive(&mac.export(&a.device).unwrap()).unwrap();
        b.join(
            &mac.export(&b.device).unwrap(),
            &mac.library,
            &mac.public_key(),
        )
        .unwrap();
        drop(mac);
        a.write("item:x".into(), json!({"title":"one"})).unwrap();
        b.write("item:x".into(), Value::Null).unwrap();
        a.receive(&b.export(&a.device).unwrap()).unwrap();
        b.receive(&a.export(&b.device).unwrap()).unwrap();
        assert_eq!(a.conflicts()["item:x"].len(), 2);
        b.write("item:x".into(), json!({"title":"resolved"}))
            .unwrap();
        let packet = b.export(&a.device).unwrap();
        a.receive(&packet).unwrap();
        a.receive(&packet).unwrap();
        assert!(a.conflicts().is_empty());
        assert_eq!(a.operations.len(), 3);
        assert_eq!(a.resolved(), b.resolved());
    }
    #[test]
    fn unauthorized_reader_and_forgery_fail() {
        let (mut a, mut b) = pair();
        a.authorize(
            b.device.clone(),
            Some(Member {
                transport_key: String::new(),
                public_key: b.public_key(),
                role: LibraryRole::Reader,
            }),
        )
        .unwrap();
        b.receive(&a.export(&b.device).unwrap()).unwrap();
        assert!(b.write("x".into(), json!(1)).is_err());
        assert!(a.export("unapproved-group-member").is_err());
        let mut p = a.export(&b.device).unwrap();
        p.controls
            .last_mut()
            .unwrap()
            .members
            .get_mut(&b.device)
            .unwrap()
            .role = LibraryRole::Admin;
        assert!(b.receive(&p).is_err());
    }
    #[test]
    fn revoked_offline_writer_and_control_fork_fail_closed() {
        let (mut a, mut b) = pair();
        b.write("x".into(), json!(1)).unwrap();
        let p = b.export(&a.device).unwrap();
        a.authorize(b.device.clone(), None).unwrap();
        assert!(a.receive(&p).is_err());
        assert!(a.operations.is_empty());
        let (mut a, mut b) = pair();
        a.authorize(
            b.device.clone(),
            Some(Member {
                transport_key: String::new(),
                public_key: b.public_key(),
                role: LibraryRole::Admin,
            }),
        )
        .unwrap();
        b.receive(&a.export(&b.device).unwrap()).unwrap();
        a.authorize(
            "c".into(),
            Some(Member {
                transport_key: String::new(),
                public_key: hex::encode([1; 32]),
                role: LibraryRole::Reader,
            }),
        )
        .unwrap();
        b.authorize(
            "d".into(),
            Some(Member {
                transport_key: String::new(),
                public_key: hex::encode([2; 32]),
                role: LibraryRole::Reader,
            }),
        )
        .unwrap();
        assert!(a.receive(&b.export(&a.device).unwrap()).is_err());
        assert!(a.frozen);
        assert!(a.write("x".into(), json!(2)).is_err());
    }
    #[test]
    fn arbitrary_operation_order_and_missing_parent_are_atomic() {
        let (mut a, mut b) = pair();
        a.write("x".into(), json!(1)).unwrap();
        a.write("x".into(), json!(2)).unwrap();
        let mut p = a.export(&b.device).unwrap();
        p.operations.reverse();
        b.receive(&p).unwrap();
        assert_eq!(b.resolved()["x"], 2);
        let (mut a, mut b) = pair();
        a.write("x".into(), json!(1)).unwrap();
        a.write("x".into(), json!(2)).unwrap();
        let mut p = a.export(&b.device).unwrap();
        p.operations.retain(|o| !o.parents.is_empty());
        assert!(b.receive(&p).is_err());
        assert!(b.operations.is_empty());
    }
    #[test]
    fn explicit_founder_and_local_identity_are_required() {
        let (a, _) = pair();
        let mut outsider = PeerReplica::identity("outsider".into()).unwrap();
        let p = a.export("phone-a").unwrap();
        assert!(outsider.join(&p, &a.library, &a.public_key()).is_err());
        assert!(outsider.controls.is_empty());
        let mut b = PeerReplica::identity("phone-a".into()).unwrap();
        assert!(b.join(&p, &a.library, &a.public_key()).is_err());
    }
    #[test]
    fn long_history_uses_dependency_order_and_oversized_generations_do_not_freeze() {
        let mut operations = BTreeMap::new();
        for index in 0..10000 {
            let id = format!("{index:032x}");
            let parents = if index == 0 {
                BTreeSet::new()
            } else {
                BTreeSet::from([format!("{:032x}", index - 1)])
            };
            operations.insert(
                id.clone(),
                Operation {
                    library: "fixture".into(),
                    id,
                    generation: 1,
                    author: "fixture".into(),
                    key: "item".into(),
                    captured_at: 0,
                    parents,
                    value: Value::Null,
                    signature: String::new(),
                },
            );
        }
        let order = operation_order(&operations, &BTreeMap::new()).unwrap();
        assert_eq!(order.len(), 10000);
        assert_eq!(order[0], format!("{:032x}", 0));
        let (a, mut b) = pair();
        let mut control = a.controls[0].clone();
        control.generation = 4_294_967_297;
        control.signature = hex::encode(
            SigningKey::from_bytes(&a.secret)
                .sign(&control_body(&control).unwrap())
                .to_bytes(),
        );
        let packet = PeerPacket {
            version: 2,
            library: a.library.clone(),
            controls: vec![control],
            operations: vec![],
        };
        assert!(b.receive(&packet).is_err());
        assert!(!b.frozen);
    }
    #[test]
    fn integer_float_transport_reencoding_preserves_signatures_without_precision_loss() {
        let (mut a, mut b) = pair();
        a.write(
            "x".into(),
            json!({"width":1.0,"zero":-0.0,"fraction":0.125}),
        )
        .unwrap();
        let mut packet = a.export(&b.device).unwrap();
        packet.operations[0].value["width"] = json!(1.0);
        b.receive(&packet).unwrap();
        b.receive(&packet).unwrap();
        assert_eq!(b.resolved()["x"]["width"], 1);
        assert!(a
            .write("unsafe".into(), json!(9_007_199_254_740_993u64))
            .is_err());
    }
    #[test]
    fn editing_base_allows_own_autosave_but_rejects_remote_changes() {
        let (mut a, mut b) = pair();
        let initial = a.write("x".into(), json!(1)).unwrap();
        let base = json!([initial]);
        a.write("x".into(), json!(2)).unwrap();
        assert!(a.edit_base_matches("x", Some(&base)));
        b.receive(&a.export(&b.device).unwrap()).unwrap();
        b.write("x".into(), json!(3)).unwrap();
        a.receive(&b.export(&a.device).unwrap()).unwrap();
        assert!(!a.edit_base_matches("x", Some(&base)));
        assert!(!a.edit_base_matches("x", None));
    }
    #[test]
    fn revoked_author_checkpoint_is_available_to_new_reader() {
        let (mut a, mut b) = pair();
        b.write("x".into(), json!({"title":"kept history"}))
            .unwrap();
        a.receive(&b.export(&a.device).unwrap()).unwrap();
        a.authorize(b.device.clone(), None).unwrap();
        let mut reader = PeerReplica::identity("new-reader".into()).unwrap();
        a.authorize(
            reader.device.clone(),
            Some(Member {
                public_key: reader.public_key(),
                transport_key: String::new(),
                role: LibraryRole::Reader,
            }),
        )
        .unwrap();
        reader
            .join(
                &a.export(&reader.device).unwrap(),
                &a.library,
                &a.public_key(),
            )
            .unwrap();
        assert_eq!(reader.resolved()["x"]["title"], "kept history");
        assert!(reader.write("x".into(), Value::Null).is_err());
    }
    #[test]
    fn signed_value_tampering_does_not_modify_receiver() {
        let (mut a, mut b) = pair();
        a.write("x".into(), json!(1)).unwrap();
        let mut packet = a.export(&b.device).unwrap();
        packet.operations[0].value = json!("tampered");
        assert!(b.receive(&packet).is_err());
        assert!(b.operations.is_empty());
    }
}

/// Durable application-level fragmentation, shared by native and Web transports.
/// Chunks must arrive through an authenticated pairwise channel. They contain secrets.
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct ChunkAssembler {
    transfers: BTreeMap<String, ChunkTransfer>,
}
#[derive(Clone, Serialize, Deserialize)]
struct ChunkTransfer {
    library: String,
    digest: String,
    total: usize,
    count: usize,
    created: u64,
    parts: BTreeMap<usize, String>,
}
impl ChunkAssembler {
    pub fn ingest(&mut self, sender: &str, value: &Value) -> Result<Option<Value>> {
        use base64::Engine;
        let invalid = || VaultError::InvalidData;
        let transfer = value["transfer"].as_str().ok_or_else(invalid)?;
        let library = value["library"].as_str().ok_or_else(invalid)?;
        let digest = value["digest"].as_str().ok_or_else(invalid)?;
        let total = value["total"].as_u64().ok_or_else(invalid)? as usize;
        let count = value["count"].as_u64().ok_or_else(invalid)? as usize;
        let index = value["index"].as_u64().ok_or_else(invalid)? as usize;
        let data = value["data"].as_str().ok_or_else(invalid)?;
        if sender.is_empty()
            || sender.len() > 128
            || transfer.len() != 32
            || !transfer.bytes().all(|b| b.is_ascii_hexdigit())
            || library.len() > 128
            || digest.len() != 64
            || total > 48 * 1024 * 1024
            || total == 0
            || count == 0
            || count > 1024
            || index >= count
            || data.len() > 90_000
        {
            return Err(VaultError::InvalidData);
        }
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(data)
            .map_err(|_| VaultError::InvalidData)?;
        if bytes.is_empty() || bytes.len() > 64 * 1024 {
            return Err(VaultError::InvalidData);
        }
        let now = web_time::SystemTime::now()
            .duration_since(web_time::UNIX_EPOCH)
            .map_err(|_| VaultError::InvalidData)?
            .as_secs();
        self.transfers
            .retain(|_, t| now.saturating_sub(t.created) < 86400);
        let key = format!("{sender}:{transfer}");
        if !self.transfers.contains_key(&key)
            && (self.transfers.len() >= 4
                || self.transfers.values().map(|t| t.total).sum::<usize>() + total
                    > 64 * 1024 * 1024)
        {
            return Err(VaultError::InvalidData);
        }
        let state = self.transfers.entry(key).or_insert_with(|| ChunkTransfer {
            library: library.into(),
            digest: digest.into(),
            total,
            count,
            created: now,
            parts: BTreeMap::new(),
        });
        if state.library != library
            || state.digest != digest
            || state.total != total
            || state.count != count
        {
            return Err(VaultError::Authentication);
        }
        if let Some(existing) = state.parts.get(&index) {
            if existing != data {
                return Err(VaultError::Authentication);
            }
        } else {
            state.parts.insert(index, data.into());
        }
        if state.parts.len() != count {
            return Ok(None);
        }
        let mut combined = Vec::with_capacity(total);
        for part in state.parts.values() {
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(part)
                .map_err(|_| VaultError::InvalidData)?;
            if combined.len() + bytes.len() > total {
                return Err(VaultError::InvalidData);
            }
            combined.extend(bytes);
        }
        if combined.len() != total || hex::encode(Sha256::digest(combined.as_slice())) != digest {
            return Err(VaultError::Authentication);
        }
        let packet: Value =
            serde_json::from_slice(&combined).map_err(|_| VaultError::InvalidData)?;
        if packet["packet"]["library"] != library {
            return Err(VaultError::Authentication);
        }
        Ok(Some(packet))
    }
    pub fn forget(&mut self, sender: &str, transfer: &str) {
        self.transfers.remove(&format!("{sender}:{transfer}"));
    }
}

#[cfg(test)]
mod transport_tests {
    use super::*;
    use base64::Engine;
    use crypto_box::{aead::Aead, PublicKey, SalsaBox, SecretKey};
    #[test]
    fn libsodium_crypto_box_fixture_is_interoperable() {
        let public: [u8; 32] =
            hex::decode("a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209")
                .unwrap()
                .try_into()
                .unwrap();
        let cipher=hex::decode("4bcbd7f4fa89adc02fd777a0a8bdcb7b98091c6045625fd650221c2c4b86e28bab29d3c207666e92372edf32504958557be2b0c1708d8383795467333ebd0cc932f7b190442129f6047ead9e7d3bae4c5383319af2b0cc48718731169132d2b0e404f5eaf55d24d92c2154751a225d67859ec0cffa0eb749").unwrap();
        let crypt = SalsaBox::new(&PublicKey::from(public), &SecretKey::from([2; 32]));
        let plain = crypt.decrypt((&[3; 24]).into(), cipher.as_slice()).unwrap();
        let data: Value = serde_json::from_slice(&plain).unwrap();
        assert_eq!(data["value"]["data"], "Zml4dHVyZQ==");
    }
    #[test]
    fn fragmented_packets_survive_restart_and_reject_mixed_senders_and_bytes() {
        let packet = serde_json::json!({"packet":{"library":"family"},"data":"x".repeat(70000)});
        let data = serde_json::to_vec(&packet).unwrap();
        let digest = hex::encode(Sha256::digest(&data));
        let chunks:Vec<_>=data.chunks(65536).enumerate().map(|(index,part)|serde_json::json!({"protocol":"peer-v2-chunk","library":"family","transfer":"a".repeat(32),"digest":digest,"index":index,"count":2,"total":data.len(),"data":base64::engine::general_purpose::STANDARD.encode(part)})).collect();
        let mut assembler = ChunkAssembler::default();
        assert!(assembler.ingest("phone", &chunks[1]).unwrap().is_none());
        let mut restored: ChunkAssembler =
            serde_json::from_slice(&serde_json::to_vec(&assembler).unwrap()).unwrap();
        assert!(restored
            .ingest("other-phone", &chunks[0])
            .unwrap()
            .is_none());
        assert_eq!(
            restored.ingest("phone", &chunks[0]).unwrap().unwrap(),
            packet
        );
        let mut changed = chunks[0].clone();
        changed["data"] =
            serde_json::json!(base64::engine::general_purpose::STANDARD.encode("tamper"));
        assert!(restored.ingest("phone", &changed).is_err());
    }
}
