//! Local security findings and k-anonymity range processing. No network side effects.
use crate::{Document, Result, VaultError};
use serde_json::{json, Value};
use sha1::{Digest, Sha1};
use std::collections::{BTreeMap, HashSet};

pub fn breach_request(password: &str) -> Value {
    let digest = hex::encode_upper(Sha1::digest(password.as_bytes()));
    json!({"prefix":&digest[..5],"suffix":&digest[5..]})
}
/// A valid successful response is necessary before claiming a password was not found.
pub fn breach_response(suffix: &str, response: &str) -> Result<u64> {
    if suffix.len() != 35
        || !suffix.bytes().all(|b| b.is_ascii_hexdigit())
        || response.len() > 4 * 1024 * 1024
        || response.trim().is_empty()
    {
        return Err(VaultError::InvalidData);
    }
    let mut count = 0;
    for line in response.lines() {
        let (candidate, value) = line.trim().split_once(':').ok_or(VaultError::InvalidData)?;
        if candidate.len() != 35 || !candidate.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(VaultError::InvalidData);
        }
        let occurrences = value.parse::<u64>().map_err(|_| VaultError::InvalidData)?;
        if candidate.eq_ignore_ascii_case(suffix) {
            count = count.max(occurrences);
        }
    }
    Ok(count)
}

/// Bundled public metadata is version-pinned and attributed. Absence never implies site safety.
pub fn bundled_security_catalog() -> Value {
    serde_json::from_str(include_str!("../data/security-catalog.json"))
        .expect("bundled catalog is validated in tests")
}

pub fn validate_security_catalog(catalog: &Value) -> Result<()> {
    if catalog["version"] != 1
        || catalog["license"].as_str().is_none_or(|s| s.is_empty())
        || !valid_date(&catalog["updatedAt"])
    {
        return Err(VaultError::InvalidData);
    }
    if let Some(sources) = catalog.get("sources") {
        for source in sources.as_array().ok_or(VaultError::InvalidData)? {
            let link = url::Url::parse(source["url"].as_str().unwrap_or(""))
                .map_err(|_| VaultError::InvalidData)?;
            if link.scheme() != "https" || link.host_str().is_none() || !source["name"].is_string()
            {
                return Err(VaultError::InvalidData);
            }
        }
    }
    let sites = catalog["sites"]
        .as_array()
        .filter(|v| v.len() <= 100_000)
        .ok_or(VaultError::InvalidData)?;
    let mut seen = HashSet::new();
    for site in sites {
        let host = site["host"].as_str().ok_or(VaultError::InvalidData)?;
        let parsed =
            url::Url::parse(&format!("https://{host}")).map_err(|_| VaultError::InvalidData)?;
        let source = url::Url::parse(site["source"].as_str().unwrap_or(""))
            .map_err(|_| VaultError::InvalidData)?;
        if parsed.host_str() != Some(host)
            || parsed.path() != "/"
            || parsed.port().is_some()
            || !parsed.username().is_empty()
            || !seen.insert(host)
            || source.scheme() != "https"
            || source.host_str().is_none()
            || !valid_date(&site["verifiedAt"])
        {
            return Err(VaultError::InvalidData);
        }
        for key in ["twoFactorSource", "passkeySource"] {
            if let Some(value) = site.get(key) {
                let link = url::Url::parse(value.as_str().unwrap_or(""))
                    .map_err(|_| VaultError::InvalidData)?;
                if link.scheme() != "https" || link.host_str().is_none() {
                    return Err(VaultError::InvalidData);
                }
            }
        }
        for key in ["twoFactor", "passkey"] {
            if site.get(key).is_some_and(|v| !v.is_boolean()) {
                return Err(VaultError::InvalidData);
            }
        }
        if let Some(incidents) = site.get("incidents") {
            for incident in incidents.as_array().ok_or(VaultError::InvalidData)? {
                let link = url::Url::parse(incident["source"].as_str().unwrap_or(""))
                    .map_err(|_| VaultError::InvalidData)?;
                if link.scheme() != "https"
                    || !valid_date(&incident["date"])
                    || !incident["title"].is_string()
                {
                    return Err(VaultError::InvalidData);
                }
            }
        }
    }
    Ok(())
}
fn valid_date(value: &Value) -> bool {
    value
        .as_str()
        .is_some_and(|v| chrono::NaiveDate::parse_from_str(v, "%Y-%m-%d").is_ok())
}

