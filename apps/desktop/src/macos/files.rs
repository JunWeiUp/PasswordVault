//! AppKit file dialogs; the shared Files bridge handles validation and import.
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
pub(crate) fn pick_device_paths() -> Result<Vec<std::path::PathBuf>, String> {
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
