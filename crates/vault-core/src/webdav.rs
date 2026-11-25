//! Shared HTTPS WebDAV backup client and RFC 4918 multistatus XML listing parser
//! used by Desktop (macOS/Windows), iOS, and Android.
//!
//! All network calls run outside the vault session lock. Security invariants:
//! - Remote servers require HTTPS (loopback HTTP is allowed only when explicitly opted in).
//! - Embedded URL credentials, queries, fragments, path traversal (`..`, `.`, `\`, `%`),
//!   and cross-origin or out-of-folder targets are rejected.
//! - Redirects are disabled (`Policy::none()`), XML external entities are rejected, and
//!   response sizes are bounded (4 MiB for PROPFIND XML, 128 MiB for backup archives).

use reqwest::{blocking::Client, Method, Url};
use serde_json::{json, Value};
use std::{collections::HashSet, io::Read, time::Duration};
use zeroize::Zeroizing;

const MAX_ARCHIVE_BYTES: u64 = 128 * 1024 * 1024;
const MAX_LISTING_BYTES: u64 = 4 * 1024 * 1024;

/// A WebDAV failure carrying a stable machine code (`WebDAVAuthentication`, `WebDAVPermission`,
/// `WebDAVNotFound`, `AlreadyExists`, `WebDAVRedirectRejected`, `WebDAVNetwork`, `WebDAVServer`,
/// `InvalidData`, `Storage`).
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum WebDavError {
    #[error("{code}")]
    Failed { code: String },
}

impl From<&str> for WebDavError {
    fn from(code: &str) -> Self {
        Self::Failed {
            code: code.to_owned(),
        }
    }
}

impl From<String> for WebDavError {
    fn from(code: String) -> Self {
        Self::Failed { code }
    }
}

pub type WebDavResult<T> = std::result::Result<T, WebDavError>;

fn err(code: &str) -> WebDavError {
    WebDavError::Failed {
        code: code.to_owned(),
    }
}

fn is_loopback_host(host: Option<&str>) -> bool {
    matches!(host, Some("localhost" | "127.0.0.1" | "::1" | "[::1]"))
}

/// Validates and normalizes the WebDAV base folder URL from a JSON config object
/// (`{"url", "folder"?, "allowLoopbackHttp"?}`).
pub fn base_url(config: &Value) -> WebDavResult<Url> {
    let raw = config["url"].as_str().ok_or_else(|| err("InvalidData"))?;
    let allow_loopback = config["allowLoopbackHttp"].as_bool().unwrap_or(false);
    let mut u = Url::parse(raw).map_err(|_| err("InvalidData"))?;
    let scheme_ok = u.scheme() == "https"
        || (allow_loopback && u.scheme() == "http" && is_loopback_host(u.host_str()));
    if !scheme_ok
        || u.host_str().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
    {
        return Err(err("InvalidData"));
    }
    let folder = config["folder"].as_str().unwrap_or("PasswordVault");
    if folder.starts_with('/')
        || folder
            .split('/')
            .any(|s| s == ".." || s == "." || s.contains(['\\', '%']))
    {
        return Err(err("InvalidData"));
    }
    {
        let mut segments = u.path_segments_mut().map_err(|_| err("InvalidData"))?;
        segments.pop_if_empty();
        for part in folder.split('/').filter(|s| !s.is_empty()) {
            segments.push(part);
        }
        segments.push("");
    }
    Ok(u)
}

/// Resolves `href` relative to `base` and verifies same-origin, within-folder,
/// no credentials/query/fragment, and no path traversal.
pub fn trusted_url(base: &Url, href: &str) -> WebDavResult<Url> {
    let decoded = percent_encoding::percent_decode_str(href)
        .decode_utf8()
        .map_err(|_| err("InvalidData"))?;
    if decoded.contains(['\\', '%']) || decoded.split('/').any(|s| s == ".." || s == ".") {
        return Err(err("InvalidData"));
    }
    let u = base.join(href).map_err(|_| err("InvalidData"))?;
    if u.origin() != base.origin()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
        || !u.path().starts_with(base.path())
    {
        return Err(err("InvalidData"));
    }
    Ok(u)
}

