//! Test-only window placement: with `PV_QA_SCREEN` set (by `tool/macos-nsh/gui.sh`),
//! the app moves its window onto the yomado virtual screen of that name. Native
//! Shell 0.3.0 always centers windows on the main display and has no `--display`.
//! Without the variable, nothing happens.

#[cfg(target_os = "macos")]
pub fn place_for_qa() {
    use objc2::MainThreadMarker;
    use objc2_app_kit::{NSApplication, NSScreen};
    use objc2_foundation::{NSOperationQueue, NSPoint};
    use std::sync::Once;

    static ONCE: Once = Once::new();
    let Ok(name) = std::env::var("PV_QA_SCREEN") else { return };
    if name.is_empty() {
        return;
    }
    ONCE.call_once(move || {
        std::thread::spawn(move || {
            for _ in 0..100 {
                std::thread::sleep(std::time::Duration::from_millis(100));
                let (tx, rx) = std::sync::mpsc::channel();
                let name = name.clone();
                let block = block2::RcBlock::new(move || {
                    let Some(mtm) = MainThreadMarker::new() else { return };
                    let app = NSApplication::sharedApplication(mtm);
                    let windows = app.windows();
                    let Some(window) = windows.iter().find(|w| w.isVisible()) else {
                        let _ = tx.send(false);
                        return;
                    };
                    let screens = NSScreen::screens(mtm);
                    let Some(screen) = screens.iter().find(|s| s.localizedName().to_string().contains(&name)) else {
                        log::warn!("PV_QA_SCREEN: no screen named {name}; window left in place");
                        let _ = tx.send(true);
                        return;
                    };
                    let area = screen.visibleFrame();
                    let frame = window.frame();
                    let x = area.origin.x + ((area.size.width - frame.size.width) / 2.0).max(0.0);
                    let y = area.origin.y + ((area.size.height - frame.size.height) / 2.0).max(0.0);
                    window.setFrameOrigin(NSPoint::new(x, y));
                    let _ = tx.send(true);
                });
                // SAFETY: the block only touches AppKit after checking it runs on the main thread.
                unsafe { NSOperationQueue::mainQueue().addOperationWithBlock(&block) };
                if rx.recv_timeout(std::time::Duration::from_secs(2)).unwrap_or(false) {
                    return;
                }
            }
        });
    });
}

#[cfg(not(target_os = "macos"))]
pub fn place_for_qa() {}
