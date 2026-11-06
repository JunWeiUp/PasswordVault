mod connect;
use super::*;
use std::{
    fs,
    io::{BufRead, BufReader, Read, Write},
    os::unix::{
        fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt},
        io::AsRawFd,
        net::{UnixListener, UnixStream},
    },
    sync::atomic::{AtomicUsize, Ordering},
};
unsafe extern "C" {
    fn getpeereid(fd: i32, uid: *mut u32, gid: *mut u32) -> i32;
    fn geteuid() -> u32;
}
fn configured_path(
    override_path: Option<std::path::PathBuf>,
    home: Option<std::path::PathBuf>,
) -> Result<std::path::PathBuf> {
    let path = match override_path {
        Some(path) => path,
        None => home
            .ok_or("MissingHome")?
            .join("Library/Application Support/PasswordVaultNSHPreview/ai/mcp.sock"),
    };
    if !path.is_absolute() || path.file_name().is_none() {
        return Err("InvalidSocketPath".into());
    }
    Ok(path)
}
fn socket_path() -> Result<std::path::PathBuf> {
    configured_path(
        std::env::var_os("PASSWORDVAULT_AI_SOCKET").map(Into::into),
        std::env::var_os("HOME").map(Into::into),
    )
}
const STARTUP_TIMEOUT: Duration = Duration::from_secs(3);
const PROBE_TIMEOUT: Duration = Duration::from_millis(100);
const RETRY_DELAY: Duration = Duration::from_millis(25);

