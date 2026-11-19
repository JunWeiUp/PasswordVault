//! Stdio MCP adapter and script CLI. No vault session or vault directory access.
//! Standalone lightweight workspace member so edits to pv-mcp never rebuild the
//! full desktop UI library.

#[cfg(target_os = "macos")]
#[path = "../../../src/ai/socket/connect.rs"]
mod connect;

#[cfg(target_os = "macos")]
mod implementation {
    use crate::connect;

    use serde_json::{Value, json};
    use std::{
        io::{self, BufRead, BufReader, Write},
        os::unix::io::AsRawFd,
        time::Duration,
    };

    const TOOLS_SCHEMA_JSON: &str = include_str!("../../../src/ai/tools.schema.json");

    unsafe extern "C" {
        fn getpeereid(fd: i32, uid: *mut u32, gid: *mut u32) -> i32;
        fn geteuid() -> u32;
    }

    fn rpc(mut request: Value) -> Result<Value, String> {
        let path = std::env::var("PV_AI_SOCKET").map_err(|_| "Set PV_AI_SOCKET")?;
        let mut s = connect::connect_timeout(std::path::Path::new(&path), Duration::from_secs(3))
            .map_err(|_| "AppUnavailable")?;
        s.set_write_timeout(Some(Duration::from_secs(5)))
            .map_err(|_| "Socket")?;
        let (mut uid, mut gid) = (0, 0);
        if unsafe { getpeereid(s.as_raw_fd(), &mut uid, &mut gid) } != 0
            || uid != unsafe { geteuid() }
        {
            return Err("PeerDenied".into());
        }
        s.set_read_timeout(Some(Duration::from_secs(70)))
            .map_err(|_| "Socket")?;
        request["token"] = json!(std::env::var("PV_AI_TOKEN").unwrap_or_default());
        writeln!(s, "{request}").map_err(|_| "Socket")?;
        let mut line = String::new();
        BufReader::new(s)
            .read_line(&mut line)
            .map_err(|_| "Socket")?;
        serde_json::from_str(&line).map_err(|_| "InvalidResponse".into())
    }

    fn schema_doc() -> Value {
        serde_json::from_str(TOOLS_SCHEMA_JSON).expect("embedded tools.schema.json must be valid JSON")
    }

    fn instructions() -> String {
        schema_doc()["instructions"]
            .as_str()
            .unwrap_or_default()
            .to_string()
    }

