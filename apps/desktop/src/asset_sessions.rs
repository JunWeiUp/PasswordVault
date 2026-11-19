//! Isolated temporary session manager for encrypted note assets:
//! - Tier 1: Quick Look / read-only preview (`0400` in non-indexed `0700` session dir)
//! - Tier 2: Third-party external open (`0600`, executable blocklist, SHA-256 watch, one-click encrypted write-back)
//! - Zero-trace cleanup on dismiss, write-back, vault lock, app exit, or stale dead-PID startup sweep.
use crate::{error_code, session::VaultSession};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{SystemTime, UNIX_EPOCH},
};

pub(crate) const ASSET_FILE_LIMIT: u64 = 100 * 1024 * 1024;

const BLOCKED_EXTENSIONS: &[&str] = &[
    "app",
    "action",
    "applescript",
    "bash",
    "bat",
    "bin",
    "bundle",
    "cjs",
    "cmd",
    "com",
    "command",
    "csh",
    "dll",
    "dmg",
    "dylib",
    "exe",
    "hta",
    "inetloc",
    "iso",
    "jar",
    "jse",
    "js",
    "ksh",
    "lnk",
    "mjs",
    "mpkg",
    "msi",
    "out",
    "pkg",
    "pl",
    "ps1",
    "py",
    "rb",
    "run",
    "scpt",
    "scptd",
    "scr",
    "sh",
    "so",
    "terminal",
    "tool",
    "url",
    "vbs",
    "webloc",
    "workflow",
    "zsh",
];

pub(crate) fn is_blocked_executable(name: &str) -> bool {
    let trimmed = name.trim();
    if trimmed.is_empty()
        || trimmed.starts_with('.')
        || trimmed.contains('\0')
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains("..")
    {
        return true;
    }
    let Some(ext) = trimmed
        .rsplit('.')
        .next()
        .filter(|_| trimmed.contains('.'))
        .map(|s| s.to_ascii_lowercase())
    else {
        return false;
    };
    BLOCKED_EXTENSIONS.contains(&ext.as_str())
}

pub(crate) fn safe_filename(name: &str) -> String {
    let clean: String = name
        .chars()
        .map(|c| {
            if c.is_control() || matches!(c, '/' | '\\' | ':' | '\0') {
                '_'
            } else {
                c
            }
        })
        .collect();
    let trimmed = clean.trim().trim_start_matches('.');
    if trimmed.is_empty() || trimmed == "." || trimmed == ".." {
        "attachment.bin".into()
    } else {
        trimmed.chars().take(180).collect()
    }
}

#[derive(Clone)]
struct ActiveSession {
    session_id: String,
    note_id: String,
    attachment_id: String,
    name: String,
    mime: String,
    app_name: String,
    dir: PathBuf,
    file_path: PathBuf,
    initial_sha256: String,
    initial_size: u64,
    last_checked_size: u64,
    last_checked_mtime: Option<SystemTime>,
    current_sha256: String,
    dirty: bool,
    opened_at_unix: u64,
}

#[derive(Default)]
struct SessionRegistry {
    external: HashMap<String, ActiveSession>,
    readonly_dirs: Vec<PathBuf>,
    swept: bool,
}

static REGISTRY: OnceLock<Mutex<SessionRegistry>> = OnceLock::new();

fn registry() -> std::sync::MutexGuard<'static, SessionRegistry> {
    REGISTRY.get_or_init(Default::default).lock().unwrap()
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn create_isolated_dir() -> Result<PathBuf, String> {
    let dir = std::env::temp_dir().join(format!(
        "pv-asset-session-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4().simple()
    ));
    fs::create_dir_all(&dir).map_err(|_| "Storage")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).map_err(|_| "Storage")?;
    }
    // Prevent Spotlight indexing and exclude from macOS Time Machine backups.
    let marker = dir.join(".metadata_never_index");
    let _ = fs::write(&marker, b"");
    #[cfg(target_os = "macos")]
    {
        use std::ffi::CString;
        if let Ok(c_path) = CString::new(dir.as_os_str().as_encoded_bytes()) {
            let name = c"com.apple.metadata:com_apple_backup_excludeItem";
            let val = b"com.apple.backupd\0";
            unsafe {
                let _ = libc::setxattr(
                    c_path.as_ptr(),
                    name.as_ptr(),
                    val.as_ptr().cast(),
                    val.len(),
                    0,
                    0,
                );
            }
        }
    }
    Ok(dir)
}

