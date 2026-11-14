//! Native-only, versioned and code-identity authenticated local transport.
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    os::unix::{fs::PermissionsExt, io::AsRawFd, net::UnixStream},
    path::{Path, PathBuf},
    time::Duration,
};
#[path = "browser/security.rs"]
pub(crate) mod security;
static START_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
static STOPPING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub(crate) fn mark_stopped(directory: &Path) -> Result<(), String> {
    let marker = directory.join("service-user-stopped");
    std::fs::write(&marker, b"stopped").map_err(|_| "Storage")?;
    std::fs::set_permissions(marker, std::fs::Permissions::from_mode(0o600))
        .map_err(|_| "Storage".into())
}
pub(crate) fn resume_directory(directory: &Path) -> Result<(), String> {
    match std::fs::remove_file(directory.join("service-user-stopped")) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err("Storage".into()),
    }
}
#[cfg(feature = "ui")]
pub(crate) fn begin_shutdown(directory: &Path) -> Result<(), String> {
    let _guard = START_LOCK.lock().map_err(|_| "Storage")?;
    mark_stopped(directory)?;
    STOPPING.store(true, std::sync::atomic::Ordering::SeqCst);
    Ok(())
}
#[cfg(feature = "ui")]
pub(crate) fn cancel_shutdown(directory: &Path) {
    let _ = resume_directory(directory);
    STOPPING.store(false, std::sync::atomic::Ordering::SeqCst);
}
pub(crate) const MAX_FRAME: usize = 2 * 1024 * 1024 * 1024;
pub(crate) fn wipe(value: &mut Value) {
    use zeroize::Zeroize;
    match value {
        Value::String(s) => s.zeroize(),
        Value::Array(a) => a.iter_mut().for_each(wipe),
        Value::Object(o) => o.values_mut().for_each(wipe),
        _ => (),
    }
}
pub(crate) fn read(stream: &mut UnixStream) -> Result<Value, String> {
    let mut size = [0; 4];
    stream
        .read_exact(&mut size)
        .map_err(|_| "ServiceUnavailable")?;
    let size = u32::from_le_bytes(size) as usize;
    if size == 0 || size > MAX_FRAME {
        return Err("InvalidData".into());
    }
    let mut bytes = zeroize::Zeroizing::new(vec![0; size]);
    stream
        .read_exact(&mut bytes)
        .map_err(|_| "ServiceUnavailable")?;
    serde_json::from_slice(&bytes).map_err(|_| "InvalidData".into())
}
pub(crate) fn write(stream: &mut UnixStream, value: &Value) -> Result<(), String> {
    let bytes = zeroize::Zeroizing::new(serde_json::to_vec(value).map_err(|_| "InvalidData")?);
    if bytes.is_empty() || bytes.len() > MAX_FRAME {
        return Err("InvalidData".into());
    }
    stream
        .write_all(&(bytes.len() as u32).to_le_bytes())
        .and_then(|_| stream.write_all(&bytes))
        .map_err(|_| "ServiceUnavailable".into())
}
pub(crate) fn same_user(fd: i32) -> bool {
    let (mut uid, mut gid) = (0, 0);
    unsafe { libc::getpeereid(fd, &mut uid, &mut gid) == 0 && uid == libc::geteuid() }
}
/// Peer PID supplied by the kernel; never accept a PID from request data.
pub(crate) fn peer_pid(fd: i32) -> Option<i32> {
    let mut pid = 0i32;
    let mut len = std::mem::size_of::<i32>() as u32;
    if unsafe {
        libc::getsockopt(
            fd,
            0,
            libc::LOCAL_PEERPID,
            (&mut pid as *mut i32).cast(),
            &mut len,
        )
    } == 0
        && len == 4
        && pid > 0
    {
        Some(pid)
    } else {
        None
    }
}
pub(crate) fn executable() -> Result<PathBuf, String> {
    std::env::current_exe().map_err(|_| "Storage".into())
}
pub(crate) const SERVICE_EXECUTABLE: &str =
    "Library/PasswordVault Background.app/Contents/MacOS/pv-background";
