//! Native Windows dialogs. Called from the bridge's blocking worker, never JS.
use std::path::PathBuf;

pub(crate) fn panel(title: String, name: Option<String>, extensions: Vec<String>) -> Result<Option<String>, String> {
    let mut dialog = rfd::FileDialog::new().set_title(title);
    if !extensions.is_empty() {
        dialog = dialog.add_filter("Files", &extensions);
    }
    let selected = match name {
        Some(name) => dialog.set_file_name(name).save_file(),
        None => dialog.pick_file(),
    };
    // A lossy path could target a different file. Reject it rather than substituting.
    selected.map(|path| path.into_os_string().into_string().map_err(|_| "InvalidData".into())).transpose()
}

pub(crate) fn pick_device_paths() -> Result<Vec<PathBuf>, String> {
    Ok(rfd::FileDialog::new()
        .set_title("导入设备资料（只读取，不执行）")
        .pick_files().unwrap_or_default())
}