fn secure_wipe_file(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    if let Ok(mut file) = OpenOptions::new().write(true).open(path) {
        if let Ok(meta) = file.metadata() {
            let len = meta.len();
            if len > 0 && len <= 16 * 1024 * 1024 {
                let zeros = vec![0u8; (len as usize).min(65536)];
                let _ = file.seek(SeekFrom::Start(0));
                let mut left = len as usize;
                while left > 0 {
                    let chunk = left.min(zeros.len());
                    if file.write_all(&zeros[..chunk]).is_err() {
                        break;
                    }
                    left -= chunk;
                }
            }
            let _ = file.set_len(0);
            let _ = file.sync_all();
        }
    }
    let _ = fs::remove_file(path);
}

fn wipe_session_dir(dir: &Path) {
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_file() {
                secure_wipe_file(&p);
            } else if p.is_dir() {
                let _ = fs::remove_dir_all(&p);
            }
        }
    }
    let _ = fs::remove_dir_all(dir);
}

/// Sweeps any leftover `pv-asset-session-<dead-pid>-*` directories from prior crashed runs.
pub(crate) fn sweep_stale_sessions() {
    let mut reg = registry();
    if reg.swept {
        return;
    }
    reg.swept = true;
    drop(reg);

    let Ok(entries) = fs::read_dir(std::env::temp_dir()) else {
        return;
    };
    let my_pid = std::process::id();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(s) = name.to_str() else { continue };
        let Some(rest) = s.strip_prefix("pv-asset-session-") else {
            continue;
        };
        let Some((pid_str, _)) = rest.split_once('-') else {
            continue;
        };
        let Ok(pid) = pid_str.parse::<u32>() else {
            continue;
        };
        if pid == my_pid {
            continue;
        }
        #[cfg(unix)]
        let alive = unsafe { libc::kill(pid as i32, 0) == 0 };
        #[cfg(not(unix))]
        let alive = false;
        if !alive {
            wipe_session_dir(&entry.path());
        }
    }
}

fn hash_regular_file(path: &Path) -> Result<(u64, String, Option<SystemTime>), String> {
    let mut file = crate::platform::open_regular_readonly(path).map_err(|_| "Storage")?;
    let meta = file.metadata().map_err(|_| "Storage")?;
    let size = meta.len();
    if size > ASSET_FILE_LIMIT {
        return Err("AssetTooLarge".into());
    }
    let mtime = meta.modified().ok();
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    let mut read_total: u64 = 0;
    loop {
        let n = file.read(&mut buf).map_err(|_| "Storage")?;
        if n == 0 {
            break;
        }
        read_total += n as u64;
        if read_total > ASSET_FILE_LIMIT {
            return Err("AssetTooLarge".into());
        }
        hasher.update(&buf[..n]);
    }
    Ok((read_total, format!("{:x}", hasher.finalize()), mtime))
}

fn launch_external_app(path: &Path, app_name: Option<&str>) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let mut cmd = std::process::Command::new("/usr/bin/open");
        if let Some(app) = app_name.map(str::trim).filter(|a| !a.is_empty()) {
            if app.len() > 120 || app.chars().any(char::is_control) {
                return Err("InvalidData".into());
            }
            cmd.arg("-a").arg(app);
        }
        cmd.arg(path);
        let status = cmd.status().map_err(|_| "OpenFailed")?;
        if !status.success() {
            return Err("OpenFailed".into());
        }
        Ok(())
    }
    #[cfg(target_os = "windows")]
    {
        let _ = app_name;
        let status = std::process::Command::new("cmd")
            .args(["/C", "start", ""])
            .arg(path)
            .status()
            .map_err(|_| "OpenFailed")?;
        if !status.success() {
            return Err("OpenFailed".into());
        }
        Ok(())
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        let _ = (path, app_name);
        Err("Unsupported".into())
    }
}