    fn tools() -> Value {
        let items = schema_doc()["tools"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let list: Vec<Value> = items
            .into_iter()
            .map(|entry| {
                let read_only = entry["readOnly"].as_bool().unwrap_or(true);
                json!({
                    "name": entry["name"],
                    "description": entry["description"],
                    "inputSchema": entry["inputSchema"],
                    "annotations": {
                        "readOnlyHint": read_only,
                        "destructiveHint": false,
                        "openWorldHint": false
                    }
                })
            })
            .collect();
        Value::Array(list)
    }

    /// One short line per failure so the AI knows what to do next.
    fn explain(code: &str) -> String {
        let hint = match code {
            "Locked" => "the vault is locked; ask the user to unlock PasswordVault",
            "Disabled" => "AI access is turned off in PasswordVault",
            "RevokedOrUnknownClient" => "this client is not paired; ask the user to pair it again",
            "AppUnavailable" => "PasswordVault is not running",
            "ApprovalDenied" => "the user declined",
            "ApprovalTimeout" => "the user did not answer in time",
            "UnscopedOrMissing" => "no such entry, or its category is not shared",
            "DeniedField" | "MissingField" => {
                "that field is not available; use a name from secretFields"
            }
            "UnclassifiedOrDeniedFile" => "that file is not shared",
            "EntryChanged" => "the entry changed during approval; ask again",
            "Busy" => "too many pending approvals; retry later",
            "TextOnly" => "the file is not UTF-8 text",
            "UnsupportedType" => "type must be account, note, totp, identity, card or device",
            "RateLimited" => "write rate limit reached; wait a minute and retry",
            "MissingTitle" => "title is required",
            "MissingSecret" => "totp needs secret",
            "DevicesNotEnabled" => {
                "devices are not enabled in this vault; ask the user to enable 设备与服务 first"
            }
            "NoteWriteDenied" => {
                "this note category is not authorized for AI auto-save; ask the user to enable it in AI 访问"
            }
            "VersionConflict" => {
                "the note changed since note_read (or expectedVersion was omitted); call note_read again and merge"
            }
            "MissingSummary" => "summary is required to explain the change in version history",
            "SectionNotFound" => {
                "that Markdown heading was not found in the note; call note_read to check headings"
            }
            "MissingSection" => "section heading is required for replace_section",
            "InvalidMode" => "mode must be append, replace_section or replace",
            "EmptyContent" => "content cannot be empty",
            "NoteTooLarge" => "note content exceeds the size limit",
            "AssetTooLarge" => "attachment file exceeds the 100 MB limit",
            "AssetAccessDisabled" => "note asset archiving/reading is disabled in AI 访问",
            "AssetTextDenied" => {
                "AI text reading is disabled for this attachment; ask the user to toggle AI 可读文本 on the file in PasswordVault"
            }
            "UnsupportedFormat" => "could not extract plain text from this file format",
            "MissingFile" => "attachmentId not found on this note",
            _ => "request refused",
        };
        format!("{code}: {hint}")
    }

    pub(super) fn main() {
        let args: Vec<String> = std::env::args().collect();
        if args.get(1).is_some_and(|a| a == "--call") {
            let r = args
                .get(2)
                .and_then(|s| serde_json::from_str(s).ok())
                .ok_or("Expected JSON request".to_string())
                .and_then(rpc);
            match r {
                Ok(v) => println!("{v}"),
                Err(e) => {
                    eprintln!("{e}");
                    std::process::exit(1)
                }
            };
            return;
        }
        for line in io::stdin().lock().lines().map_while(Result::ok) {
            let Ok(r) = serde_json::from_str::<Value>(&line) else {
                println!(
                    "{}",
                    json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}})
                );
                continue;
            };
            if r.get("id").is_none() {
                continue;
            }
            let result = match r["method"].as_str().unwrap_or("") {
                "initialize" => {
                    let asked = r["params"]["protocolVersion"].as_str().unwrap_or("");
                    let version = if matches!(asked, "2025-03-26" | "2025-06-18") {
                        asked
                    } else {
                        "2024-11-05"
                    };
                    Ok(json!({
                        "protocolVersion": version,
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "passwordvault", "version": env!("CARGO_PKG_VERSION")},
                        "instructions": instructions()
                    }))
                }
                "ping" => Ok(json!({})),
                "tools/list" => Ok(json!({"tools": tools()})),
                "tools/call" => {
                    let mut req = r["params"]["arguments"].clone();
                    if !req.is_object() {
                        req = json!({})
                    }
                    req["op"] = r["params"]["name"].clone();
                    let (error, text) = match rpc(req) {
                        Ok(v) if v["ok"] == true => (false, v["result"].to_string()),
                        Ok(v) => (true, explain(v["error"].as_str().unwrap_or(""))),
                        Err(e) => (true, explain(&e)),
                    };
                    Ok(json!({"isError": error, "content": [{"type": "text", "text": text}]}))
                }
                _ => Err(json!({"code": -32601, "message": "Method not found"})),
            };
            let out = match result {
                Ok(v) => json!({"jsonrpc": "2.0", "id": r["id"], "result": v}),
                Err(e) => json!({"jsonrpc": "2.0", "id": r["id"], "error": e}),
            };
            println!("{out}");
        }
    }
}

#[cfg(target_os = "macos")]
fn main() {
    implementation::main();
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("This helper is not available on Windows yet.");
    std::process::exit(2);
}
