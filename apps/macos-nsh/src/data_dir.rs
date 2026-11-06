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