fn launch_quick_look(path: &Path) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("/usr/bin/qlmanage")
            .arg("-p")
            .arg(path)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|_| "OpenFailed")?;
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = path;
        Err("Unsupported".into())
    }
}

fn session_json(s: &ActiveSession) -> Value {
    json!({
        "sessionId": s.session_id,
        "noteId": s.note_id,
        "attachmentId": s.attachment_id,
        "name": s.name,
        "mime": s.mime,
        "appName": s.app_name,
        "initialSize": s.initial_size,
        "currentSize": s.last_checked_size,
        "deltaBytes": (s.last_checked_size as i64) - (s.initial_size as i64),
        "dirty": s.dirty,
        "openedAtUnix": s.opened_at_unix,
    })
}

fn stage_external_internal(
    vault_session: &VaultSession,
    note_id: &str,
    attachment_id: &str,
    app_name: Option<&str>,
    launch: bool,
) -> Result<Value, String> {
    sweep_stale_sessions();

    // Lookup attachment metadata first so executable names are rejected before any decryption!
    let list_raw = vault_session
        .command(json!({"op":"note-attachments-list","noteId":note_id}).to_string())
        .map_err(error_code)?;
    let list: Value = serde_json::from_str(&list_raw).map_err(|_| "InvalidData")?;
    let meta = list["attachments"]
        .as_array()
        .and_then(|arr| arr.iter().find(|a| a["id"] == attachment_id))
        .ok_or("InvalidData")?;
    let name = meta["name"].as_str().unwrap_or("attachment.bin").to_owned();
    let mime = meta["mime"]
        .as_str()
        .unwrap_or("application/octet-stream")
        .to_owned();
    if is_blocked_executable(&name) {
        return Err("BlockedExecutable".into());
    }

    // If an active session already exists for this exact attachment, reuse & re-focus it.
    {
        let reg = registry();
        if let Some(existing) = reg
            .external
            .values()
            .find(|s| s.note_id == note_id && s.attachment_id == attachment_id)
        {
            if existing.file_path.is_file() {
                if launch {
                    launch_external_app(&existing.file_path, app_name)?;
                }
                return Ok(session_json(existing));
            }
        }
    }

    let dir = create_isolated_dir()?;
    let safe = safe_filename(&name);
    let file_path = dir.join(&safe);
    let export_raw = match vault_session.export_note_attachment_file(
        note_id.into(),
        attachment_id.into(),
        file_path.to_string_lossy().into_owned(),
        false,
    ) {
        Ok(raw) => raw,
        Err(err) => {
            wipe_session_dir(&dir);
            return Err(error_code(err));
        }
    };
    let exported: Value = serde_json::from_str(&export_raw).map_err(|_| {
        wipe_session_dir(&dir);
        "InvalidData".to_string()
    })?;
    let initial_sha256 = exported["sha256"].as_str().unwrap_or("").to_owned();
    let initial_size = exported["size"].as_u64().unwrap_or(0);
    let initial_mtime = fs::metadata(&file_path).ok().and_then(|m| m.modified().ok());

    if launch {
        if let Err(err) = launch_external_app(&file_path, app_name) {
            wipe_session_dir(&dir);
            return Err(err);
        }
    }

    let label = app_name
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("默认应用")
        .to_owned();
    let session_id = uuid::Uuid::new_v4().to_string();
    let active = ActiveSession {
        session_id: session_id.clone(),
        note_id: note_id.to_owned(),
        attachment_id: attachment_id.to_owned(),
        name,
        mime,
        app_name: label,
        dir,
        file_path,
        initial_sha256: initial_sha256.clone(),
        initial_size,
        last_checked_size: initial_size,
        last_checked_mtime: initial_mtime,
        current_sha256: initial_sha256,
        dirty: false,
        opened_at_unix: unix_now(),
    };
    let out = session_json(&active);
    registry().external.insert(session_id, active);
    Ok(out)
}

pub(crate) fn open_external(
    vault_session: &VaultSession,
    note_id: &str,
    attachment_id: &str,
    app_name: Option<&str>,
) -> Result<Value, String> {
    stage_external_internal(vault_session, note_id, attachment_id, app_name, true)
}