fn read_limited(reader: impl Read, limit: u64) -> WebDavResult<Zeroizing<Vec<u8>>> {
    let mut bytes = Zeroizing::new(Vec::new());
    reader
        .take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| err("Storage"))?;
    if bytes.len() as u64 > limit {
        return Err(err("InvalidData"));
    }
    Ok(bytes)
}

struct DavClient {
    client: Client,
    base: Url,
    username: String,
    password: Zeroizing<String>,
}

impl DavClient {
    fn from_config(config: &Value) -> WebDavResult<Self> {
        let base = base_url(config)?;
        let https_only = base.scheme() == "https";
        Ok(Self {
            client: Client::builder()
                .https_only(https_only)
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(90))
                .build()
                .map_err(|_| err("Storage"))?,
            base,
            username: config["username"].as_str().unwrap_or("").into(),
            password: Zeroizing::new(config["password"].as_str().unwrap_or("").into()),
        })
    }

    fn request(&self, method: &str, url: Url, body: Vec<u8>) -> WebDavResult<Zeroizing<Vec<u8>>> {
        trusted_url(&self.base, url.as_str())?;
        let mut req = self
            .client
            .request(
                Method::from_bytes(method.as_bytes()).map_err(|_| err("InvalidData"))?,
                url,
            )
            .basic_auth(&self.username, Some(self.password.as_str()));
        if method == "PROPFIND" {
            req = req
                .header("Depth", "1")
                .header("Content-Type", "application/xml");
        }
        if method == "PUT" {
            req = req
                .header("If-None-Match", "*")
                .header("Content-Type", "application/octet-stream");
        }
        let response = req.body(body).send().map_err(|_| err("WebDAVNetwork"))?;
        let status = response.status().as_u16();
        if !(200..300).contains(&status) && !(method == "MKCOL" && status == 405) {
            return Err(err(match status {
                401 => "WebDAVAuthentication",
                403 => "WebDAVPermission",
                404 => "WebDAVNotFound",
                412 => "AlreadyExists",
                300..=399 => "WebDAVRedirectRejected",
                _ => "WebDAVServer",
            }));
        }
        read_limited(
            response,
            if method == "PROPFIND" {
                MAX_LISTING_BYTES
            } else {
                MAX_ARCHIVE_BYTES
            },
        )
    }
}

fn status_is_2xx(status: &str) -> bool {
    status.split_whitespace().nth(1).is_some_and(|code| {
        code.len() == 3 && code.starts_with('2') && code.bytes().all(|b| b.is_ascii_digit())
    })
}

