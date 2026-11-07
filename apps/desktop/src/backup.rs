//! Local backup and HTTPS WebDAV. File content never crosses into JavaScript.
use crate::{Vault, error_code};
use base64::{Engine, engine::general_purpose::STANDARD};
use nsh_core::prelude::*;
use reqwest::{Method, Url, blocking::Client};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    path::Path,
    time::Duration,
};
use zeroize::Zeroizing;
const LIMIT: u64 = 128 * 1024 * 1024;
/// Local encrypted archives, reviewed imports and HTTPS WebDAV.
#[module]
pub struct Backup;
fn read(path: &str) -> Result<Zeroizing<Vec<u8>>, String> {
    let file = std::fs::File::open(path).map_err(|_| "Storage")?;
    if !file.metadata().map_err(|_| "Storage")?.is_file() {
        return Err("InvalidData".into());
    }
    limited(file, LIMIT)
}
fn limited(reader: impl Read, limit: u64) -> Result<Zeroizing<Vec<u8>>, String> {
    let mut bytes = Zeroizing::new(Vec::new());
    reader
        .take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "Storage")?;
    if bytes.len() as u64 > limit {
        return Err("InvalidData".into());
    }
    Ok(bytes)
}
fn command(session: &vault_core::VaultSession, value: Value) -> Result<String, String> {
    let request = Zeroizing::new(value.to_string());
    session.command(request.to_string()).map_err(error_code)
}
fn archive(session: &vault_core::VaultSession, password: &str) -> Result<String, String> {
    let response = command(
        session,
        json!({"op":"export","password":password,"richNotes":true}),
    )?;
    let value: Value = serde_json::from_str(&response).map_err(|_| "InvalidData")?;
    Ok(value["content"].as_str().ok_or("InvalidData")?.into())
}
fn merge(
    session: &vault_core::VaultSession,
    data: &[u8],
    password: &str,
) -> Result<String, String> {
    command(
        session,
        json!({"op":"import","content":std::str::from_utf8(data).map_err(|_| "InvalidData")?,"password":password,"richNotes":true}),
    )
}
fn base(config: &Value) -> Result<Url, String> {
    let mut u =
        Url::parse(config["url"].as_str().ok_or("InvalidData")?).map_err(|_| "InvalidData")?;
    if u.scheme() != "https"
        || u.host_str().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
    {
        return Err("InvalidData".into());
    }
    let folder = config["folder"].as_str().unwrap_or("PasswordVault");
    if folder.starts_with('/')
        || folder
            .split('/')
            .any(|s| s == ".." || s == "." || s.contains(['\\', '%']))
    {
        return Err("InvalidData".into());
    }
    {
        let mut segments = u.path_segments_mut().map_err(|_| "InvalidData")?;
        segments.pop_if_empty();
        for part in folder.split('/').filter(|s| !s.is_empty()) {
            segments.push(part);
        }
        segments.push("");
    }
    Ok(u)
}
fn trusted(base: &Url, href: &str) -> Result<Url, String> {
    let decoded = percent_encoding::percent_decode_str(href)
        .decode_utf8()
        .map_err(|_| "InvalidData")?;
    if decoded.contains(['\\', '%']) || decoded.split('/').any(|s| s == ".." || s == ".") {
        return Err("InvalidData".into());
    }
    let u = base.join(href).map_err(|_| "InvalidData")?;
    if u.origin() != base.origin()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
        || !u.path().starts_with(base.path())
    {
        return Err("InvalidData".into());
    }
    Ok(u)
}
struct Dav {
    client: Client,
    base: Url,
    username: String,
    password: Zeroizing<String>,
}
impl Dav {
    fn new(c: &Value) -> Result<Self, String> {
        Ok(Self {
            client: Client::builder()
                .https_only(true)
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(90))
                .build()
                .map_err(|_| "Storage")?,
            base: base(c)?,
            username: c["username"].as_str().unwrap_or("").into(),
            password: Zeroizing::new(c["password"].as_str().unwrap_or("").into()),
        })
    }
    fn request(&self, method: &str, url: Url, body: Vec<u8>) -> Result<Zeroizing<Vec<u8>>, String> {
        trusted(&self.base, url.as_str())?;
        let mut r = self
            .client
            .request(
                Method::from_bytes(method.as_bytes()).map_err(|_| "InvalidData")?,
                url,
            )
            .basic_auth(&self.username, Some(self.password.as_str()));
        if method == "PROPFIND" {
            r = r
                .header("Depth", "1")
                .header("Content-Type", "application/xml");
        }
        if method == "PUT" {
            r = r
                .header("If-None-Match", "*")
                .header("Content-Type", "application/octet-stream");
        }
        let response = r.body(body).send().map_err(|_| "WebDAVNetwork")?;
        let status = response.status().as_u16();
        if !(200..300).contains(&status) && !(method == "MKCOL" && status == 405) {
            return Err(match status {
                401 => "WebDAVAuthentication",
                403 => "WebDAVPermission",
                404 => "WebDAVNotFound",
                412 => "AlreadyExists",
                300..=399 => "WebDAVRedirectRejected",
                _ => "WebDAVServer",
            }
            .into());
        }
        limited(
            response,
            if method == "PROPFIND" {
                4 * 1024 * 1024
            } else {
                LIMIT
            },
        )
    }
    fn list(&self) -> Result<String, String> {
        let bytes = self.request("PROPFIND", self.base.clone(), br#"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getlastmodified/><d:creationdate/><d:getcontentlength/></d:prop></d:propfind>"#.to_vec())?;
        listing(
            &self.base,
            std::str::from_utf8(&bytes).map_err(|_| "InvalidData")?,
        )
    }
}
fn listing(base: &Url, xml: &str) -> Result<String, String> {
    let doc = roxmltree::Document::parse(xml).map_err(|_| "InvalidData")?;
    if !doc.root_element().has_tag_name(("DAV:", "multistatus")) {
        return Err("InvalidData".into());
    }
    let mut rows = Vec::new();
    for response in doc
        .root_element()
        .children()
        .filter(|n| n.has_tag_name(("DAV:", "response")))
    {
        let href = response
            .children()
            .find(|n| n.has_tag_name(("DAV:", "href")))
            .and_then(|n| n.text())
            .ok_or("InvalidData")?;
        let u = trusted(base, href)?;
        if u == *base {
            continue;
        }
        let name = percent_encoding::percent_decode_str(u.path().rsplit('/').next().unwrap_or(""))
            .decode_utf8()
            .map_err(|_| "InvalidData")?
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
        let mut success = false;
        for ps in response
            .children()
            .filter(|n| n.has_tag_name(("DAV:", "propstat")))
        {
            let status = ps
                .children()
                .find(|n| n.has_tag_name(("DAV:", "status")))
                .and_then(|n| n.text())
                .unwrap_or("");
            if !status
                .split_whitespace()
                .nth(1)
                .is_some_and(|s| s.starts_with('2'))
            {
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
                    "getlastmodified" => modified = p.text(),
                    "creationdate" => created = p.text(),
                    "getcontentlength" => size = p.text().and_then(|s| s.parse::<u64>().ok()),
                    "resourcetype" => {
                        collection = p.children().any(|n| n.has_tag_name(("DAV:", "collection")))
                    }
                    _ => {}
                }
            }
        }
        if success && !collection {
            rows.push(json!({"url":u.as_str(),"name":name,"modified":modified,"created":created,"size":size}));
        }
    }
    Ok(json!(rows).to_string())
}
fn write_new(path: &Path, bytes: &[u8]) -> Result<(), String> {
    #[cfg(unix)]
    use std::os::unix::fs::OpenOptionsExt;
    let parent = path.parent().ok_or("InvalidData")?;
    let staging = parent.join(format!(".pvbackup-{}.tmp", uuid::Uuid::new_v4()));
    let result: Result<(), &str> = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)] options.mode(0o600);
        let mut file = options.open(&staging)
            .map_err(|_| "Storage")?;
        file.write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| "Storage")?;
        // Linking is atomic and fails if the destination already exists, including symlinks.
        std::fs::hard_link(&staging, path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::AlreadyExists {
                "AlreadyExists"
            } else {
                "Storage"
            }
        })?;
        Ok(())
    })();
    let _ = std::fs::remove_file(staging);
    result.map_err(String::from)
}
fn structured_file(
    session: &vault_core::VaultSession,
    path: &str,
    options: &str,
) -> Result<String, String> {
    let mut value: Value = serde_json::from_str(&options).map_err(|_| "InvalidData")?;
    if !["import-preview", "import-commit"].contains(&value["op"].as_str().unwrap_or("")) {
        return Err("InvalidData".into());
    }
    let data = read(&path)?;
    use sha2::{Digest, Sha256};
    let fingerprint = format!("{:x}", Sha256::digest(&*data));
    if value["op"] == "import-commit" && value["fingerprint"] != fingerprint {
        return Err("StaleEdit".into());
    }
    value["data"] = json!(STANDARD.encode(&*data));
    value["richNotes"] = json!(true);
    let result = command(&session, value)?;
    let mut result: Value = serde_json::from_str(&result).map_err(|_| "InvalidData")?;
    result["fingerprint"] = json!(fingerprint);
    // Preview exposes summaries, never passwords or retained source material.
    if let Some(rows) = result["rows"].as_array_mut() {
        for row in rows {
            let i = &row["item"];
            row["item"] = json!({"title":i["title"],"type":i["type"],"username":i["username"],"url":i["url"]});
        }
    }
    Ok(result.to_string())
}
#[module]
impl Backup {
    /// Writes a complete encrypted archive to a new destination.
    pub async fn export_file(
        vault: Instance<Vault>,
        path: String,
        password: String,
    ) -> Result<(), String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            let password = Zeroizing::new(password);
            let content = archive(&session, &password)?;
            write_new(Path::new(&path), content.as_bytes())
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }
    /// Merges a local archive through the shared core.
    pub async fn import_file(
        vault: Instance<Vault>,
        path: String,
        password: String,
    ) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || merge(&session, &read(&path)?, &Zeroizing::new(password)))
            .await
            .map_err(|_| "Storage".to_string())?
    }
    /// Previews summaries or commits a fingerprint-bound CSV/1PUX source.
    pub async fn structured(
        vault: Instance<Vault>,
        path: String,
        options: String,
    ) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || structured_file(&session, &path, &options))
            .await
            .map_err(|_| "Storage".to_string())?
    }
    /// Saves encrypted configuration, lists, uploads, or restores via HTTPS.
    pub async fn webdav(vault: Instance<Vault>, options: String) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            let status: Value = serde_json::from_str(&command(&session, json!({"op":"status"}))?).map_err(|_| "InvalidData")?;
            if status["unlocked"] != true { return Err("Locked".into()); }
            let options = Zeroizing::new(options);
            let o: Value = serde_json::from_str(&options).map_err(|_| "InvalidData")?;
            let dav = Dav::new(&o["config"])?;
            match o["action"].as_str().unwrap_or("") {
                "save" => command(
                    &session,
                    json!({"op":"settings","settings":{"webdav":o["config"]}}),
                ),
                "list" => dav.list(),
                "upload" => {
                    let content = archive(&session, o["password"].as_str().ok_or("InvalidData")?)?;
                    dav.request("MKCOL", dav.base.clone(), vec![])?;
                    let name = format!("PasswordVault-{}.pvbackup", uuid::Uuid::new_v4());
                    dav.request(
                        "PUT",
                        dav.base.join(&name).map_err(|_| "InvalidData")?,
                        content.into_bytes(),
                    )?;
                    Ok(json!({"name":name}).to_string())
                }
                "restore" => {
                    let url = trusted(&dav.base, o["url"].as_str().ok_or("InvalidData")?)?;
                    let data = dav.request("GET", url, vec![])?;
                    merge(&session, &data, o["password"].as_str().unwrap_or(""))
                }
                _ => Err("InvalidData".into()),
            }
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn backup_dav_origin_and_traversal_guards() {
        for url in [
            "http://127.0.0.1/dav/",
            "https://user:pass@example.test/",
            "https://example.test/?q=x",
        ] {
            assert!(base(&json!({"url":url})).is_err());
        }
        let root = base(&json!({"url":"https://example.test/dav/","folder":"backups"})).unwrap();
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
            assert!(trusted(&root, href).is_err(), "{href}");
        }
        assert!(trusted(&root, "a%20b.pvbackup").is_ok());
    }
    #[test]
    fn backup_listing_uses_only_successful_properties_and_reports_unknowns() {
        let root = Url::parse("https://example.test/backups/").unwrap();
        let xml = r#"<d:multistatus xmlns:d="DAV:"><d:response><d:href>/backups/a.pvbackup</d:href><d:propstat><d:prop><d:getcontentlength>999</d:getcontentlength></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat><d:propstat><d:prop><d:getlastmodified>Thu, 05 Nov 2026 01:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"#;
        let rows: Value = serde_json::from_str(&listing(&root, xml).unwrap()).unwrap();
        assert_eq!(rows[0]["name"], "a.pvbackup");
        assert!(rows[0]["size"].is_null());
        assert!(rows[0]["created"].is_null());
        assert!(
            listing(
                &root,
                &xml.replace("/backups/a.pvbackup", "https://evil.test/a.pvbackup")
            )
            .is_err()
        );
        assert!(
            listing(
                &root,
                "<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><x>&e;</x>"
            )
            .is_err()
        );
    }
    #[test]
    fn backup_archive_round_trip_wrong_password_and_settings() {
        let root = std::env::temp_dir().join(format!("pv-backup-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let source =
            vault_core::VaultSession::new(root.join("source").to_string_lossy().into()).unwrap();
        let destination =
            vault_core::VaultSession::new(root.join("destination").to_string_lossy().into())
                .unwrap();
        for s in [&source, &destination] {
            command(s, json!({"op":"create","password":"synthetic-master"})).unwrap();
        }
        command(&source,json!({"op":"save","item":{"id":"fixture","type":"password","title":"Synthetic","username":"example","password":"synthetic-secret"},"richNotes":true})).unwrap();
        command(&source,json!({"op":"settings","settings":{"webdav":{"url":"https://example.test/","username":"synthetic-user","password":"synthetic-dav-secret","folder":"backups"}}})).unwrap();
        let bytes = archive(&source, "synthetic-backup-password").unwrap();
        assert!(!bytes.contains("synthetic-dav-secret"));
        assert!(merge(&destination, bytes.as_bytes(), "wrong").is_err());
        let before: Value = serde_json::from_str(
            &command(&destination, json!({"op":"list","richNotes":true})).unwrap(),
        )
        .unwrap();
        assert!(before["items"].as_array().unwrap().is_empty());
        merge(&destination, bytes.as_bytes(), "synthetic-backup-password").unwrap();
        let after: Value = serde_json::from_str(
            &command(&destination, json!({"op":"list","richNotes":true})).unwrap(),
        )
        .unwrap();
        assert_eq!(after["items"][0]["title"], "Synthetic");
        let file = root.join("archive.pvbackup");
        write_new(&file, bytes.as_bytes()).unwrap();
        assert!(write_new(&file, b"replacement").is_err());
        assert_eq!(&*read(file.to_str().unwrap()).unwrap(), bytes.as_bytes());
        assert!(limited(&b"12345"[..], 4).is_err());
        drop(source);
        drop(destination);
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[cfg(test)]
mod import_tests {
    use super::*;
    #[test]
    fn backup_review_masks_secrets_rejects_changed_source_and_skips_duplicates() {
        let root = std::env::temp_dir().join(format!("pv-import-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let session =
            vault_core::VaultSession::new(root.join("vault").to_string_lossy().into()).unwrap();
        command(
            &session,
            json!({"op":"create","password":"synthetic-master"}),
        )
        .unwrap();
        let path = root.join("source.csv");
        let path = path.to_str().unwrap();
        let source = "name,username,password,url\nExample,test,synthetic-secret,https://example.test\nExample,test,synthetic-secret,https://example.test\n";
        std::fs::write(path, source).unwrap();
        let preview = structured_file(
            &session,
            path,
            &json!({"op":"import-preview","format":"csv"}).to_string(),
        )
        .unwrap();
        assert!(!preview.contains("synthetic-secret"));
        let preview: Value = serde_json::from_str(&preview).unwrap();
        assert_eq!(preview["rows"].as_array().unwrap().len(), 2);
        assert!(
            !preview["rows"][1]["duplicateIds"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        let options =
            json!({"op":"import-commit","format":"csv","fingerprint":preview["fingerprint"]})
                .to_string();
        std::fs::write(path, source.replace("Example", "Changed")).unwrap();
        assert_eq!(
            structured_file(&session, path, &options).unwrap_err(),
            "StaleEdit"
        );
        std::fs::write(path, source).unwrap();
        structured_file(&session, path, &options).unwrap();
        let doc: Value = serde_json::from_str(
            &command(&session, json!({"op":"list","richNotes":true})).unwrap(),
        )
        .unwrap();
        assert_eq!(doc["items"].as_array().unwrap().len(), 1);
        drop(session);
        std::fs::remove_dir_all(root).unwrap();
    }
}
