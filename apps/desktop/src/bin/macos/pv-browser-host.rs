//! Native Messaging v2 host. No root grant is ever written to browser stdout.
#[path = "../../browser/grants.rs"]
mod grants;
#[path = "../../browser/security.rs"]
mod security;
#[path = "../../browser/wire.rs"]
mod wire;
#[path = "../../data_dir.rs"]
mod data_dir;
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    os::unix::{io::AsRawFd, net::UnixStream},
    path::Path,
    time::Duration,
};
fn run(contents: &Path, id: &str, directory: &Path, mut request: Value) -> Result<Value, String> {
    wire::browser_request(&mut request)?;
    let op = request["op"].as_str().unwrap_or("").to_string();
    let token = request["syncToken"].as_str().unwrap_or("").to_string();
    if op == "open" {
        let success = std::process::Command::new("/usr/bin/open")
            .arg(contents.parent().ok_or("unavailable")?)
            .status()
            .map_err(|_| "unavailable")?
            .success();
        return if success {
            Ok(json!({"ok":true}))
        } else {
            Err("native-unavailable".into())
        };
    }
    match op.as_str() {
        "configure-sync" => {
            grants::configure(directory, id, &request)?;
            return Ok(json!({"ok":true}));
        }
        "disable-sync" => {
            grants::revoke(directory, id, &token)?;
            return Ok(json!({"ok":true}));
        }
        "disable-auto-unlock" => {
            grants::disable_desktop(directory, id, &token)?;
            return Ok(json!({"ok":true}));
        }
        _ => {}
    }
    let auth = grants::authorization(directory, id, &token).ok();
    let read = auth.as_ref().is_some_and(|a| a.read);
    if matches!(op.as_str(), "matches" | "fill") && read {
        request["op"] = format!("authorized-{op}").into();
    }
    let privileged = op == "sync-save" || (matches!(op.as_str(), "matches" | "fill") && read);
    if privileged {
        request["_backgroundGrant"] = STANDARD
            .encode(&*auth.as_ref().ok_or("sync-authorization")?.grant)
            .into();
    }
    let result = if let Ok(mut stream) = UnixStream::connect(directory.join("browser-nsh.sock")) {
        let app = contents.join("MacOS/PasswordVault");
        if !security::peer(stream.as_raw_fd(), &app) {
            return Err("invalid-peer".into());
        }
        stream
            .set_read_timeout(Some(Duration::from_secs(45)))
            .map_err(|_| "unavailable")?;
        stream
            .set_write_timeout(Some(Duration::from_secs(15)))
            .map_err(|_| "unavailable")?;
        wire::write(
            &mut stream,
            &json!({"extensionOrigin":format!("chrome-extension://{id}/"),"request":request}),
        )?;
        wire::read(&mut stream, 1_000_000)?
    } else if privileged {
        let session = vault_core::VaultSession::new(directory.to_string_lossy().into())
            .map_err(|_| "sync-busy")?;
        request.as_object_mut().unwrap().remove("_backgroundGrant");
        request["op"] = op.clone().into();
        let auth = auth.as_ref().ok_or("sync-authorization")?;
        let output = if op == "sync-save" {
            session.background_save(auth.grant.to_vec(), request.to_string())
        } else {
            session.authorized_browser_command(auth.grant.to_vec(), request.to_string())
        }
        .map_err(|_| "sync-authorization")?;
        json!({"ok":true,"data":serde_json::from_str::<Value>(&output).map_err(|_|"failed")?})
    } else if op == "status" {
        json!({"ok":true,"unlocked":false,"paired":false,"version":2})
    } else {
        return Err("not-running".into());
    };
    let mut result = result;
    if op == "status" {
        result["syncSupported"] = true.into();
        result["syncReady"] = auth.is_some().into();
        result["readReady"] = read.into();
        // Only status metadata; never initiate desktop unlock from polling.
        result["autoUnlockReady"] = (auth.as_ref().is_some_and(|a| a.startup)
            && grants::owner(directory, id, &token))
        .into();
    }
    Ok(result)
}
pub(super) fn main() {
    let result = (|| -> Result<(), String> {
        let contents = wire::bundle()?;
        let id = wire::identity(&contents)?;
        if std::env::args().nth(1).as_deref() == Some("--desktop-unlock") {
            if !security::parent(&contents.join("MacOS/PasswordVault")) {
                return Err("invalid-peer".into());
            }
            let request = wire::read(&mut std::io::stdin(), 4096)?;
            let directory =
                std::path::PathBuf::from(request["directory"].as_str().ok_or("invalid-request")?);
            if directory.join("browser-startup-disabled").exists() {
                return Err("sync-authorization".into());
            }
            let nonce = request["nonce"].as_str().ok_or("invalid-request")?;
            uuid::Uuid::parse_str(nonce).map_err(|_| "invalid-request")?;
            let auth = grants::desktop(&directory, &id)?;
            let mut stream = UnixStream::connect(directory.join("browser-nsh.sock"))
                .map_err(|_| "not-running")?;
            if !security::peer(stream.as_raw_fd(), &contents.join("MacOS/PasswordVault")) {
                return Err("invalid-peer".into());
            }
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .map_err(|_| "unavailable")?;
            wire::write(
                &mut stream,
                &json!({"extensionOrigin":format!("chrome-extension://{id}/"),"request":{"version":2,"op":"desktop-auto-unlock","nonce":nonce,"_backgroundGrant":STANDARD.encode(&*auth.grant)}}),
            )?;
            let response = wire::read(&mut stream, 4096)?;
            wire::write(&mut std::io::stdout(), &response)?;
            return Ok(());
        }
        if std::env::args().nth(1).as_deref() != Some(&format!("chrome-extension://{id}/")) {
            return Err("invalid-origin".into());
        }
        let directory = std::path::PathBuf::from(std::env::var("HOME").map_err(|_| "unavailable")?)
            .join("Library/Application Support")
            .join(data_dir::data_directory_name())
            .join("vault");
        let mut input = std::io::stdin().lock();
        let mut output = std::io::stdout().lock();
        while let Ok(request) = wire::read(&mut input, 65536) {
            let reply =
                run(&contents, &id, &directory, request).unwrap_or_else(|e| wire::failure(&e));
            wire::write(&mut output, &reply)?;
        }
        Ok(())
    })();
    if let Err(e) = result {
        let _ = wire::write(&mut std::io::stdout(), &wire::failure(&e));
    }
}
