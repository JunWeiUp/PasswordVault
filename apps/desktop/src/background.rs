//! Headless macOS owner. Built without the `ui` feature (and without NSH).
#[cfg(not(feature = "ui"))]
mod server {
    use crate::{browser, hotkey, platform, relay, service_ipc as ipc};
    use base64::{Engine, engine::general_purpose::STANDARD};
    use serde_json::{Value, json};
    use std::{
        os::unix::{fs::PermissionsExt, io::AsRawFd, net::UnixListener},
        path::PathBuf,
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        },
        time::{Duration, Instant},
    };
    use vault_core::VaultSession;
    unsafe extern "C" {
        fn malloc_zone_pressure_relief(zone: *mut std::ffi::c_void, goal: usize) -> usize;
    }
    #[derive(Default)]
    struct UiActivity(std::sync::Mutex<Option<(i32, Instant)>>);
    impl UiActivity {
        fn touch(&self, pid: Option<i32>) {
            if let (Some(pid), Ok(mut lease)) = (pid, self.0.lock()) {
                *lease = Some((pid, Instant::now()));
            }
        }
        fn active_at(&self, now: Instant, alive: impl FnOnce(i32) -> bool) -> bool {
            self.0
                .lock()
                .ok()
                .and_then(|value| *value)
                .is_some_and(|(pid, seen)| {
                    now.saturating_duration_since(seen) < Duration::from_secs(5) && alive(pid)
                })
        }
        fn active(&self) -> bool {
            self.active_at(Instant::now(), |pid| unsafe { libc::kill(pid, 0) == 0 })
        }
    }
    fn release(session: &VaultSession, activity: &UiActivity) {
        // Only the authenticated, live UI can keep the document warm. Browser
        // requests never refresh this lease. A crash/timeout still releases it.
        if activity.active() {
            return;
        }
        let _ = session.release_idle_document();
        unsafe {
            malloc_zone_pressure_relief(std::ptr::null_mut(), 0);
        }
    }
    fn string(args: &Value, name: &str) -> Result<String, String> {
        args[name]
            .as_str()
            .map(str::to_owned)
            .ok_or("InvalidData".into())
    }
    fn bytes(args: &Value, name: &str) -> Result<Vec<u8>, String> {
        serde_json::from_value(args[name].clone()).map_err(|_| "InvalidData".into())
    }
    fn dispatch(
        session: &Arc<VaultSession>,
        directory: &std::path::Path,
        method: &str,
        args: &Value,
    ) -> Result<Value, String> {
        let error = crate::error_code;
        match method {
            "ping" => Ok(json!(true)),
            "browser-start" => {
                browser::request_startup(directory)?;
                Ok(json!(true))
            }
            "command" => {
                let request = zeroize::Zeroizing::new(string(args, "request")?);
                let mut parsed: Value =
                    serde_json::from_str(&request).map_err(|_| "InvalidData")?;
                if parsed["op"] == "lock" {
                    browser::cancel_startup_native();
                    relay::stop_background(session);
                }
                ipc::wipe(&mut parsed);
                session
                    .command(request.to_string())
                    .map(Value::String)
                    .map_err(error)
            }
            "authorized-browser" => session
                .authorized_browser_command(bytes(args, "grant")?, string(args, "request")?)
                .map(Value::String)
                .map_err(error),
            "background-save" => session
                .background_save(bytes(args, "grant")?, string(args, "request")?)
                .map(Value::String)
                .map_err(error),
            "unlock-grant" => session
                .unlock_desktop_grant(bytes(args, "grant")?)
                .map(|_| Value::Null)
                .map_err(error),
            "unlock-biometric" => session
                .unlock_biometric(bytes(args, "key")?)
                .map(|_| Value::Null)
                .map_err(error),
            "biometric-key" => session
                .biometric_key()
                .map(|mut key| {
                    use zeroize::Zeroize;
                    let value = json!(STANDARD.encode(&key));
                    key.zeroize();
                    value
                })
                .map_err(error),
            "attachment-import" => session
                .import_note_attachment(
                    string(args, "noteId")?,
                    string(args, "name")?,
                    string(args, "mime")?,
                    STANDARD
                        .decode(string(args, "data")?)
                        .map_err(|_| "InvalidData")?,
                )
                .map(Value::String)
                .map_err(error),
            "attachment-read" => session
                .read_note_attachment(string(args, "noteId")?, string(args, "id")?)
                .map(|mut data| {
                    use zeroize::Zeroize;
                    let value = json!(STANDARD.encode(&data));
                    data.zeroize();
                    value
                })
                .map_err(error),
            "attachment-import-file" => session
                .import_note_attachment_file(
                    string(args, "noteId")?,
                    string(args, "path")?,
                    string(args, "name")?,
                    string(args, "mime")?,
                )
                .map(Value::String)
                .map_err(error),
            "attachment-export-file" => session
                .export_note_attachment_file(
                    string(args, "noteId")?,
                    string(args, "id")?,
                    string(args, "destPath")?,
                    args["readonly"] == true,
                )
                .map(Value::String)
                .map_err(error),
            "attachment-discard" => session
                .discard_note_attachment(string(args, "noteId")?, string(args, "id")?)
                .map(|_| Value::Null)
                .map_err(error),
            "browser-cancel" => {
                browser::cancel_startup_native();
                Ok(Value::Null)
            }
            "browser-pending" => Ok(json!(browser::pending_native())),
            "browser-poll" => Ok(json!(browser::poll_native())),
            "browser-approve" => {
                browser::approve_native(string(args, "challenge")?, args["allow"] == true);
                Ok(Value::Null)
            }
            "browser-approve-passkey" => {
                browser::approve_passkey_native(string(args, "challenge")?, args["selection"].clone());
                Ok(Value::Null)
            }
            "hotkey-configure" => {
                let choice = string(args, "choice")?;
                let ok = hotkey::configure_background(choice.clone());
                if ok {
                    std::fs::write(directory.join("quick-access-shortcut"), choice)
                        .map_err(|_| "Storage")?;
                }
                Ok(json!(ok))
            }
            "hotkey-poll" => Ok(json!(hotkey::poll_background())),
            "relay" => relay::background_dispatch(session.clone(), directory.to_path_buf(), args),
            _ => Err("Unsupported".into()),
        }
    }
    #[cfg(test)]
    mod lease_tests {
        use super::*;
        #[test]
        fn only_a_live_recent_ui_keeps_the_document_warm() {
            let lease = UiActivity::default();
            let now = Instant::now();
            assert!(!lease.active_at(now, |_| true));
            lease.touch(Some(123));
            let now = Instant::now();
            assert!(lease.active_at(now, |pid| pid == 123));
            assert!(!lease.active_at(now, |_| false));
            assert!(!lease.active_at(now + Duration::from_secs(5), |_| true));
        }
    }

    pub fn run() -> Result<(), String> {
        let mut args = std::env::args();
        if args.nth(1).as_deref() != Some("--vault-directory") {
            return Err("InvalidData".into());
        }
        let directory = PathBuf::from(args.next().ok_or("InvalidData")?);
        if !directory.is_absolute() {
            return Err("InvalidData".into());
        }
        // Initialize AppKit's event infrastructure without creating any window.
        let mtm = objc2::MainThreadMarker::new().ok_or("Storage")?;
        let app = objc2_app_kit::NSApplication::sharedApplication(mtm);
        app.setActivationPolicy(objc2_app_kit::NSApplicationActivationPolicy::Prohibited);
        let choice = std::fs::read_to_string(directory.join("quick-access-shortcut"))
            .unwrap_or_else(|_| "command-shift-space".into());
        hotkey::initialize_background(&choice);
        let session = Arc::new(
            VaultSession::new(directory.to_string_lossy().into()).map_err(crate::error_code)?,
        );
        let path = directory.join("service.sock");
        // Session's exclusive flock makes stale socket removal safe.
        if path.exists() {
            std::fs::remove_file(&path).map_err(|_| "Storage")?;
        }
        let listener = UnixListener::bind(&path).map_err(|_| "Storage")?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| "Storage")?;
        browser::start(session.clone(), &directory)?;
        let ui = ipc::application_contents()?.join("MacOS/PasswordVault");
        let activity = Arc::new(UiActivity::default());
        let socket_activity = activity.clone();
        let active = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let worker_session = session.clone();
        let worker_directory = directory.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { break };
                if !ipc::same_user(stream.as_raw_fd())
                    || !ipc::security::peer(stream.as_raw_fd(), &ui)
                {
                    if std::env::var_os("PV_SERVICE_DIAGNOSTICS").is_some() {
                        eprintln!("service rejected IPC identity");
                    }
                    continue;
                }
                if active.fetch_add(1, Ordering::SeqCst) >= 8 {
                    active.fetch_sub(1, Ordering::SeqCst);
                    continue;
                }
                let peer_pid = ipc::peer_pid(stream.as_raw_fd());
                let activity = socket_activity.clone();
                let (session, directory, active, stop) = (
                    worker_session.clone(),
                    worker_directory.clone(),
                    active.clone(),
                    stop.clone(),
                );
                std::thread::spawn(move || {
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(120)));
                    let _ = stream.set_write_timeout(Some(Duration::from_secs(120)));
                    if let Ok(mut request) = ipc::read(&mut stream) {
                        let id = request["id"].as_str().unwrap_or("").to_owned();
                        let valid = request["version"] == 1 && !id.is_empty() && id.len() <= 64;
                        let method = request["method"].as_str().unwrap_or("");
                        if valid && method != "shutdown" {
                            activity.touch(peer_pid);
                        }
                        let result = if !valid {
                            Err("InvalidData".into())
                        } else if method == "shutdown" {
                            if ipc::mark_stopped(&directory).is_err() {
                                ipc::wipe(&mut request);
                                active.fetch_sub(1, Ordering::SeqCst);
                                return;
                            }
                            browser::cancel_startup_native();
                            relay::stop_background(&session);
                            let _ = session.command(r#"{"op":"lock"}"#.into());
                            stop.store(true, Ordering::SeqCst);
                            Ok(Value::Null)
                        } else {
                            dispatch(&session, &directory, method, &request["args"])
                        };

                        let mut reply = match result {
                            Ok(value) => json!({"version":1,"id":id,"value":value}),
                            Err(error) => json!({"version":1,"id":id,"error":error}),
                        };
                        ipc::wipe(&mut request);
                        let _ = ipc::write(&mut stream, &reply);
                        ipc::wipe(&mut reply);
                        release(&session, &activity);
                    }
                    active.fetch_sub(1, Ordering::SeqCst);
                    if stop.load(Ordering::SeqCst) {
                        std::process::exit(0);
                    }
                });
            }
        });
        // AppKit/Carbon notifications require a main-thread run loop, not a UI runtime.
        let _ = platform::poll();
        std::thread::spawn(move || {
            let mut unlocked_since = Instant::now();
            let mut was_unlocked = false;
            loop {
                std::thread::sleep(Duration::from_millis(250));
                let signals: Value = serde_json::from_str(&platform::poll()).unwrap_or(Value::Null);
                let settings = session
                    .command(r#"{"op":"read-settings"}"#.into())
                    .ok()
                    .and_then(|s| serde_json::from_str::<Value>(&s).ok());
                let unlocked = settings.is_some();
                if unlocked && !was_unlocked {
                    unlocked_since = Instant::now();
                    let _ = relay::connect_background(session.clone(), directory.clone());
                }
                if !unlocked && was_unlocked {
                    // Lock can also originate from the browser while the UI is absent.
                    relay::stop_background(&session);
                }
                was_unlocked = unlocked;
                if let Some(mut settings) = settings {
                    let events = signals["events"].as_u64().unwrap_or(0);
                    let sleep = events & 1 != 0 && settings["macLockOnSleep"] != false;
                    let screen = events & 14 != 0 && settings["macLockOnScreenLock"] != false;
                    let idle = signals["idleSeconds"]
                        .as_f64()
                        .unwrap_or(0.)
                        .min(unlocked_since.elapsed().as_secs_f64());
                    let limit = settings["autoLockMinutes"]
                        .as_f64()
                        .unwrap_or(60.)
                        .clamp(1., 120.)
                        * 60.;
                    if sleep || screen || (settings["macNeverIdleLock"] != true && idle >= limit) {
                        browser::cancel_startup_native();
                        relay::stop_background(&session);
                        let _ = session.command(r#"{"op":"lock"}"#.into());
                    }
                    ipc::wipe(&mut settings);
                }
                release(&session, &activity);
            }
        });
        app.run();
        Ok(())
    }
}
#[cfg(not(feature = "ui"))]
pub use server::run;
/// Reopen the sibling UI bundle. No account content or credentials in arguments.
pub(crate) fn show_interface() {
    if let Ok(contents) = crate::service_ipc::application_contents() {
        if let Some(app) = contents.parent() {
            let _ = std::process::Command::new("/usr/bin/open").arg(app).spawn();
        }
    }
}
