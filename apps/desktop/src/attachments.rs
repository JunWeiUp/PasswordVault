//! Owner-bound encrypted attachments. Only verified raster images cross to JS.
use crate::{Vault, error_code};
use nsh_core::prelude::*;
use std::io::Read;
use zeroize::Zeroizing;

/// Encrypted note attachments owned by the current vault session.
#[module]
pub struct Attachments;

fn image_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if bytes.starts_with(b"\xff\xd8\xff") {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some("image/gif")
    } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        Some("image/webp")
    } else {
        None
    }
}
fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let n = ((c[0] as u32) << 16)
            | ((c.get(1).copied().unwrap_or(0) as u32) << 8)
            | c.get(2).copied().unwrap_or(0) as u32;
        out.push(TABLE[((n >> 18) & 63) as usize] as char);
        out.push(TABLE[((n >> 12) & 63) as usize] as char);
        out.push(if c.len() > 1 {
            TABLE[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if c.len() > 2 {
            TABLE[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}

#[module]
impl Attachments {
    /// Imports a local file without passing its plaintext through JS. Returns metadata JSON.
    pub async fn import_file(
        vault: Instance<Vault>,
        note_id: String,
        path: String,
    ) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            const LIMIT: u64 = 25 * 1024 * 1024;
            let path = std::path::PathBuf::from(path);
            let file = std::fs::File::open(&path).map_err(|_| "Storage")?;
            let meta = file.metadata().map_err(|_| "Storage")?;
            if !meta.is_file() || meta.len() > LIMIT {
                return Err("InvalidData".into());
            }
            let mut data = Zeroizing::new(Vec::new());
            file.take(LIMIT + 1)
                .read_to_end(&mut data)
                .map_err(|_| "Storage")?;
            if data.len() as u64 > LIMIT {
                return Err("InvalidData".into());
            }
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .ok_or("InvalidData")?
                .to_string();
            let mime = image_mime(&data)
                .unwrap_or("application/octet-stream")
                .to_string();
            session
                .import_note_attachment(note_id, name, mime, data.to_vec())
                .map_err(error_code)
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }
    /// Reads an owner-bound raster only; never returns arbitrary files or SVG/HTML.
    pub async fn read_image(
        vault: Instance<Vault>,
        note_id: String,
        id: String,
    ) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            let data = Zeroizing::new(
                session
                    .read_note_attachment(note_id, id)
                    .map_err(error_code)?,
            );
            let mime = image_mime(&data).ok_or("Unsupported")?;
            Ok(format!("data:{mime};base64,{}", base64(&data)))
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }
    /// Discards an unreferenced import. Core refuses referenced or wrong-owner IDs.
    pub async fn discard(
        vault: Instance<Vault>,
        note_id: String,
        id: String,
    ) -> Result<(), String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            session
                .discard_note_attachment(note_id, id)
                .map_err(error_code)
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn raster_and_encoding() {
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(image_mime(b"<svg/>"), None);
        assert_eq!(image_mime(b"<html>"), None);
        assert_eq!(image_mime(b"RIFF1234WEBP"), Some("image/webp"));
    }
}

#[cfg(test)]
mod ownership_tests {
    use super::*;
    use serde_json::{Value, json};
    #[test]
    fn encrypted_attachment_owner_lock_and_reference_guards() {
        let output = std::process::Command::new("mktemp")
            .args(["-d", "/tmp/pv-nsh-attachment-test.XXXXXX"])
            .output()
            .unwrap();
        assert!(output.status.success());
        let directory = String::from_utf8(output.stdout).unwrap().trim().to_string();
        let session = vault_core::VaultSession::new(format!("{directory}/vault")).unwrap();
        let run = |v: Value| session.command(v.to_string()).unwrap();
        run(json!({"op":"create", "password":"attachment-test-password"}));
        for id in ["owner", "other"] {
            run(
                json!({"op":"save", "richNotes":true, "item":{"id":id,"type":"secureNote","title":id,"note":"","noteFormat":"plain"}}),
            );
        }
        let bytes = b"\x89PNG\r\n\x1a\nsynthetic-image-canary";
        let meta: Value = serde_json::from_str(
            &session
                .import_note_attachment(
                    "owner".into(),
                    "fixture.png".into(),
                    "image/png".into(),
                    bytes.to_vec(),
                )
                .unwrap(),
        )
        .unwrap();
        let id = meta["id"].as_str().unwrap().to_string();
        assert!(
            session
                .read_note_attachment("other".into(), id.clone())
                .is_err()
        );
        assert_eq!(
            session
                .read_note_attachment("owner".into(), id.clone())
                .unwrap(),
            bytes
        );
        run(
            json!({"op":"save", "richNotes":true,"item":{"id":"owner","type":"secureNote","title":"owner","note":"fixture","noteFormat":"rich-v1","noteDocument":{"type":"doc","content":[{"type":"vaultImage","attrs":{"attachmentId":id,"name":"fixture.png","mime":"image/png","width":600,"caption":""}}]}}}),
        );
        assert!(
            session
                .discard_note_attachment("owner".into(), id.clone())
                .is_err()
        );
        run(json!({"op":"lock"}));
        assert!(
            session
                .read_note_attachment("owner".into(), id.clone())
                .is_err()
        );
        run(json!({"op":"unlock","password":"attachment-test-password","richNotes":true}));
        assert_eq!(
            session.read_note_attachment("owner".into(), id).unwrap(),
            bytes
        );
        drop(session);
        std::fs::remove_dir_all(directory).unwrap();
    }
}
