//! Synthetic QA client. Not included in application packages.
#[cfg(target_os = "macos")]
#[path = "../src/service_ipc.rs"]
mod service_ipc;
#[cfg(target_os = "macos")]
fn main() {
    use std::io::{BufRead, Read, Write};
    let directory = std::path::PathBuf::from(std::env::args().nth(1).expect("synthetic directory"));
    assert!(directory.starts_with("/tmp") || directory.starts_with("/private/tmp"));
    let invoke = |input: &str| {
        let request: serde_json::Value = serde_json::from_str(input).unwrap();
        let result = service_ipc::control(
            &directory,
            request["method"].as_str().unwrap(),
            request["args"].clone(),
        );
        match result {
            Ok(value) => serde_json::json!({"value":value}),
            Err(error) => serde_json::json!({"error":error}),
        }
    };
    if std::env::args().nth(2).as_deref() == Some("--stream") {
        for line in std::io::stdin().lock().lines() {
            let output = invoke(&line.unwrap());
            println!("{output}");
            std::io::stdout().flush().unwrap();
        }
    } else {
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input).unwrap();
        let output = invoke(&input);
        std::io::stdout()
            .write_all(output.to_string().as_bytes())
            .unwrap();
    }
}
#[cfg(not(target_os = "macos"))]
fn main() {}
