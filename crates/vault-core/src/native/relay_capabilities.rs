//! Authenticated personal-relay format negotiation, independent of business grants.
use super::*;
use crypto_box::{
    aead::{Aead, AeadCore, OsRng},
    PublicKey, SalsaBox, SecretKey,
};

pub(super) struct Identity {
    group: String,
    device: String,
    secret: SecretKey,
    peers: BTreeMap<String, String>,
}
impl Identity {
    pub(super) fn parse(data: &str, state: &State) -> Result<Self> {
        let v: Value = serde_json::from_str(data).map_err(|_| VaultError::InvalidData)?;
        if v["group"] != state.group || v["device"] != state.device {
            return Err(VaultError::Authentication);
        }
        let secret = SecretKey::from(Self::key(string(&v, "secret")?)?);
        let group: Value = if let Some(encoded) = v["groupState"].as_str() {
            serde_json::from_slice(
                &STANDARD
                    .decode(encoded)
                    .map_err(|_| VaultError::Authentication)?,
            )
            .map_err(|_| VaultError::Authentication)?
        } else {
            v["groups"].clone()
        };
        let peers = if !group.is_null() {
            &group["trusted_peers"]
        } else {
            &v["peers"]
        };
        Ok(Self {
            group: state.group.clone(),
            device: state.device.clone(),
            secret,
            peers: serde_json::from_value(peers.clone()).map_err(|_| VaultError::Authentication)?,
        })
    }
    fn key(value: &str) -> Result<[u8; 32]> {
        let bytes = if value.len() == 64 {
            hex::decode(value).map_err(|_| VaultError::Authentication)?
        } else {
            STANDARD
                .decode(value)
                .map_err(|_| VaultError::Authentication)?
        };
        bytes.try_into().map_err(|_| VaultError::Authentication)
    }
    fn cipher(&self, peer: &str) -> Result<SalsaBox> {
        let key = self.peers.get(peer).ok_or(VaultError::Authentication)?;
        Ok(SalsaBox::new(
            &PublicKey::from(Self::key(key)?),
            &self.secret,
        ))
    }
    pub(super) fn binding(&self, peer: &str) -> Result<String> {
        let key = Self::key(self.peers.get(peer).ok_or(VaultError::Authentication)?)?;
        Ok(hex::encode(Sha256::digest(
            [self.secret.public_key().as_bytes().as_slice(), &key].concat(),
        )))
    }
    pub(super) fn ready(&self, state: &State, peer: &str) -> bool {
        self.binding(peer)
            .ok()
            .is_some_and(|key| state.capabilities.get(peer) == Some(&key))
    }
    pub(super) fn command(&self, state: &mut State, request: &Value) -> Result<Value> {
        let peer = string(request, "peer")?;
        if peer == self.device || !valid_name(peer) {
            return Err(VaultError::Authentication);
        }
        let cipher = self.cipher(peer)?;
        match string(request, "op")? {
            "relay-capabilities-challenge" => {
                let now = now()?;
                state.challenges.retain(|_, (_, expires)| *expires > now);
                let challenge = state
                    .challenges
                    .get(peer)
                    .map(|(c, _)| c.clone())
                    .unwrap_or_else(new_id);
                if state.challenges.len() >= 1024 && !state.challenges.contains_key(peer) {
                    return Err(VaultError::InvalidData);
                }
                state
                    .challenges
                    .entry(peer.into())
                    .or_insert((challenge.clone(), now + 120));
                Ok(json!({"challenge":challenge}))
            }
            "relay-capabilities-prove" => {
                let challenge = string(request, "challenge")?;
                if !valid_name(challenge) {
                    return Err(VaultError::InvalidData);
                }
                let payload = serde_json::to_vec(&json!({"domain":"passwordvault-personal-capabilities-v2","group":self.group,"hub":state.hub,"from":self.device,"to":peer,"challenge":challenge,"protocol":2,"format":7})).map_err(|_| VaultError::InvalidData)?;
                let nonce = SalsaBox::generate_nonce(&mut OsRng);
                let ciphertext = cipher
                    .encrypt(&nonce, payload.as_slice())
                    .map_err(|_| VaultError::Authentication)?;
                Ok(
                    json!({"proof":{"nonce":STANDARD.encode(nonce),"ciphertext":STANDARD.encode(ciphertext)}}),
                )
            }
            "relay-capabilities-accept" => {
                let proof = &request["proof"];
                let nonce: [u8; 24] = STANDARD
                    .decode(string(proof, "nonce")?)
                    .map_err(|_| VaultError::Authentication)?
                    .try_into()
                    .map_err(|_| VaultError::Authentication)?;
                let encoded = string(proof, "ciphertext")?;
                if encoded.len() > 4096 {
                    return Err(VaultError::InvalidData);
                }
                let ciphertext = STANDARD
                    .decode(encoded)
                    .map_err(|_| VaultError::Authentication)?;
                let plain = Zeroizing::new(
                    cipher
                        .decrypt((&nonce).into(), ciphertext.as_slice())
                        .map_err(|_| VaultError::Authentication)?,
                );
                let payload: Value =
                    serde_json::from_slice(&plain).map_err(|_| VaultError::Authentication)?;
                let (challenge, expires) = state
                    .challenges
                    .get(peer)
                    .ok_or(VaultError::Authentication)?;
                if *expires <= now()? {
                    return Err(VaultError::Authentication);
                }
                if payload
                    != json!({"domain":"passwordvault-personal-capabilities-v2","group":self.group,"hub":state.hub,"from":peer,"to":self.device,"challenge":challenge,"protocol":2,"format":7})
                {
                    return Err(VaultError::Authentication);
                }
                state.capabilities.insert(peer.into(), self.binding(peer)?);
                state.challenges.remove(peer);
                Ok(json!({"ok":true}))
            }
            _ => Err(VaultError::Unsupported),
        }
    }
}

fn now() -> Result<u64> {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .map_err(|_| VaultError::Authentication)
}
