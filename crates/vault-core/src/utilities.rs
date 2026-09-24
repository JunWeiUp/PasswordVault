use crate::{random_bytes, Result, VaultError};
use data_encoding::BASE32_NOPAD;
use hmac::{Hmac, Mac};
use rand::{rngs::OsRng, seq::SliceRandom, Rng};
use serde_json::{json, Value};
use sha1::Sha1;
use url::Url;

pub fn new_id() -> String {
    hex::encode(random_bytes::<16>())
}

pub fn normalize_totp_secret(secret: &str) -> Result<String> {
    let normalized: String = secret
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .collect::<String>()
        .trim_end_matches('=')
        .to_ascii_uppercase();
    let bytes = BASE32_NOPAD
        .decode(normalized.as_bytes())
        .map_err(|_| VaultError::InvalidData)?;
    if bytes.is_empty() || bytes.len() > 256 {
        return Err(VaultError::InvalidData);
    }
    Ok(normalized)
}

pub fn totp(secret: &str, period: u64, time: u64) -> Result<String> {
    if period == 0 || period > 86400 {
        return Err(VaultError::InvalidData);
    }
    let secret = normalize_totp_secret(secret)?;
    let bytes = BASE32_NOPAD
        .decode(secret.as_bytes())
        .map_err(|_| VaultError::InvalidData)?;
    let mut mac =
        <Hmac<Sha1> as Mac>::new_from_slice(&bytes).map_err(|_| VaultError::InvalidData)?;
    mac.update(&(time / period).to_be_bytes());
    let hash = mac.finalize().into_bytes();
    let offset = (hash[19] & 15) as usize;
    let number = u32::from_be_bytes(hash[offset..offset + 4].try_into().unwrap()) & 0x7fff_ffff;
    Ok(format!("{:06}", number % 1_000_000))
}

pub fn parse_totp_uri(input: &str) -> Result<Value> {
    if input.len() > 8192 {
        return Err(VaultError::InvalidData);
    }
    let url = Url::parse(input).map_err(|_| VaultError::InvalidData)?;
    if url.scheme() != "otpauth"
        || url.host_str() != Some("totp")
        || url.fragment().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
    {
        return Err(VaultError::Unsupported);
    }
    let mut params = std::collections::HashMap::new();
    for (key, value) in url.query_pairs() {
        if params.insert(key.to_string(), value.to_string()).is_some() {
            return Err(VaultError::InvalidData);
        }
    }
    if params
        .get("algorithm")
        .is_some_and(|v| !v.eq_ignore_ascii_case("SHA1"))
        || params.get("digits").is_some_and(|v| v != "6")
        || params.contains_key("counter")
    {
        return Err(VaultError::Unsupported);
    }
    let label = url
        .path()
        .strip_prefix('/')
        .ok_or(VaultError::InvalidData)?;
    if label.is_empty() || label.contains('/') {
        return Err(VaultError::InvalidData);
    }
    let decoded =
        url::form_urlencoded::parse(format!("label={}", label.replace('+', "%2B")).as_bytes())
            .next()
            .ok_or(VaultError::InvalidData)?
            .1
            .into_owned();
    let (label_issuer, account) = decoded
        .split_once(':')
        .map(|(a, b)| (Some(a), b))
        .unwrap_or((None, &decoded));
    if account.trim().is_empty() {
        return Err(VaultError::InvalidData);
    }
    let issuer = params
        .get("issuer")
        .map(String::as_str)
        .or(label_issuer)
        .unwrap_or(account);
    if label_issuer.is_some_and(|v| v != issuer) {
        return Err(VaultError::InvalidData);
    }
    let period: u64 = params
        .get("period")
        .map(|v| v.parse().map_err(|_| VaultError::InvalidData))
        .transpose()?
        .unwrap_or(30);
    if period == 0 || period > 86400 {
        return Err(VaultError::InvalidData);
    }
    let secret = normalize_totp_secret(params.get("secret").ok_or(VaultError::InvalidData)?)?;
    Ok(
        json!({"id":new_id(),"type":"totp","title":issuer,"username":account,"secret":secret,"period":period}),
    )
}

pub fn generate_password(
    length: usize,
    upper: bool,
    lower: bool,
    digits: bool,
    symbols: bool,
) -> Result<String> {
    if !(4..=128).contains(&length) {
        return Err(VaultError::InvalidData);
    }
    let choices: Vec<&[u8]> = [
        (upper, b"ABCDEFGHIJKLMNOPQRSTUVWXYZ".as_slice()),
        (lower, b"abcdefghijklmnopqrstuvwxyz".as_slice()),
        (digits, b"0123456789".as_slice()),
        (symbols, b"!@#$%^&*()-_=+[]{};:,.?".as_slice()),
    ]
    .into_iter()
    .filter_map(|(yes, c)| yes.then_some(c))
    .collect();
    if choices.is_empty() {
        return Err(VaultError::InvalidData);
    }
    let mut rng = OsRng;
    let all: Vec<u8> = choices.iter().flat_map(|s| s.iter().copied()).collect();
    let mut result: Vec<u8> = choices
        .iter()
        .map(|s| s[rng.gen_range(0..s.len())])
        .collect();
    while result.len() < length {
        result.push(all[rng.gen_range(0..all.len())]);
    }
    result.shuffle(&mut rng);
    String::from_utf8(result).map_err(|_| VaultError::InvalidData)
}