/// Parses an RFC 4918 WebDAV multistatus XML listing against `base`.
/// When `strict_hrefs` is true, any untrusted href fails the listing; when false,
/// untrusted hrefs are skipped while valid in-folder entries are retained.
pub fn parse_listing(base: &Url, xml: &str, strict_hrefs: bool) -> WebDavResult<String> {
    if xml.len() as u64 > MAX_LISTING_BYTES * 2 {
        return Err(err("InvalidData"));
    }
    let doc = roxmltree::Document::parse(xml).map_err(|_| err("InvalidData"))?;
    if !doc.root_element().has_tag_name(("DAV:", "multistatus")) {
        return Err(err("InvalidData"));
    }
    let mut seen = HashSet::new();
    let mut rows = Vec::new();
    for response in doc
        .root_element()
        .children()
        .filter(|n| n.has_tag_name(("DAV:", "response")))
    {
        if let Some(resp_status) = response
            .children()
            .find(|n| n.has_tag_name(("DAV:", "status")))
            .and_then(|n| n.text())
        {
            if !status_is_2xx(resp_status) {
                continue;
            }
        }
        let href = match response
            .children()
            .find(|n| n.has_tag_name(("DAV:", "href")))
            .and_then(|n| n.text())
        {
            Some(h) => h.trim(),
            None if strict_hrefs => return Err(err("InvalidData")),
            None => continue,
        };
        let u = match trusted_url(base, href) {
            Ok(u) => u,
            Err(e) if strict_hrefs => return Err(e),
            Err(_) => continue,
        };
        if u == *base || u.path().ends_with('/') {
            continue;
        }
        let name = percent_encoding::percent_decode_str(u.path().rsplit('/').next().unwrap_or(""))
            .decode_utf8()
            .map_err(|_| err("InvalidData"))?
            .to_string();
        if ![".pvbackup", ".json", ".bak"]
            .iter()
            .any(|ext| name.to_lowercase().ends_with(ext))
        {
            continue;
        }
        let mut modified = None;
        let mut created = None;
        let mut size = None;
        let mut collection = false;
        let mut saw_propstat = false;
        let mut success = false;
        for ps in response
            .children()
            .filter(|n| n.has_tag_name(("DAV:", "propstat")))
        {
            saw_propstat = true;
            let status = ps
                .children()
                .find(|n| n.has_tag_name(("DAV:", "status")))
                .and_then(|n| n.text())
                .unwrap_or("");
            if !status_is_2xx(status) {
                continue;
            }
            success = true;
            for p in ps
                .children()
                .filter(|n| n.has_tag_name(("DAV:", "prop")))
                .flat_map(|n| n.children())
            {
                if p.tag_name().namespace() != Some("DAV:") {
                    continue;
                }
                match p.tag_name().name() {
                    "getlastmodified" => {
                        if let Some(t) = p.text().map(str::trim).filter(|s| !s.is_empty()) {
                            modified = Some(t);
                        }
                    }
                    "creationdate" => {
                        if let Some(t) = p.text().map(str::trim).filter(|s| !s.is_empty()) {
                            created = Some(t);
                        }
                    }
                    "getcontentlength" => {
                        if let Some(v) = p.text().map(str::trim).and_then(|s| s.parse::<u64>().ok())
                        {
                            size = Some(v);
                        }
                    }
                    "resourcetype" => {
                        collection |= p.children().any(|n| n.has_tag_name(("DAV:", "collection")));
                    }
                    _ => {}
                }
            }
        }
        if (success || !saw_propstat) && !collection && seen.insert(u.as_str().to_owned()) {
            rows.push(json!({
                "url": u.as_str(),
                "name": name,
                "modified": modified,
                "created": created,
                "size": size,
            }));
        }
    }
    Ok(json!(rows).to_string())
}

const PROPFIND_BODY: &[u8] = br#"<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getlastmodified/><d:creationdate/><d:getcontentlength/></d:prop></d:propfind>"#;

/// Lists backup files in the configured WebDAV folder as a JSON array of
/// `{url, name, modified, created, size}`.
#[uniffi::export]
pub fn webdav_list(config_json: String) -> WebDavResult<String> {
    let config_json = Zeroizing::new(config_json);
    let config: Value = serde_json::from_str(&config_json).map_err(|_| err("InvalidData"))?;
    let strict_hrefs = config["strictHrefs"].as_bool().unwrap_or(true);
    let dav = DavClient::from_config(&config)?;
    let bytes = dav.request("PROPFIND", dav.base.clone(), PROPFIND_BODY.to_vec())?;
    let xml = std::str::from_utf8(&bytes).map_err(|_| err("InvalidData"))?;
    parse_listing(&dav.base, xml, strict_hrefs)
}

/// Ensures the configured WebDAV folder exists (`MKCOL`) and uploads `data` to `filename`
/// with `If-None-Match: *` (never overwrites an existing backup).
#[uniffi::export]
pub fn webdav_upload(config_json: String, filename: String, data: Vec<u8>) -> WebDavResult<()> {
    let config_json = Zeroizing::new(config_json);
    let config: Value = serde_json::from_str(&config_json).map_err(|_| err("InvalidData"))?;
    if filename.is_empty()
        || filename == "."
        || filename == ".."
        || filename.contains(['/', '\\', '%'])
    {
        return Err(err("InvalidData"));
    }
    let dav = DavClient::from_config(&config)?;
    dav.request("MKCOL", dav.base.clone(), Vec::new())?;
    let target = dav.base.join(&filename).map_err(|_| err("InvalidData"))?;
    dav.request("PUT", target, data)?;
    Ok(())
}

