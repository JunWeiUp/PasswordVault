//! Registry gate for the JSON command API.
//!
//! `contract/commands.json` is the single source of truth for every `op` accepted by
//! `Vault::command`. Client bindings are generated or checked from the same file by
//! `tool/core_contract.py`, so an op that is not registered here is rejected before any
//! dispatch instead of silently drifting between Rust, TypeScript, Kotlin and Swift.
use serde_json::Value;
use std::{collections::HashSet, sync::OnceLock};

pub(crate) const SOURCE: &str = include_str!("../../contract/commands.json");

/// Registered op names. A malformed registry yields an empty set, which fails closed.
fn registry() -> &'static HashSet<String> {
    static REGISTRY: OnceLock<HashSet<String>> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        serde_json::from_str::<Value>(SOURCE)
            .ok()
            .and_then(|v| {
                v["commands"]
                    .as_object()
                    .map(|m| m.keys().cloned().collect())
            })
            .unwrap_or_default()
    })
}

pub(crate) fn is_registered(op: &str) -> bool {
    registry().contains(op)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::native::DiskVault;
    use crate::VaultError;
    use serde_json::json;

    /// Ops whose placeholder params fail format validation (recovery-key syntax, relay role
    /// combination) before the lock check is reached.
    const INPUT_CHECKED_FIRST: [&str; 2] = ["recovery-export", "relay-init"];
    const TYPES: [&str; 6] = ["string", "number", "bool", "object", "array", "any"];

    fn spec() -> Value {
        serde_json::from_str(SOURCE).expect("commands.json parses")
    }

    #[test]
    fn registry_is_well_formed() {
        let spec = spec();
        let commands = spec["commands"].as_object().expect("commands object");
        assert!(commands.len() > 100);
        assert_eq!(registry().len(), commands.len());
        for (op, entry) in commands {
            assert!(
                !op.is_empty()
                    && op
                        .chars()
                        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'),
                "{op}: op names are kebab-case"
            );
            assert!(
                entry["group"].as_str().is_some_and(|g| !g.is_empty()),
                "{op}: group"
            );
            assert!(
                matches!(entry["lock"].as_str(), Some("none" | "unlocked")),
                "{op}: lock"
            );
            assert!(entry["result"].as_str().is_some(), "{op}: result");
            for (name, ty) in entry["params"].as_object().expect("params object") {
                assert!(name != "op" && !name.is_empty(), "{op}: param name");
                assert!(
                    TYPES.contains(&ty.as_str().unwrap_or_default()),
                    "{op}.{name}: type {ty}"
                );
            }
        }
    }

    #[test]
    fn unregistered_ops_are_rejected_before_dispatch() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = DiskVault::new(&dir.path().join("vault")).unwrap();
        assert!(matches!(
            vault.command(&json!({"op":"definitely-not-an-op"})),
            Err(VaultError::Unsupported)
        ));
        assert!(matches!(
            vault.command(&json!({})),
            Err(VaultError::InvalidData)
        ));
        assert!(vault.command(&json!({"op":"status"})).is_ok());
    }

    /// The `lock` column is a contract: every op that needs an unlocked vault must refuse
    /// with `Locked` (never touch the store) while the vault is locked.
    #[test]
    fn unlocked_ops_refuse_while_locked() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = DiskVault::new(&dir.path().join("vault")).unwrap();
        vault
            .command(&json!({"op":"create","password":"fixture-password"}))
            .unwrap();
        vault.command(&json!({"op":"lock"})).unwrap();
        let spec = spec();
        let mut wrong = Vec::new();
        for (op, entry) in spec["commands"].as_object().unwrap() {
            if entry["lock"] != "unlocked" {
                continue;
            }
            // Fill required params with placeholders so validation cannot mask the lock check.
            let mut request = json!({"op": op});
            for (name, ty) in entry["params"].as_object().unwrap() {
                if name.ends_with('?') {
                    continue;
                }
                request[name] = match ty.as_str().unwrap() {
                    "string" => json!("x"),
                    "number" => json!(0),
                    "bool" => json!(true),
                    "array" => json!([]),
                    _ => json!({}),
                };
            }
            match vault.command(&request) {
                Err(VaultError::Locked) => {}
                // Pure input-format checks that run before the lock check and never touch the store.
                Err(VaultError::InvalidData) if INPUT_CHECKED_FIRST.contains(&op.as_str()) => {}
                other => wrong.push(format!("{op}: {other:?}")),
            }
        }
        assert!(wrong.is_empty(), "ops not refusing with Locked: {wrong:#?}");
    }
}