pub fn matching_accounts(items: &[Value], origin: &str) -> Result<Value> {
    let origin = Url::parse(origin).map_err(|_| VaultError::InvalidData)?;
    if !["https", "http"].contains(&origin.scheme()) || origin.host_str().is_none() {
        return Err(VaultError::InvalidData);
    }
    let host = origin.host_str().unwrap();
    let result: Vec<Value> = items
        .iter()
        .filter(|v| v["type"] == "password" && v["isDeleted"] != true)
        .filter(|v| {
            v["url"].as_str().is_some_and(|s| {
                s.split(|c: char| c.is_whitespace() || c == ',')
                    .any(|entry| {
                        Url::parse(entry)
                            .or_else(|_| Url::parse(&format!("https://{entry}")))
                            .is_ok_and(|u| {
                                ["https", "http"].contains(&u.scheme())
                                    && u.host_str() == Some(host)
                                    && (u.scheme() != "https" || origin.scheme() == "https")
                            })
                    })
            })
        })
        .map(|v| json!({"id":v["id"],"title":v["title"],"username":v["username"]}))
        .collect();
    let mut all = result;
    for item in items {
        if !all.iter().any(|v| v["id"] == item["id"]) {
            continue;
        }
        if let Some(accounts) = item["accounts"].as_array() {
            for account in accounts {
                if account["id"].as_str().is_some_and(|s| !s.is_empty()) {
                    all.push(json!({"id":item["id"],"accountId":account["id"],"title":item["title"],"username":account["username"]}));
                }
            }
        }
    }
    Ok(json!(all))
}

pub fn audit(items: &[Value]) -> Value {
    let active: Vec<&Value> = items
        .iter()
        .filter(|v| v["type"] == "password" && v["isDeleted"] != true)
        .collect();
    let mut accounts = Vec::new();
    for item in &active {
        accounts.push((*item, *item));
        if let Some(additional) = item["accounts"].as_array() {
            for account in additional {
                accounts.push((*item, account));
            }
        }
    }
    let now = web_time::SystemTime::now()
        .duration_since(web_time::UNIX_EPOCH)
        .map(|v| v.as_millis() as i64)
        .unwrap_or(0);
    let mut results = Vec::new();
    for item in active {
        let own: Vec<_> = accounts
            .iter()
            .filter(|(parent, _)| parent["id"] == item["id"])
            .collect();
        let weak = own
            .iter()
            .any(|(_, account)| account["password"].as_str().unwrap_or("").chars().count() < 12);
        let reused = own.iter().any(|(_, account)| {
            let pass = account["password"].as_str().unwrap_or("");
            !pass.is_empty()
                && accounts
                    .iter()
                    .filter(|(_, other)| other["password"].as_str() == Some(pass))
                    .count()
                    > 1
        });
        let expired = own.iter().any(|(_, account)| {
            let days = item["passwordDuration"].as_i64().unwrap_or(0);
            let value = json!({"updatedAt":account["passwordLastChanged"]});
            let changed = crate::timestamp(&value);
            days > 0
                && days <= 36500
                && changed > 0
                && now > changed.saturating_add(days * 86_400_000)
        });
        if weak || reused || expired {
            results.push(json!({"id":item["id"],"title":item["title"],"weak":weak,"reused":reused,"expired":expired}));
        }
    }
    json!(results)
}

pub fn fill_account(
    items: &[Value],
    origin: &str,
    id: &str,
    account_id: Option<&str>,
) -> Result<Value> {
    let matches = matching_accounts(items, origin)?;
    if !matches
        .as_array()
        .unwrap()
        .iter()
        .any(|v| v["id"] == id && v["accountId"].as_str() == account_id)
    {
        return Err(VaultError::Authentication);
    }
    let item = items
        .iter()
        .find(|v| v["id"] == id)
        .ok_or(VaultError::InvalidData)?;
    let account = if let Some(account_id) = account_id {
        item["accounts"]
            .as_array()
            .and_then(|a| a.iter().find(|v| v["id"] == account_id))
            .ok_or(VaultError::InvalidData)?
    } else {
        item
    };
    Ok(json!({"username":account["username"],"password":account["password"]}))
}
