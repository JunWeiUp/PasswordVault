use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
};
pub const HOST: &str = "com.securepass.vault.native_v2";
pub const BROWSERS: [&str; 4] = [
    "Google/Chrome",
    "Microsoft Edge",
    "Microsoft Edge Beta",
    "ego lite",
];
pub fn failure(code: &str) -> Value {
    json!({"ok":false,"error":code})
}
pub fn read(r: &mut impl Read, limit: usize) -> Result<Value, String> {
    let mut size = [0; 4];
    r.read_exact(&mut size).map_err(|_| "unavailable")?;
    let size = u32::from_le_bytes(size) as usize;
    if size == 0 || size > limit {
        return Err("invalid-request".into());
    }
    let mut bytes = zeroize::Zeroizing::new(vec![0; size]);
    r.read_exact(&mut bytes).map_err(|_| "invalid-request")?;
    serde_json::from_slice(&bytes).map_err(|_| "invalid-request".into())
}
pub fn write(w: &mut impl Write, value: &Value) -> Result<(), String> {
    let bytes = zeroize::Zeroizing::new(serde_json::to_vec(value).map_err(|_| "invalid-request")?);
    if bytes.len() > 1_000_000 {
        return Err("invalid-request".into());
    }
    w.write_all(&(bytes.len() as u32).to_le_bytes())
        .and_then(|_| w.write_all(&bytes))
        .and_then(|_| w.flush())
        .map_err(|_| "unavailable".into())
}
pub fn bundle() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|_| "unavailable")?;
    let contents = exe.parent().and_then(Path::parent).ok_or("unavailable")?;
    if contents.file_name().and_then(|v| v.to_str()) != Some("Contents") {
        return Err("Signed preview bundle required".into());
    }
    Ok(contents.to_path_buf())
}
pub fn identity(contents: &Path) -> Result<String, String> {
    let value: Value = serde_json::from_slice(
        &std::fs::read(contents.join("Resources/BrowserIdentity.json"))
            .map_err(|_| "unavailable")?,
    )
    .map_err(|_| "unavailable")?;
    let id = value["extensionId"].as_str().ok_or("invalid-origin")?;
    if id.len() != 32 || !id.bytes().all(|b| (b'a'..=b'p').contains(&b)) {
        return Err("invalid-origin".into());
    }
    Ok(id.into())
}
pub fn tokens(value: &Value) -> Vec<String> {
    match value {
        Value::String(s) if !s.is_empty() => vec![s.clone()],
        Value::Array(a) => a
            .iter()
            .filter_map(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect(),
        _ => vec![],
    }
}
pub fn paired(settings: &Value, id: &str, token: &str) -> bool {
    !token.is_empty()
        && tokens(&settings["browserPairings"][id])
            .iter()
            .fold(false, |found, s| {
                let equal = s.len() == token.len()
                    && s.bytes()
                        .zip(token.bytes())
                        .fold(0u8, |v, (a, b)| v | (a ^ b))
                        == 0;
                found | equal
            })
}
pub fn browser_request(request: &mut Value) -> Result<(), String> {
    let obj = request.as_object_mut().ok_or("invalid-request")?;
    obj.remove("_backgroundGrant");
    if request["version"] != 2 {
        return Err("invalid-request".into());
    }
    if matches!(
        request["op"].as_str(),
        Some("desktop-auto-unlock" | "authorized-matches" | "authorized-fill")
    ) {
        return Err("unsupported".into());
    }
    Ok(())
}
pub fn manifest_path(home: &Path, browser: &str) -> Result<PathBuf, String> {
    if !BROWSERS.contains(&browser) {
        return Err("invalid-request".into());
    }
    Ok(home
        .join("Library/Application Support")
        .join(browser)
        .join("NativeMessagingHosts")
        .join(format!("{HOST}.json")))
}
pub fn registration(
    home: &Path,
    browser: &str,
    helper: &Path,
    id: &str,
    install: bool,
) -> Result<(), String> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let path = manifest_path(home, browser)?;
    if !install {
        let value: Value =
            serde_json::from_slice(&std::fs::read(&path).map_err(|_| "unavailable")?)
                .map_err(|_| "invalid-request")?;
        if value["path"] != helper.to_string_lossy().as_ref() {
            return Err("Registration belongs to another app".into());
        }
        return std::fs::remove_file(path).map_err(|_| "unavailable".into());
    }
    std::fs::create_dir_all(path.parent().unwrap()).map_err(|_| "unavailable")?;
    let temp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)
        .map_err(|_| "unavailable")?;
    let value = json!({"name":HOST,"description":"PasswordVault native vault connection","path":helper,"type":"stdio","allowed_origins":[format!("chrome-extension://{id}/")]});
    file.write_all(value.to_string().as_bytes())
        .and_then(|_| file.sync_all())
        .and_then(|_| std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o600)))
        .and_then(|_| std::fs::rename(&temp, path))
        .map_err(|_| "unavailable".into())
}