pub(crate) fn application_contents() -> Result<PathBuf, String> {
    executable()?
        .ancestors()
        .find(|p| {
            p.file_name().is_some_and(|v| v == "Contents")
                && p.join("MacOS/pv-browser-host").is_file()
        })
        .map(Path::to_path_buf)
        .ok_or("Storage".into())
}
pub(crate) fn helper() -> Result<PathBuf, String> {
    Ok(application_contents()?.join(SERVICE_EXECUTABLE))
}
pub(crate) fn label(directory: &Path) -> String {
    format!(
        "com.securepass.vault.background.{}",
        &hex_digest(directory)[..16]
    )
}
fn hex_digest(directory: &Path) -> String {
    format!(
        "{:x}",
        Sha256::digest(directory.as_os_str().as_encoded_bytes())
    )
}
fn xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}
/// No RunAtLoad/KeepAlive: registration does not add login startup. A crashed
/// service is restarted only on the next demand and always starts locked.
pub(crate) fn ensure(directory: &Path) -> Result<(), String> {
    let _guard = START_LOCK.lock().map_err(|_| "Storage")?;
    if STOPPING.load(std::sync::atomic::Ordering::SeqCst)
        || directory.join("service-user-stopped").exists()
    {
        return Err("ServiceStopped".into());
    }
    if UnixStream::connect(directory.join("service.sock")).is_ok() {
        return Ok(());
    }
    if !directory.is_absolute() {
        return Err("InvalidData".into());
    }
    let binary = helper()?;
    security::code_hash(&binary).ok_or("UnsignedService")?;
    let home = PathBuf::from(std::env::var_os("HOME").ok_or("Storage")?);
    let agents = home.join("Library/LaunchAgents");
    std::fs::create_dir_all(&agents).map_err(|_| "Storage")?;
    let label = label(directory);
    let plist = agents.join(format!("{label}.plist"));
    let text = format!(
        "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>{label}</string><key>ProgramArguments</key><array><string>{}</string><string>--vault-directory</string><string>{}</string></array><key>EnvironmentVariables</key><dict><key>MallocLargeCache</key><string>0</string><key>MallocDeferredReclaim</key><string>0</string></dict><key>ProcessType</key><string>Background</string></dict></plist>",
        xml(&binary.to_string_lossy()),
        xml(&directory.to_string_lossy())
    );
    // Atomic replacement prevents simultaneous UI/helper startup from truncating it.
    let tmp = agents.join(format!(".{label}.{}.plist", uuid::Uuid::new_v4()));
    std::fs::write(&tmp, text).map_err(|_| "Storage")?;
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))
        .map_err(|_| "Storage")?;
    std::fs::rename(&tmp, &plist).map_err(|_| "Storage")?;
    let domain = format!("gui/{}", unsafe { libc::geteuid() });
    let _ = std::process::Command::new("/bin/launchctl")
        .args(["bootstrap", &domain])
        .arg(&plist)
        .output();
    let _ = std::process::Command::new("/bin/launchctl")
        .args(["kickstart", &format!("{domain}/{label}")])
        .output();
    for _ in 0..100 {
        if UnixStream::connect(directory.join("service.sock")).is_ok() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err("ServiceUnavailable".into())
}
pub(crate) fn control(directory: &Path, method: &str, mut args: Value) -> Result<Value, String> {
    let result = (|| {
        if std::env::var_os("PV_ALLOW_LOCAL_SESSION").is_some() {
            return Err("Unsupported".into());
        }
        if method != "shutdown" {
            if STOPPING.load(std::sync::atomic::Ordering::SeqCst) {
                return Err("ServiceStopped".into());
            }
            if directory.join("service-user-stopped").exists() {
                return Err("ServiceStopped".into());
            }
        }
        let mut stream = match UnixStream::connect(directory.join("service.sock")) {
            Ok(stream) => stream,
            Err(_) if method == "shutdown" => return Ok(Value::Null),
            Err(_) => {
                ensure(directory)?;
                UnixStream::connect(directory.join("service.sock"))
                    .map_err(|_| "ServiceUnavailable")?
            }
        };
        stream
            .set_read_timeout(Some(Duration::from_secs(120)))
            .map_err(|_| "Storage")?;
        stream
            .set_write_timeout(Some(Duration::from_secs(120)))
            .map_err(|_| "Storage")?;
        if !same_user(stream.as_raw_fd()) || !security::peer(stream.as_raw_fd(), &helper()?) {
            return Err("InvalidPeer".into());
        }
        let id = uuid::Uuid::new_v4().to_string();
        let mut request = json!({"version":1,"id":id,"method":method,"args":args.take()});
        let sent = write(&mut stream, &request);
        wipe(&mut request);
        sent?;
        // Never replay a command after an ambiguous disconnect.
        let mut reply = read(&mut stream)?;
        let result = if reply["version"] != 1 || reply["id"] != id {
            Err("InvalidData".into())
        } else if let Some(error) = reply["error"].as_str() {
            Err(error.to_owned())
        } else {
            Ok(reply["value"].take())
        };
        wipe(&mut reply);
        result
    })();
    wipe(&mut args);
    result
}

/// Run socket, filesystem and Security.framework work outside the NSH engine.
#[cfg(feature = "ui")]
pub(crate) async fn control_async(
    directory: PathBuf,
    method: &'static str,
    args: Value,
) -> Result<Value, String> {
    nsh_core::prelude::blocking(move || control(&directory, method, args))
        .await
        .map_err(|_| "Storage".to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn invalid_lengths_are_rejected_before_allocating() {
        for size in [0, MAX_FRAME as u32 + 1, u32::MAX] {
            let (mut send, mut receive) = UnixStream::pair().unwrap();
            send.write_all(&size.to_le_bytes()).unwrap();
            assert_eq!(read(&mut receive).unwrap_err(), "InvalidData");
        }
    }
    #[test]
    fn same_user_transport_and_message_round_trip() {
        let (mut send, mut receive) = UnixStream::pair().unwrap();
        assert!(same_user(send.as_raw_fd()));
        let value = json!({"version":1,"id":"fixture","value":{"ok":true}});
        write(&mut send, &value).unwrap();
        assert_eq!(read(&mut receive).unwrap(), value);
    }
}