pub(crate) fn quick_look(
    vault_session: &VaultSession,
    note_id: &str,
    attachment_id: &str,
) -> Result<Value, String> {
    sweep_stale_sessions();
    let list_raw = vault_session
        .command(json!({"op":"note-attachments-list","noteId":note_id}).to_string())
        .map_err(error_code)?;
    let list: Value = serde_json::from_str(&list_raw).map_err(|_| "InvalidData")?;
    let meta = list["attachments"]
        .as_array()
        .and_then(|arr| arr.iter().find(|a| a["id"] == attachment_id))
        .ok_or("InvalidData")?;
    let name = meta["name"].as_str().unwrap_or("attachment.bin");
    if is_blocked_executable(name) {
        return Err("BlockedExecutable".into());
    }
    let dir = create_isolated_dir()?;
    let file_path = dir.join(safe_filename(name));
    if let Err(err) = vault_session.export_note_attachment_file(
        note_id.into(),
        attachment_id.into(),
        file_path.to_string_lossy().into_owned(),
        true, // 0400 read-only!
    ) {
        wipe_session_dir(&dir);
        return Err(error_code(err));
    }
    if let Err(err) = launch_quick_look(&file_path) {
        wipe_session_dir(&dir);
        return Err(err);
    }
    registry().readonly_dirs.push(dir);
    Ok(json!({"ok": true, "readonly": true}))
}

pub(crate) fn list_sessions(note_id: Option<&str>) -> Value {
    let mut reg = registry();
    let mut vanished = Vec::new();
    let mut out = Vec::new();

    for (sid, s) in reg.external.iter_mut() {
        if let Some(target) = note_id {
            if s.note_id != target {
                continue;
            }
        }
        let Ok(meta) = fs::metadata(&s.file_path) else {
            vanished.push(sid.clone());
            continue;
        };
        if !meta.is_file() {
            vanished.push(sid.clone());
            continue;
        }
        let size = meta.len();
        let mtime = meta.modified().ok();
        if size != s.last_checked_size || mtime != s.last_checked_mtime {
            if let Ok((cur_size, cur_hash, cur_mtime)) = hash_regular_file(&s.file_path) {
                s.last_checked_size = cur_size;
                s.last_checked_mtime = cur_mtime;
                s.current_sha256 = cur_hash;
                s.dirty = s.current_sha256 != s.initial_sha256;
            }
        }
        out.push(session_json(s));
    }
    for sid in vanished {
        if let Some(s) = reg.external.remove(&sid) {
            wipe_session_dir(&s.dir);
        }
    }
    out.sort_by_key(|v| v["openedAtUnix"].as_u64().unwrap_or(0));
    json!({"sessions": out})
}

pub(crate) fn write_back_session(
    vault_session: &VaultSession,
    session_id: &str,
) -> Result<Value, String> {
    let session = {
        let reg = registry();
        reg.external
            .get(session_id)
            .cloned()
            .ok_or("SessionNotFound")?
    };
    let (_, cur_hash, _) = hash_regular_file(&session.file_path)?;
    if cur_hash == session.initial_sha256 {
        return Err("Unchanged".into());
    }
    let meta_raw = vault_session
        .import_note_attachment_file(
            session.note_id.clone(),
            session.file_path.to_string_lossy().into_owned(),
            session.name.clone(),
            session.mime.clone(),
        )
        .map_err(error_code)?;
    let meta: Value = serde_json::from_str(&meta_raw).map_err(|_| "InvalidData")?;

    // Clean up temporary session file immediately after secure write-back.
    if let Some(removed) = registry().external.remove(session_id) {
        wipe_session_dir(&removed.dir);
    }
    Ok(json!({
        "sessionId": session_id,
        "noteId": session.note_id,
        "oldAttachmentId": session.attachment_id,
        "appName": session.app_name,
        "meta": meta,
    }))
}

pub(crate) fn close_session(session_id: &str) -> bool {
    let removed = registry().external.remove(session_id);
    if let Some(s) = removed {
        wipe_session_dir(&s.dir);
        true
    } else {
        false
    }
}

