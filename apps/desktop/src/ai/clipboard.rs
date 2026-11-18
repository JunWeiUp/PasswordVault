//! Delivers an approved secret to the system clipboard instead of the AI client.
//! The value is marked concealed/transient for clipboard managers and cleared after
//! `seconds` unless the user has copied something else meanwhile.
use super::Result;

#[cfg(test)]
pub(super) static LAST: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

#[cfg(test)]
pub(super) fn put(value: &str, _seconds: u64) -> Result<()> {
    *LAST.lock().unwrap() = Some(value.to_string());
    Ok(())
}

#[cfg(all(not(test), target_os = "macos"))]
pub(super) fn put(value: &str, seconds: u64) -> Result<()> {
    use objc2_app_kit::NSPasteboard;
    use objc2_foundation::{NSArray, NSString};
    let board = NSPasteboard::generalPasteboard();
    let text = NSString::from_str("public.utf8-plain-text");
    let concealed = NSString::from_str("org.nspasteboard.ConcealedType");
    let transient = NSString::from_str("org.nspasteboard.TransientType");
    let change = {
        board.clearContents();
        let types = NSArray::from_slice(&[&*text, &*concealed, &*transient]);
        unsafe { board.declareTypes_owner(&types, None) };
        let value = NSString::from_str(value);
        if !board.setString_forType(&value, &text) {
            return Err("ClipboardUnavailable".into());
        }
        board.setString_forType(&NSString::from_str(""), &concealed);
        board.setString_forType(&NSString::from_str(""), &transient);
        board.changeCount()
    };
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_secs(seconds));
        let board = NSPasteboard::generalPasteboard();
        // Only clear our own write; the user may have copied something since.
        if board.changeCount() == change {
            board.clearContents();
        }
    });
    Ok(())
}

#[cfg(all(not(test), not(target_os = "macos")))]
pub(super) fn put(_value: &str, _seconds: u64) -> Result<()> {
    Err("Unsupported".into())
}