pub fn security_audit(document: &Document, catalog: Option<&Value>) -> Result<Value> {
    let bundled = bundled_security_catalog();
    let catalog = catalog.unwrap_or(&bundled);
    validate_security_catalog(catalog)?;
    let mut findings = crate::audit(&document.items)
        .as_array()
        .cloned()
        .unwrap_or_default();
    for finding in &mut findings {
        finding["kind"] = json!("passwordHealth");
        finding["key"] = json!(format!(
            "{}:passwordHealth",
            finding["id"].as_str().unwrap_or("")
        ));
    }
    let mut duplicates: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for item in document.items.iter().filter(|v| v["isDeleted"] != true) {
        let mut content = item.clone();
        if let Some(obj) = content.as_object_mut() {
            for key in [
                "id",
                "createdAt",
                "updatedAt",
                "lastAccessedAt",
                "isFavorite",
                "isPinned",
                "importSource",
            ] {
                obj.remove(key);
            }
        }
        duplicates
            .entry(content.to_string())
            .or_default()
            .push(item["id"].as_str().unwrap_or("").to_owned());
        if item["type"] != "password" {
            continue;
        }
        let host = url::Url::parse(item["url"].as_str().unwrap_or(""))
            .ok()
            .and_then(|url| url.host_str().map(str::to_owned));
        let site = catalog["sites"]
            .as_array()
            .unwrap()
            .iter()
            .find(|site| site["host"].as_str() == host.as_deref());
        if let Some(site) = site {
            for (feature, kind) in [
                ("twoFactor", "twoFactorAvailable"),
                ("passkey", "passkeyAvailable"),
            ] {
                if site[feature] == true {
                    findings.push(json!({"id":item["id"],"title":item["title"],"kind":kind,"key":format!("{}:{kind}",item["id"].as_str().unwrap_or("")),"source":site.get(format!("{feature}Source")).unwrap_or(&site["source"]),"verifiedAt":site["verifiedAt"],"status":"suggestion","message":"Provider supports this method; account configuration has not been checked"}));
                }
            }
            for incident in site["incidents"].as_array().into_iter().flatten() {
                findings.push(json!({"id":item["id"],"title":item["title"],"kind":"siteIncident","key":format!("{}:siteIncident:{}",item["id"].as_str().unwrap_or(""),incident["source"].as_str().unwrap_or("")),"incident":incident,"status":"reviewNeeded"}));
            }
        }
    }
    for ids in duplicates.values().filter(|ids| ids.len() > 1) {
        for id in ids {
            findings.push(json!({"id":id,"kind":"duplicateEntry","key":format!("{id}:duplicateEntry"),"relatedIds":ids}));
        }
    }
    let ignored = document.settings["securityIgnored"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    for finding in &mut findings {
        finding["ignored"] = json!(ignored.contains(&finding["key"]));
    }
    Ok(
        json!({"findings":findings,"catalogUpdatedAt":catalog["updatedAt"],"catalogCoverage":catalog["coverage"],"catalogSources":catalog["sources"],"catalogLicense":catalog["license"],"catalogLicenseText":format!("{}\n\n{}",include_str!("../data/twofactorauth-LICENSE.md"),include_str!("../data/passkeys-LICENSE.md")),"networkBreachStatus":"notChecked","siteCoverageStatus":"limited; unlisted sites are not checked"}),
    )
}

pub fn set_security_ignored(document: &mut Document, key: &str, ignored: bool) -> Result<()> {
    if key.is_empty() || key.len() > 4096 {
        return Err(VaultError::InvalidData);
    }
    let mut keys = document.settings["securityIgnored"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    keys.retain(|v| v != key);
    if ignored {
        keys.push(json!(key));
    }
    if keys.len() > 100_000 {
        return Err(VaultError::InvalidData);
    }
    document.settings["securityIgnored"] = json!(keys);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn breach_padding_and_errors_are_distinct_from_safe() {
        let q = breach_request("test-only-not-a-real-secret");
        let suffix = q["suffix"].as_str().unwrap();
        assert_eq!(q["prefix"].as_str().unwrap().len(), 5);
        assert_eq!(
            breach_response(suffix, &format!("{suffix}:12\r\n{}:0", "A".repeat(35))).unwrap(),
            12
        );
        assert!(breach_response(suffix, "<html>error</html>").is_err());
        assert!(breach_response(suffix, "").is_err());
    }
    #[test]
    fn suggestions_do_not_claim_account_status_and_ignore_is_reversible() {
        let mut doc = Document::default();
        doc.upsert(json!({"id":"a","type":"password","title":"Example","url":"https://github.com/login","username":"test","password":"long-test-password"})).unwrap();
        let audit = security_audit(&doc, None).unwrap();
        assert_eq!(audit["networkBreachStatus"], "notChecked");
        assert!(audit["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v["kind"] == "passkeyAvailable"));
        set_security_ignored(&mut doc, "a:passkeyAvailable", true).unwrap();
        assert!(security_audit(&doc, None).unwrap()["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v["key"] == "a:passkeyAvailable" && v["ignored"] == true));
        set_security_ignored(&mut doc, "a:passkeyAvailable", false).unwrap();
        assert!(doc.settings["securityIgnored"]
            .as_array()
            .unwrap()
            .is_empty());
    }
    #[test]
    fn catalog_requires_attribution_and_valid_host() {
        let mut catalog = bundled_security_catalog();
        assert!(validate_security_catalog(&catalog).is_ok());
        catalog["sites"][0]["host"] = json!("github.com/path");
        assert!(validate_security_catalog(&catalog).is_err());
    }
}
