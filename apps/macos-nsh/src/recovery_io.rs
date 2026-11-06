//! Emergency archives stay in native memory and never cross the JS bridge.
use crate::{Vault, error_code};
use nsh_core::prelude::*;
use std::io::{Read, Write};
use zeroize::Zeroizing;

/// Emergency archive IO and the system recovery-key print panel.
#[module]
pub struct RecoveryIO;
#[module]
impl RecoveryIO {
    /// Uses the system print panel; no plaintext temporary file is created.
    pub async fn print_key(key: String) -> Result<(), String> {
        let key = Zeroizing::new(key);
        blocking(move || {
            dispatch2::DispatchQueue::main().exec_sync(move || {
                use objc2::{class, msg_send, rc::{Retained, Allocated}, runtime::{AnyObject, Bool}};
                use objc2_foundation::{NSString, NSRect, NSPoint, NSSize};
                unsafe {
                    let view: Allocated<AnyObject> = msg_send![class!(NSTextView), alloc];
                    let view: Retained<AnyObject> = msg_send![view, initWithFrame: NSRect::new(NSPoint::new(0., 0.), NSSize::new(500., 300.))];
                    let text = NSString::from_str(&format!("PasswordVault recovery key\n\n{}\n\nKeep separately from your emergency backup.", key.as_str()));
                    let _: () = msg_send![&*view, setString: &*text];
                    let operation: Retained<AnyObject> = msg_send![class!(NSPrintOperation), printOperationWithView: &*view];
                    let _: Bool = msg_send![&*operation, runOperation];
                    let _: () = msg_send![&*view, setString: &*NSString::from_str("")];
                }
            });
            Ok(())
        }).await.map_err(|_| "Storage".to_string())?
    }

    /// Writes an emergency archive without returning its bytes to JS.
    pub async fn export(vault: Instance<Vault>, key: String, path: String) -> Result<(), String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        let key = Zeroizing::new(key);
        blocking(move || {
            let request = Zeroizing::new(serde_json::json!({"op":"recovery-export","key":key.as_str(),"richNotes":true}).to_string());
            let response = Zeroizing::new(session.command(request.to_string()).map_err(error_code)?);
            let value: serde_json::Value = serde_json::from_str(&response).map_err(|_| "InvalidData")?;
            let content = value["content"].as_str().ok_or("InvalidData")?;
            write_archive(&path, content)
        }).await.map_err(|_| "Storage".to_string())?
    }
    /// Restores an archive into a nonexistent vault only.
    pub async fn restore(vault: Instance<Vault>, key: String, new_password: String, path: String) -> Result<(), String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        let key = Zeroizing::new(key);
        let password = Zeroizing::new(new_password);
        blocking(move || {
            let content = read_archive(&path)?;
            let request = Zeroizing::new(serde_json::json!({"op":"recovery-restore-backup","key":key.as_str(),"newPassword":password.as_str(),"content":content.as_str(),"richNotes":true}).to_string());
            session.command(request.to_string()).map_err(error_code)?;
            Ok(())
        }).await.map_err(|_| "Storage".to_string())?
    }
}

fn write_archive(path: &str, content: &str) -> Result<(), String> {
    // Refuse replacement, including symlinks, even after panel confirmation.
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
    let mut file = options.open(path).map_err(|_| "Storage")?;
    if file.write_all(content.as_bytes()).and_then(|_| file.sync_all()).is_err() {
        let _ = std::fs::remove_file(path);
        return Err("Storage".to_string());
    }
    Ok(())
}
fn read_archive(path: &str) -> Result<Zeroizing<String>, String> {
    const LIMIT: u64 = 1024 * 1024 * 1024;
    let file = std::fs::File::open(path).map_err(|_| "Storage")?;
    let meta = file.metadata().map_err(|_| "Storage")?;
    if !meta.is_file() || meta.len() > LIMIT { return Err("InvalidData".into()); }
    let mut content = Zeroizing::new(String::new());
    file.take(LIMIT + 1).read_to_string(&mut content).map_err(|_| "InvalidData")?;
    if content.len() as u64 > LIMIT { return Err("InvalidData".into()); }
    Ok(content)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recovery_io_archive_authentication_and_existing_target_boundary() {
        use serde_json::json;
        let root = std::env::temp_dir().join(format!("pv-recovery-roundtrip-{}", std::process::id()));
        std::fs::create_dir(&root).unwrap();
        let source = vault_core::VaultSession::new(root.join("source").to_string_lossy().into()).unwrap();
        let command = |v: serde_json::Value| -> serde_json::Value {
            serde_json::from_str(&source.command(v.to_string()).unwrap()).unwrap()
        };
        command(json!({"op":"create","password":"synthetic-original"}));
        let key = command(json!({"op":"recovery-generate"}))["key"].as_str().unwrap().to_owned();
        command(json!({"op":"recovery-enable","key":key,"currentPassword":"synthetic-original"}));
        let archive = command(json!({"op":"recovery-export","key":key}));
        let path = root.join("archive.pvbackup");
        write_archive(path.to_str().unwrap(), archive["content"].as_str().unwrap()).unwrap();
        let content = read_archive(path.to_str().unwrap()).unwrap();
        let target = vault_core::VaultSession::new(root.join("target").to_string_lossy().into()).unwrap();
        let request = |key: &str| json!({"op":"recovery-restore-backup","key":key,"content":content.as_str(),"newPassword":"synthetic-new"}).to_string();
        assert!(target.command(request("invalid-key")).is_err());
        target.command(request(&key)).unwrap();
        assert!(target.command(request(&key)).is_err());
        target.command(json!({"op":"lock"}).to_string()).unwrap();
        target.command(json!({"op":"unlock","password":"synthetic-new"}).to_string()).unwrap();
        drop(target); drop(source);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn recovery_io_never_overwrites_and_rejects_invalid_archives() {
        let root = std::env::temp_dir().join(format!("pv-recovery-io-{}", std::process::id()));
        std::fs::create_dir(&root).unwrap();
        let path = root.join("backup.pvbackup");
        let path = path.to_str().unwrap();
        write_archive(path, "synthetic encrypted archive").unwrap();
        assert!(write_archive(path, "replacement").is_err());
        assert_eq!(read_archive(path).unwrap().as_str(), "synthetic encrypted archive");
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(path).unwrap().permissions().mode() & 0o777, 0o600);
        let link = root.join("link");
        std::os::unix::fs::symlink(path, &link).unwrap();
        assert!(write_archive(link.to_str().unwrap(), "replacement").is_err());
        assert!(read_archive(root.to_str().unwrap()).is_err());
        std::fs::write(path, [0xff]).unwrap();
        assert!(read_archive(path).is_err());
        std::fs::OpenOptions::new().write(true).open(path).unwrap().set_len(1024 * 1024 * 1024 + 1).unwrap();
        assert!(read_archive(path).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
