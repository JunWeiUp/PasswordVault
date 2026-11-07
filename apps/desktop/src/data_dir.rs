//! The Application Support folder for this build, shared by the app and the
//! browser helper (which includes this file by path).

/// Isolated folder used by development and test builds.
pub const PREVIEW_DIRECTORY: &str = "PasswordVaultNSHPreview";

/// The Application Support folder name for this build. A packaged daily-use
/// install sets `PVVaultDirectoryName` in its Info.plist (e.g. the shipping
/// `PasswordVaultNative` folder); development and test builds have no such key
/// and stay on the isolated preview folder.
pub fn data_directory_name() -> String {
    std::env::current_exe()
        .ok()
        .and_then(|exe| Some(exe.parent()?.parent()?.join("Info.plist")))
        .and_then(|plist| std::fs::read_to_string(plist).ok())
        .and_then(|text| {
            let key = text.find("<key>PVVaultDirectoryName</key>")?;
            let rest = &text[key..];
            let start = rest.find("<string>")? + "<string>".len();
            let end = rest[start..].find("</string>")? + start;
            let name = rest[start..end].trim().to_string();
            // A plain folder name only: no separators or parent references.
            (!name.is_empty() && !name.contains('/') && name != "." && name != "..").then_some(name)
        })
        .unwrap_or_else(|| PREVIEW_DIRECTORY.to_string())
}

/// Resolve the native storage root without silently writing vaults into cwd.
/// Windows previews never inspect a macOS bundle or reuse its production name.
pub fn default_vault_directory() -> std::path::PathBuf {
    #[cfg(target_os = "windows")]
    {
        let root = std::env::var_os("LOCALAPPDATA")
            .filter(|value| !value.is_empty())
            .map(std::path::PathBuf::from)
            .filter(|path| path.is_absolute())
            .expect("LOCALAPPDATA must be an absolute directory for vault storage");
        return root.join(PREVIEW_DIRECTORY).join("vault");
    }
    #[cfg(not(target_os = "windows"))]
    {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
        std::path::PathBuf::from(home)
            .join("Library/Application Support")
            .join(data_directory_name())
            .join("vault")
    }
}