/// Explicit unlock matters: close alone leaves flock held while a forked child
/// retains a duplicate descriptor, even when FD_CLOEXEC is already set.
struct StartupLock(fs::File);
impl Drop for StartupLock {
    fn drop(&mut self) {
        unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}
impl StartupLock {
    fn acquire(file: fs::File, deadline: Instant) -> Result<Self> {
        loop {
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                return Ok(Self(file));
            }
            let error = std::io::Error::last_os_error();
            if !matches!(
                error.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
            ) {
                return Err("SocketLock".into());
            }
            retry(deadline)?;
        }
    }
}
fn retry(deadline: Instant) -> Result<()> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err("SocketInUse".into());
    }
    std::thread::sleep(RETRY_DELAY.min(remaining));
    Ok(())
}
/// Startup is serialized across processes. Only a same-owner socket with a
/// refused liveness probe may be unlinked; files, symlinks and live peers survive.
fn bind_socket(path: &std::path::Path) -> Result<UnixListener> {
    bind_socket_until(path, Instant::now() + STARTUP_TIMEOUT)
}
fn bind_socket_until(path: &std::path::Path, deadline: Instant) -> Result<UnixListener> {
    let dir = path.parent().ok_or("InvalidSocketPath")?;
    fs::create_dir_all(dir).map_err(|_| "SocketDirectory")?;
    let meta = fs::symlink_metadata(dir).map_err(|_| "SocketDirectory")?;
    if !meta.is_dir() || meta.uid() != unsafe { geteuid() } {
        return Err("SocketOwner".into());
    }
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).map_err(|_| "SocketPermissions")?;
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(dir.join("mcp.lock"))
        .map_err(|_| "SocketLock")?;
    let lock_meta = lock.metadata().map_err(|_| "SocketLock")?;
    if !lock_meta.is_file() || lock_meta.uid() != unsafe { geteuid() } {
        return Err("SocketOwner".into());
    }
    let _startup_lock = StartupLock::acquire(lock, deadline)?;
    loop {
        if Instant::now() >= deadline {
            return Err("SocketInUse".into());
        }
        match fs::symlink_metadata(path) {
            Ok(meta) => {
                if !meta.file_type().is_socket() || meta.uid() != unsafe { geteuid() } {
                    return Err("UnsafeSocketPath".into());
                }
                match connect::connect_timeout(
                    path,
                    PROBE_TIMEOUT.min(deadline.saturating_duration_since(Instant::now())),
                ) {
                    // A connected descriptor may belong to a forked child that has
                    // not exec'd yet. Never unlink it; retry within the total budget.
                    Ok(_) => {
                        retry(deadline)?;
                        continue;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => {
                        let current = fs::symlink_metadata(path).map_err(|_| "SocketChanged")?;
                        if current.ino() != meta.ino()
                            || current.dev() != meta.dev()
                            || !current.file_type().is_socket()
                        {
                            return Err("SocketChanged".into());
                        }
                        fs::remove_file(path).map_err(|_| "SocketCleanup")?;
                        break;
                    }
                    Err(e)
                        if matches!(
                            e.kind(),
                            std::io::ErrorKind::TimedOut
                                | std::io::ErrorKind::WouldBlock
                                | std::io::ErrorKind::Interrupted
                        ) =>
                    {
                        retry(deadline)?;
                        continue;
                    }
                    Err(_) => return Err("SocketProbeFailed".into()),
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => break,
            Err(_) => return Err("SocketMetadata".into()),
        }
    }
    let listener = UnixListener::bind(path).map_err(|_| "SocketBind")?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .map_err(|_| "SocketPermissions")?;
    Ok(listener)
}
pub fn start(s: Arc<VaultSession>) -> Result<String> {
    let mut st = state();
    if let Some(path) = &st.socket {
        return Ok(path.clone());
    }
    let path = socket_path()?;
    let listener = bind_socket(&path)?;
    let path = path.to_string_lossy().to_string();
    st.socket = Some(path.clone());
    std::thread::spawn(move || {
        let count = Arc::new(AtomicUsize::new(0));
        for stream in listener.incoming().flatten() {
            if count.load(Ordering::SeqCst) >= 16 {
                continue;
            }
            let (mut uid, mut gid) = (0, 0);
            if unsafe { getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0
                || uid != unsafe { geteuid() }
            {
                continue;
            }
            count.fetch_add(1, Ordering::SeqCst);
            let (s, count) = (s.clone(), count.clone());
            std::thread::spawn(move || {
                let _ = serve(stream, &s);
                count.fetch_sub(1, Ordering::SeqCst);
            });
        }
    });
    Ok(path)
}
fn serve(mut stream: UnixStream, s: &VaultSession) -> Result<()> {
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|_| "Socket")?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(|_| "Socket")?;
    let mut line = String::new();
    BufReader::new((&stream).take(65537))
        .read_line(&mut line)
        .map_err(|_| "Socket")?;
    if line.len() > 65536 || !line.ends_with('\n') {
        return Err("RequestTooLarge".into());
    }
    let request_id = id();
    let result = serde_json::from_str::<Value>(&line)
        .map_err(|_| "InvalidData".to_string())
        .and_then(|mut r| {
            if !r.is_object() {
                return Err("InvalidData".into());
            }
            r["requestId"] = json!(request_id);
            request(s, r)
        });
    let response = match result {
        Ok(v) => json!({"ok":true,"result":v,"requestId":request_id}),
        Err(e) => json!({"ok":false,"error":e,"requestId":request_id}),
    };
    writeln!(stream, "{response}").map_err(|_| "Socket".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ai_socket_fixed_path_and_test_override() {
        let home = std::path::PathBuf::from("/tmp/ai-home");
        assert_eq!(
            configured_path(None, Some(home.clone())).unwrap(),
            home.join("Library/Application Support/PasswordVaultNSHPreview/ai/mcp.sock")
        );
        let path = std::path::PathBuf::from("/tmp/ai-isolated/mcp.sock");
        assert_eq!(configured_path(Some(path.clone()), None).unwrap(), path);
        assert!(configured_path(Some("relative.sock".into()), None).is_err());
    }
    #[test]
    fn ai_socket_preserves_live_listener_and_recovers_stale_socket() {
        let dir = std::env::temp_dir().join(format!("ai-{}", id()));
        let path = dir.join("mcp.sock");
        let first = bind_socket(&path).unwrap();
        assert_eq!(
            fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let start = Instant::now();
        assert_eq!(
            bind_socket_until(&path, start + Duration::from_millis(150)).unwrap_err(),
            "SocketInUse"
        );
        assert!(start.elapsed() < Duration::from_secs(2));
        first.set_nonblocking(true).unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            match first.accept() {
                Ok((peer, _)) => {
                    drop(peer);
                    break;
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(Instant::now() < deadline);
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(e) => panic!("{e}"),
            }
        }
        // Deterministically model the listener lifetime extension between fork
        // and exec. The production retry must recover without test-side retries.
        let inherited = first.try_clone().unwrap();
        let holder = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(150));
            drop(inherited);
        });
        drop(first);
        let restarted = bind_socket(&path).unwrap();
        holder.join().unwrap();
        assert!(connect::connect_timeout(&path, Duration::from_millis(200)).is_ok());
        drop(restarted);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn ai_startup_lock_releases_even_with_an_inherited_descriptor() {
        let dir = std::env::temp_dir().join(format!("ai-{}", id()));
        fs::create_dir(&dir).unwrap();
        let path = dir.join("lock");
        let file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .read(true)
            .open(&path)
            .unwrap();
        let guard = StartupLock::acquire(file, Instant::now() + Duration::from_secs(1)).unwrap();
        let inherited = guard.0.try_clone().unwrap();
        drop(guard);
        let next = StartupLock::acquire(
            fs::File::open(&path).unwrap(),
            Instant::now() + Duration::from_millis(200),
        )
        .unwrap();
        drop(next);
        drop(inherited);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn ai_socket_never_replaces_regular_files_or_symlinks() {
        let dir = std::env::temp_dir().join(format!("ai-{}", id()));
        fs::create_dir(&dir).unwrap();
        let path = dir.join("mcp.sock");
        fs::write(&path, b"keep").unwrap();
        assert_eq!(bind_socket(&path).unwrap_err(), "UnsafeSocketPath");
        assert_eq!(fs::read(&path).unwrap(), b"keep");
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(dir.join("target"), &path).unwrap();
        assert_eq!(bind_socket(&path).unwrap_err(), "UnsafeSocketPath");
        assert!(
            fs::symlink_metadata(&path)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        fs::remove_dir_all(dir).unwrap();
    }
}