/// Immediately wipes every active temporary decrypted asset file (on lock or exit).
pub(crate) fn cleanup_all() {
    let (externals, readonly) = {
        let mut reg = registry();
        let exts: Vec<ActiveSession> = reg.external.drain().map(|(_, v)| v).collect();
        let ro: Vec<PathBuf> = reg.readonly_dirs.drain(..).collect();
        (exts, ro)
    };
    for s in externals {
        wipe_session_dir(&s.dir);
    }
    for d in readonly {
        wipe_session_dir(&d);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn executable_blocklist_rejects_scripts_and_bundles_allows_documents() {
        for bad in [
            "run.command",
            "script.sh",
            "app.APP",
            "installer.pkg",
            "disk.dmg",
            "payload.exe",
            "macro.ps1",
            "../escape.pdf",
            ".hidden.pdf",
        ] {
            assert!(is_blocked_executable(bad), "should block {bad}");
        }
        for ok in [
            "2026-Q4-券商对账单.pdf",
            "2026-资产配置模型.xlsx",
            "林晓-简历.docx",
            "slides.pptx",
            "scan.png",
            "notes.md",
        ] {
            assert!(!is_blocked_executable(ok), "should allow {ok}");
        }
    }

    #[test]
    fn external_stage_watch_writeback_and_cleanup_lifecycle() {
        let root = std::env::temp_dir().join(format!("pv-asset-sess-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let session = VaultSession::new(root.join("vault").to_string_lossy().into()).unwrap();
        let run = |v: Value| session.command(v.to_string()).unwrap();
        run(json!({"op":"create","password":"synthetic-session-password"}));
        run(json!({"op":"save","richNotes":true,"item":{"id":"n1","type":"secureNote","title":"N","note":"","noteFormat":"plain"}}));

        // Blocked executable cannot be opened externally.
        let bad_meta: Value = serde_json::from_str(
            &session
                .import_note_attachment("n1".into(), "evil.command".into(), "text/plain".into(), b"echo hi".to_vec())
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            stage_external_internal(&session, "n1", bad_meta["id"].as_str().unwrap(), None, false)
                .unwrap_err(),
            "BlockedExecutable"
        );

        // Stage a real PDF, verify isolated dir + .metadata_never_index, simulate external edit, write back!
        let pdf_meta: Value = serde_json::from_str(
            &session
                .import_note_attachment("n1".into(), "statement.pdf".into(), "application/pdf".into(), b"%PDF-1.7 original".to_vec())
                .unwrap(),
        )
        .unwrap();
        let aid = pdf_meta["id"].as_str().unwrap().to_string();
        let staged = stage_external_internal(&session, "n1", &aid, Some("Preview"), false).unwrap();
        let sid = staged["sessionId"].as_str().unwrap().to_string();
        assert_eq!(staged["dirty"], false);

        let (dir, path) = {
            let reg = registry();
            let s = reg.external.get(&sid).unwrap();
            (s.dir.clone(), s.file_path.clone())
        };
        assert!(dir.join(".metadata_never_index").is_file());
        assert_eq!(fs::read(&path).unwrap(), b"%PDF-1.7 original");

        // Simulate external app saving modified content.
        fs::write(&path, b"%PDF-1.7 edited externally!").unwrap();
        let listed = list_sessions(Some("n1"));
        let found = listed["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["sessionId"] == sid)
            .unwrap();
        assert_eq!(found["dirty"], true);
        assert!(found["deltaBytes"].as_i64().unwrap() > 0);

        // One-click write-back creates new encrypted attachment and wipes temp session dir!
        let wb = write_back_session(&session, &sid).unwrap();
        let new_id = wb["meta"]["id"].as_str().unwrap().to_string();
        assert_ne!(new_id, aid);
        assert!(!dir.exists());
        assert_eq!(
            session.read_note_attachment("n1".into(), new_id).unwrap(),
            b"%PDF-1.7 edited externally!"
        );
        // Old attachment remains intact for version history!
        assert_eq!(
            session.read_note_attachment("n1".into(), aid).unwrap(),
            b"%PDF-1.7 original"
        );

        cleanup_all();
        drop(session);
        let _ = fs::remove_dir_all(&root);
    }
}
