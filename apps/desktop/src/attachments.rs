//! Owner-bound encrypted attachments: 100 MiB chunked blobs, three-tier external open,
//! change watching, encrypted write-back, local text preview and zero-trace session cleanup.
use crate::{Vault, asset_sessions, error_code, text_extract};
use image::GenericImageView;
use nsh_core::prelude::*;
use serde_json::{Value, json};
use std::io::{Cursor, Read};
use zeroize::Zeroizing;

const THUMB_MAX_EDGE: u32 = 400;
const CACHE_EXCERPT_CHARS: usize = 4000;
const CACHE_SOURCE_LIMIT: u64 = 32 * 1024 * 1024;

/// Builds a compact <=400px L2 raster thumbnail as a base64 data URL.
/// Returns `(data_url, width, height, is_downscaled)`.
pub(crate) fn build_thumbnail(bytes: &[u8]) -> Option<(String, u32, u32, bool)> {
    let mime = image_mime(bytes)?;
    let img = image::load_from_memory(bytes).ok()?;
    let (w, h) = img.dimensions();
    if w == 0 || h == 0 {
        return None;
    }
    let downscaled = w > THUMB_MAX_EDGE || h > THUMB_MAX_EDGE;
    if !downscaled && bytes.len() <= 48 * 1024 {
        return Some((format!("data:{mime};base64,{}", base64(bytes)), w, h, false));
    }
    let resized = if downscaled {
        img.resize(
            THUMB_MAX_EDGE,
            THUMB_MAX_EDGE,
            image::imageops::FilterType::Triangle,
        )
    } else {
        img
    };
    let (tw, th) = resized.dimensions();
    let mut encoded = Vec::new();
    let mut cursor = Cursor::new(&mut encoded);
    // Encode as JPEG (quality 80) for compact L2 thumbnails; fall back to PNG if needed.
    let rgb = resized.to_rgb8();
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut cursor, 80);
    if enc
        .encode(&rgb, tw, th, image::ExtendedColorType::Rgb8)
        .is_ok()
    {
        return Some((
            format!("data:image/jpeg;base64,{}", base64(&encoded)),
            tw,
            th,
            downscaled,
        ));
    }
    encoded.clear();
    if resized
        .write_to(&mut Cursor::new(&mut encoded), image::ImageFormat::Png)
        .is_ok()
    {
        return Some((
            format!("data:image/png;base64,{}", base64(&encoded)),
            tw,
            th,
            downscaled,
        ));
    }
    None
}

fn populate_import_cache(
    session: &crate::session::VaultSession,
    note_id: &str,
    attachment_id: &str,
    path: &std::path::Path,
    name: &str,
    mime: &str,
    size: u64,
) {
    if size == 0 || size > CACHE_SOURCE_LIMIT {
        return;
    }
    let is_img = mime.starts_with("image/");
    let is_text = text_extract::can_extract_text(name, mime);
    if !is_img && !is_text {
        return;
    }
    let Ok(mut file) = crate::platform::open_regular_readonly(path) else {
        return;
    };
    let mut buf = Zeroizing::new(Vec::with_capacity(size.min(4 * 1024 * 1024) as usize));
    if file.read_to_end(&mut buf).is_err() {
        return;
    }
    let mut req = json!({
        "op": "note-attachment-cache-put",
        "noteId": note_id,
        "id": attachment_id,
    });
    let mut any = false;
    if is_img {
        if let Some((data_url, tw, th, _)) = build_thumbnail(&buf) {
            req["thumb"] = json!({"dataUrl": data_url, "width": tw, "height": th});
            any = true;
        }
    } else if is_text {
        if let Ok(full) = text_extract::extract_text(name, mime, &buf) {
            let total_chars = full.chars().count();
            let snippet: String = full.chars().take(CACHE_EXCERPT_CHARS).collect();
            if !snippet.is_empty() {
                req["excerpt"] = json!({
                    "text": snippet,
                    "totalChars": total_chars,
                    "truncated": total_chars > CACHE_EXCERPT_CHARS,
                });
                any = true;
            }
        }
    }
    if any {
        let _ = session.command(req.to_string());
    }
}

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

/// Validates and sniffs a regular local file before streaming it into `vault-core`.
pub(crate) fn inspect_import_file(path: &std::path::Path) -> Result<(String, String, u64), String> {
    let mut file = crate::platform::open_regular_readonly(path).map_err(|_| "Storage")?;
    let meta = file.metadata().map_err(|_| "Storage")?;
    if !meta.is_file() || meta.len() > asset_sessions::ASSET_FILE_LIMIT {
        return Err("AssetTooLarge".into());
    }
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .filter(|n| !n.is_empty() && n.len() <= 1024)
        .ok_or("InvalidData")?
        .to_string();
    let mut head = [0u8; 8192];
    let n = file.read(&mut head).map_err(|_| "Storage")?;
    let mime = text_extract::detect_mime(&name, &head[..n]).to_string();
    Ok((name, mime, meta.len()))
}

