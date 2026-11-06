//! Synthetic stdin fixture only: always opens a fresh temporary vault, never user data.
use std::io::{self, BufRead};
use vault_core::VaultSession;
fn main() {
    let directory = tempfile::tempdir().expect("fixture directory");
    let vault =
        VaultSession::new(directory.path().to_string_lossy().into()).expect("fixture vault");
    for line in io::stdin().lock().lines() {
        let result = line
            .map_err(|_| "input".to_string())
            .and_then(|line| vault.command(line).map_err(|e| e.to_string()));
        match result {
            Ok(value) => println!("{{\"ok\":{value}}}"),
            Err(error) => println!("{}", serde_json::json!({"error":error})),
        }
    }
}
