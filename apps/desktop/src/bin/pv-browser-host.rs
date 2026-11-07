//! Platform entry point; authenticated helpers are currently macOS-only.
#[cfg(target_os = "macos")]
#[path = "macos/pv-browser-host.rs"]
mod implementation;
#[cfg(target_os = "macos")]
fn main() { implementation::main(); }
#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("This helper is not available on Windows yet.");
    std::process::exit(2);
}