#[module]
impl Attachments {
    /// Streams a local file (up to 100 MiB) into chunked encrypted `blobs/` without
    /// passing plaintext through JS or buffering the whole file in memory.
    pub async fn import_file(
        vault: Instance<Vault>,
        note_id: String,
        path: String,
    ) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            let pb = std::path::PathBuf::from(&path);
            let (name, mime, size) = inspect_import_file(&pb)?;
            let raw = session
                .import_note_attachment_file(note_id.clone(), path, name.clone(), mime.clone())
                .map_err(error_code)?;
            if let Ok(meta) = serde_json::from_str::<Value>(&raw) {
                if let Some(aid) = meta["id"].as_str() {
                    populate_import_cache(&session, &note_id, aid, &pb, &name, &mime, size);
                }
            }
            Ok(raw)
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }

    /// Reads an owner-bound L2 thumbnail (<=400px) from SQLCipher cache or generates & caches it.
    /// Works even for `remote` attachments that carried a synced thumbnail preview.
    pub async fn read_thumbnail(
        vault: Instance<Vault>,
        note_id: String,
        id: String,
    ) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            if let Ok(raw) = session.command(
                json!({"op":"note-attachment-cache-get","noteId":note_id,"id":id}).to_string(),
            ) {
                if let Ok(parsed) = serde_json::from_str::<Value>(&raw) {
                    if let Some(url) = parsed["thumb"]["dataUrl"]
                        .as_str()
                        .filter(|s| !s.is_empty())
                    {
                        return Ok(json!({
                            "dataUrl": url,
                            "width": parsed["thumb"]["width"],
                            "height": parsed["thumb"]["height"],
                            "lod": "l2",
                            "cached": true,
                        })
                        .to_string());
                    }
                }
            }
            let data = Zeroizing::new(
                session
                    .read_note_attachment(note_id.clone(), id.clone())
                    .map_err(error_code)?,
            );
            if let Some((data_url, tw, th, downscaled)) = build_thumbnail(&data) {
                let _ = session.command(
                    json!({
                        "op": "note-attachment-cache-put",
                        "noteId": note_id,
                        "id": id,
                        "thumb": {"dataUrl": data_url, "width": tw, "height": th},
                    })
                    .to_string(),
                );
                return Ok(json!({
                    "dataUrl": data_url,
                    "width": tw,
                    "height": th,
                    "lod": if downscaled { "l2" } else { "l3" },
                    "cached": false,
                })
                .to_string());
            }
            let mime = image_mime(&data).ok_or("Unsupported")?;
            Ok(json!({
                "dataUrl": format!("data:{mime};base64,{}", base64(&data)),
                "lod": "l3",
                "cached": false,
            })
            .to_string())
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

    /// Local zero-network text-extraction primitive (SQLCipher excerpt cache first, then PDFKit / Office XML / UTF-8).
    /// UI metadata shaping, display formatting, and policy presentation stay in TypeScript.
    pub async fn extract_text(
        vault: Instance<Vault>,
        note_id: String,
        id: String,
        max_chars: u32,
    ) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            let cap = (max_chars as usize).clamp(1, 65_536);
            // Fast path: hit encrypted SQLCipher excerpt cache in milliseconds (works even when remote).
            if let Ok(cache_raw) = session.command(
                json!({"op":"note-attachment-cache-get","noteId":note_id,"id":id}).to_string(),
            ) {
                if let Ok(cached) = serde_json::from_str::<Value>(&cache_raw) {
                    if let Some(ex_text) = cached["excerpt"]["text"].as_str() {
                        let cached_total = cached["excerpt"]["totalChars"]
                            .as_u64()
                            .unwrap_or(ex_text.chars().count() as u64)
                            as usize;
                        let cached_truncated =
                            cached["excerpt"]["truncated"].as_bool().unwrap_or(false);
                        if !cached_truncated || cap <= CACHE_EXCERPT_CHARS {
                            let snippet: String = ex_text.chars().take(cap).collect();
                            return Ok(json!({
                                "text": snippet,
                                "totalChars": cached_total,
                                "truncated": cached_total > cap,
                                "cached": true,
                            })
                            .to_string());
                        }
                    }
                }
            }

            let raw = session
                .command(json!({"op":"note-attachments-list","noteId":note_id}).to_string())
                .map_err(error_code)?;
            let list: Value = serde_json::from_str(&raw).map_err(|_| "InvalidData")?;
            let meta = list["attachments"]
                .as_array()
                .and_then(|arr| arr.iter().find(|a| a["id"] == id))
                .ok_or("InvalidData")?;
            if meta["state"].as_str() == Some("remote") {
                return Ok(
                    json!({"text": null, "totalChars": 0, "truncated": false, "remote": true})
                        .to_string(),
                );
            }
            let name = meta["name"].as_str().unwrap_or("");
            let mime = meta["mime"].as_str().unwrap_or("");
            let size = meta["size"].as_u64().unwrap_or(0);
            if size > 32 * 1024 * 1024 || !text_extract::can_extract_text(name, mime) {
                return Ok(json!({"text": null, "totalChars": 0, "truncated": false}).to_string());
            }
            let bytes = Zeroizing::new(
                session
                    .read_note_attachment(note_id.clone(), id.clone())
                    .map_err(error_code)?,
            );
            match text_extract::extract_text(name, mime, &bytes) {
                Ok(full) => {
                    let total_chars = full.chars().count();
                    let snippet: String = full.chars().take(cap).collect();
                    let cache_snippet: String = full.chars().take(CACHE_EXCERPT_CHARS).collect();
                    if !cache_snippet.is_empty() {
                        let _ = session.command(
                            json!({
                                "op": "note-attachment-cache-put",
                                "noteId": note_id,
                                "id": id,
                                "excerpt": {
                                    "text": cache_snippet,
                                    "totalChars": total_chars,
                                    "truncated": total_chars > CACHE_EXCERPT_CHARS,
                                },
                            })
                            .to_string(),
                        );
                    }
                    Ok(json!({
                        "text": snippet,
                        "totalChars": total_chars,
                        "truncated": total_chars > cap,
                        "cached": false,
                    })
                    .to_string())
                }
                Err(_) => {
                    Ok(json!({"text": null, "totalChars": 0, "truncated": false}).to_string())
                }
            }
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }

    /// Tier 1 native macOS Quick Look (0400 read-only in isolated non-indexed session dir).
    pub async fn quick_look(
        vault: Instance<Vault>,
        note_id: String,
        id: String,
    ) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || asset_sessions::quick_look(&session, &note_id, &id).map(|v| v.to_string()))
            .await
            .map_err(|_| "Storage".to_string())?
    }

    /// Tier 2 external open in a third-party app with change watching for one-click write-back.
    pub async fn open_external(
        vault: Instance<Vault>,
        note_id: String,
        id: String,
        app_name: Option<String>,
    ) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            asset_sessions::open_external(&session, &note_id, &id, app_name.as_deref())
                .map(|v| v.to_string())
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }

    /// Polls active external sessions (optionally filtered by note_id) and checks for modifications.
    pub async fn list_sessions(note_id: Option<String>) -> Result<String, String> {
        blocking(move || Ok(asset_sessions::list_sessions(note_id.as_deref()).to_string()))
            .await
            .map_err(|_| "Storage".to_string())?
    }

    /// Re-encrypts a modified external session file as a new immutable attachment and wipes temp.
    pub async fn write_back_session(
        vault: Instance<Vault>,
        session_id: String,
    ) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            asset_sessions::write_back_session(&session, &session_id).map(|v| v.to_string())
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }

    /// Dismisses one active external session and securely deletes its temp file.
    pub async fn close_session(session_id: String) -> Result<bool, String> {
        blocking(move || Ok(asset_sessions::close_session(&session_id)))
            .await
            .map_err(|_| "Storage".to_string())?
    }

    /// Wipes every temporary decrypted asset session immediately (called on lock/quit).
    pub async fn cleanup_sessions() -> Result<(), String> {
        blocking(move || {
            asset_sessions::cleanup_all();
            Ok(())
        })
        .await
        .map_err(|_| "Storage".to_string())?
    }

    /// Tier 3 explicit plaintext export to a user-selected destination path.
    pub async fn export_plaintext(
        vault: Instance<Vault>,
        note_id: String,
        id: String,
        dest_path: String,
    ) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            session
                .export_note_attachment_file(note_id, id, dest_path, false)
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

    #[test]
    fn thumbnail_downscales_large_raster_to_400px_l2() {
        let img = image::RgbImage::from_pixel(1000, 500, image::Rgb([30, 120, 220]));
        let mut png = Vec::new();
        img.write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        let (url, w, h, downscaled) = build_thumbnail(&png).expect("thumbnail should build");
        assert!(url.starts_with("data:image/jpeg;base64,"));
        assert_eq!((w, h), (400, 200));
        assert!(downscaled);
    }
}

#[cfg(test)]
mod ownership_tests {
    use serde_json::{Value, json};
    #[test]
    fn encrypted_attachment_owner_lock_and_reference_guards() {
        let output = std::process::Command::new("mktemp")
            .args(["-d", "/tmp/pv-nsh-attachment-test.XXXXXX"])
            .output()
            .unwrap();
        assert!(output.status.success());
        let directory = String::from_utf8(output.stdout).unwrap().trim().to_string();
        let session = crate::session::VaultSession::new(format!("{directory}/vault")).unwrap();
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
