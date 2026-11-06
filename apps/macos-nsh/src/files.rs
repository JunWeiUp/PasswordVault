//! System file panels and bounded, inert device-document imports.
use nsh_core::prelude::*;
/// Native macOS file pickers returning paths only.
#[module]
pub struct Files;

pub(crate) fn panel(
    title: String,
    name: Option<String>,
    extensions: Vec<String>,
) -> Result<Option<String>, String> {
    use objc2::MainThreadMarker;
    use objc2_app_kit::{NSOpenPanel, NSSavePanel};
    use objc2_foundation::{NSArray, NSString};
    let (send, recv) = std::sync::mpsc::sync_channel(1);
    dispatch2::DispatchQueue::main().exec_sync(move || {
        let mtm = MainThreadMarker::new().expect("main queue");
        let save;
        let open;
        let p: &NSSavePanel = if let Some(name) = name {
            save = NSSavePanel::savePanel(mtm);
            save.setNameFieldStringValue(&NSString::from_str(&name));
            &save
        } else {
            open = NSOpenPanel::openPanel(mtm);
            open.setCanChooseDirectories(false);
            open.setAllowsMultipleSelection(false);
            &open
        };
        p.setTitle(Some(&NSString::from_str(&title)));
        let types: Vec<_> = extensions.iter().map(|s| NSString::from_str(s)).collect();
        #[allow(deprecated)]
        p.setAllowedFileTypes(Some(&NSArray::from_retained_slice(&types)));
        p.setCanCreateDirectories(true);
        let path = if p.runModal() == 1 {
            p.URL().and_then(|u| u.path()).map(|s| s.to_string())
        } else {
            None
        };
        let _ = send.send(path);
    });
    recv.recv().map_err(|_| "Storage".into())
}
const DEVICE_FILE_LIMIT: u64 = 256 * 1024;
const DEVICE_TOTAL_LIMIT: usize = 1024 * 1024;
fn read_device_documents(paths: Vec<std::path::PathBuf>) -> Result<String, String> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;
    if paths.len() > 32 { return Err("最多选择 32 个设备资料文件".into()); }
    let mut total = 0usize;
    let mut result = Vec::new();
    for path in paths {
        let name = path.file_name().and_then(|v| v.to_str()).ok_or("文件名不是有效 UTF-8")?;
        if name.len() > 1024 { return Err("文件名过长".into()); }
        // Open read-only, reject symlinks/FIFOs/devices, and bound the actual read
        // as well as metadata so a changing file cannot bypass the size limit.
        let file = std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&path).map_err(|_| "无法读取设备资料文件")?;
        let meta = file.metadata().map_err(|_| "无法读取设备资料文件")?;
        if !meta.is_file() || meta.len() > DEVICE_FILE_LIMIT { return Err("设备资料必须是普通文件，每个不超过 256 KiB".into()); }
        let mut bytes = zeroize::Zeroizing::new(Vec::new());
        file.take(DEVICE_FILE_LIMIT + 1).read_to_end(&mut bytes).map_err(|_| "无法读取设备资料文件")?;
        total += bytes.len();
        if bytes.len() as u64 > DEVICE_FILE_LIMIT || total > DEVICE_TOTAL_LIMIT { return Err("设备资料每个不超过 256 KiB，合计不超过 1 MiB".into()); }
        let text = std::str::from_utf8(&bytes).map_err(|_| "设备资料必须是 UTF-8 文本")?;
        if text.contains('\0') { return Err("设备资料不能包含二进制内容".into()); }
        // IDs must not expose an unkeyed fingerprint of a low-entropy secret.
        // Duplicate checks compare filename/text only inside the unlocked UI.
        result.push(serde_json::json!({"id":uuid::Uuid::new_v4().to_string(),"name":name,"text":text,"size":bytes.len()}));
    }
    serde_json::to_string(&result).map_err(|_| "InvalidData".into())
}
fn pick_device_paths() -> Result<Vec<std::path::PathBuf>, String> {
    use objc2::MainThreadMarker;
    use objc2_app_kit::NSOpenPanel;
    use objc2_foundation::NSString;
    let (send, recv) = std::sync::mpsc::sync_channel(1);
    dispatch2::DispatchQueue::main().exec_sync(move || {
        let panel = NSOpenPanel::openPanel(MainThreadMarker::new().expect("main queue"));
        panel.setCanChooseDirectories(false);
        panel.setAllowsMultipleSelection(true);
        panel.setResolvesAliases(false);
        panel.setTitle(Some(&NSString::from_str("导入设备资料（只读取，不执行）")));
        let paths = if panel.runModal() == 1 {
            panel.URLs().iter().filter_map(|url| url.path()).map(|p| std::path::PathBuf::from(p.to_string())).collect()
        } else { Vec::new() };
        let _ = send.send(paths);
    });
    recv.recv().map_err(|_| "Storage".into())
}
#[module]
impl Files {
    /// User-selected device documents only. Never executes, moves or rewrites sources.
    pub async fn pick_device_documents(vault: Instance<crate::Vault>) -> Result<String, String> {
        let session = vault.with(|v| v.session.clone()).ok_or("Locked")?;
        blocking(move || {
            let unlocked = || -> Result<(), String> {
                let state: serde_json::Value = serde_json::from_str(&session.command(r#"{"op":"status"}"#.into()).map_err(crate::error_code)?).map_err(|_| "InvalidData")?;
                if state["unlocked"] != true { return Err("Locked".into()); }
                Ok(())
            };
            unlocked()?;
            let paths = pick_device_paths()?;
            unlocked()?;
            let result = zeroize::Zeroizing::new(read_device_documents(paths)?);
            unlocked()?;
            Ok(result.to_string())
        }).await.map_err(|_| "Storage".to_owned())?
    }
    /// Selects one existing file; cancellation returns null.
    pub async fn pick_open(
        title: String,
        extensions: Vec<String>,
    ) -> Result<Option<String>, String> {
        blocking(move || panel(title, None, extensions))
            .await
            .map_err(|_| "Storage".to_string())?
    }
    /// Selects a destination; cancellation returns null.
    pub async fn pick_save(
        title: String,
        suggested_name: String,
        extensions: Vec<String>,
    ) -> Result<Option<String>, String> {
        blocking(move || panel(title, Some(suggested_name), extensions))
            .await
            .map_err(|_| "Storage".to_string())?
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn device_documents_are_bounded_utf8_inert_and_preserved() {
        let root = std::env::temp_dir().join(format!("pv-device-import-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let script = root.join("示例北区-控制台.command");
        let marker = root.join("must-not-exist");
        let content = format!("#!/bin/sh\r\ntouch '{}'\r\n", marker.display());
        std::fs::write(&script, &content).unwrap();
        let token = root.join("示例北区-令牌.txt");
        std::fs::write(&token, "SYNTHETIC_TOKEN\n").unwrap();
        let first: serde_json::Value = serde_json::from_str(&read_device_documents(vec![script.clone(), token.clone()]).unwrap()).unwrap();
        assert_eq!(first[0]["text"], content);
        assert_eq!(first[0]["name"], "示例北区-控制台.command");
        assert_eq!(first[1]["text"], "SYNTHETIC_TOKEN\n");
        assert!(!marker.exists());
        assert_eq!(std::fs::read_to_string(&script).unwrap(), content);
        let again: serde_json::Value = serde_json::from_str(&read_device_documents(vec![script.clone()]).unwrap()).unwrap();
        assert_ne!(first[0]["id"], again[0]["id"]);
        assert_eq!(first[0]["text"], again[0]["text"]);
        std::fs::write(&token, [0xff, 0xfe]).unwrap();
        assert!(read_device_documents(vec![token.clone()]).is_err());
        std::fs::write(&token, b"binary\0data").unwrap();
        assert!(read_device_documents(vec![token.clone()]).is_err());
        std::fs::write(&token, vec![b'x'; DEVICE_FILE_LIMIT as usize + 1]).unwrap();
        assert!(read_device_documents(vec![token.clone()]).is_err());
        std::fs::write(&token, vec![b'x'; DEVICE_FILE_LIMIT as usize]).unwrap();
        assert!(read_device_documents(vec![token.clone(); 5]).is_err());
        assert!(read_device_documents(vec![script.clone(); 33]).is_err());
        let link = root.join("link.txt");
        std::os::unix::fs::symlink(&script, &link).unwrap();
        assert!(read_device_documents(vec![link]).is_err());
        let wrong = root.join("source.sh");
        std::fs::write(&wrong, "echo never-run").unwrap();
        assert!(read_device_documents(vec![wrong]).is_ok());
        for extension in ["py", "js", "json", "yaml", "toml", "conf", "custom"] {
            let path = root.join(format!("example.{extension}"));
            std::fs::write(&path, "  preserved\r\n\tcontent\n").unwrap();
            let parsed: serde_json::Value = serde_json::from_str(&read_device_documents(vec![path]).unwrap()).unwrap();
            assert_eq!(parsed[0]["text"], "  preserved\r\n\tcontent\n");
        }
        assert_eq!(read_device_documents(vec![]).unwrap(), "[]");
        std::fs::remove_dir_all(root).unwrap();
    }
}