/// Downloads a backup archive at `target_url` after verifying it belongs to the configured
/// WebDAV origin and folder.
#[uniffi::export]
pub fn webdav_download(config_json: String, target_url: String) -> WebDavResult<Vec<u8>> {
    let config_json = Zeroizing::new(config_json);
    let config: Value = serde_json::from_str(&config_json).map_err(|_| err("InvalidData"))?;
    let dav = DavClient::from_config(&config)?;
    let target = trusted_url(&dav.base, &target_url)?;
    let bytes = dav.request("GET", target, Vec::new())?;
    Ok(bytes.to_vec())
}

/// Pure RFC 4918 multistatus XML listing parser exposed for mobile tests and custom transports.
#[uniffi::export]
pub fn webdav_parse_listing(base: String, xml: String, strict_hrefs: bool) -> WebDavResult<String> {
    let mut url = Url::parse(&base).map_err(|_| err("InvalidData"))?;
    if !url.path().ends_with('/') {
        let mut segments = url.path_segments_mut().map_err(|_| err("InvalidData"))?;
        segments.push("");
    }
    parse_listing(&url, &xml, strict_hrefs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn origin_and_traversal_guards() {
        for url in [
            "http://127.0.0.1/dav/",
            "https://user:pass@example.test/",
            "https://example.test/?q=x",
        ] {
            assert!(base_url(&json!({"url": url})).is_err(), "{url}");
        }
        assert!(
            base_url(&json!({"url": "http://127.0.0.1/dav/", "allowLoopbackHttp": true})).is_ok()
        );
        assert!(
            base_url(&json!({"url": "http://example.test/dav/", "allowLoopbackHttp": true}))
                .is_err()
        );

        let root =
            base_url(&json!({"url": "https://example.test/dav/", "folder": "backups"})).unwrap();
        assert_eq!(root.as_str(), "https://example.test/dav/backups/");
        for href in [
            "https://evil.test/x.pvbackup",
            "../x.pvbackup",
            "%2e%2e/x.pvbackup",
            "%252e%252e/x.pvbackup",
            "/dav/backups2/x.pvbackup",
            "x.pvbackup?q=secret",
            "https://user@example.test/dav/backups/x",
        ] {
            assert!(trusted_url(&root, href).is_err(), "{href}");
        }
        assert!(trusted_url(&root, "a%20b.pvbackup").is_ok());
    }

    #[test]
    fn listing_respects_propstat_status_xxe_and_strict_mode() {
        let root = Url::parse("https://example.test/backups/").unwrap();
        let xml = r#"<d:multistatus xmlns:d="DAV:"><d:response><d:href>/backups/a.pvbackup</d:href><d:propstat><d:prop><d:getcontentlength>999</d:getcontentlength></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat><d:propstat><d:prop><d:getlastmodified>Thu, 05 Nov 2026 01:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"#;
        let rows: Value = serde_json::from_str(&parse_listing(&root, xml, true).unwrap()).unwrap();
        assert_eq!(rows[0]["name"], "a.pvbackup");
        assert!(rows[0]["size"].is_null());
        assert!(rows[0]["created"].is_null());
        // Strict mode rejects untrusted hrefs; non-strict skips them.
        let evil = xml.replace("/backups/a.pvbackup", "https://evil.test/a.pvbackup");
        assert!(parse_listing(&root, &evil, true).is_err());
        let skipped: Value =
            serde_json::from_str(&parse_listing(&root, &evil, false).unwrap()).unwrap();
        assert_eq!(skipped.as_array().unwrap().len(), 0);
        // XXE is always rejected.
        assert!(parse_listing(
            &root,
            "<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><x>&e;</x>",
            false,
        )
        .is_err());
    }
}
