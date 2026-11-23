# vault-core — agent notes

Shared Rust core for every client: crypto, SQLCipher storage, notes/attachments, history,
sync (mesh, peer, relay), backup/import and the common-relay protocol. Rust 1.98.0 (pinned).

## Where things are
- `contract/commands.json` — the JSON command API registry. Every `op` must be registered;
  unregistered ops are rejected (`src/native/contract.rs`). Results use a TS-like notation.
- `src/native.rs` — `VaultSession` / `DiskVault`, UniFFI exports and `DiskVault::command`,
  which runs the shared checks (registry, lock, format guards) and routes by the op's registry
  `group`: simple groups live in `src/native/ops/<group>.rs`; stateful ones next to their state
  (`native/relay*.rs`, `history.rs`, `passkeys.rs`, `recovery.rs`, `devices.rs`, `capabilities.rs`).
- `src/relay_protocol/` — relay protocol: signing chain, strict payloads, invitation links,
  envelopes, libsodium-compatible `secretstream`, the group state machine (`groups`) and the
  owner retry/exit `policy`. Mobile reaches the pure parts through `relay-protocol-*` ops.
- `src/relay_net/` (native) — the only relay transport for every client: HTTPS (`http`), WSS
  `connection` with the delivery `journal`, encrypted `files`, and the UniFFI surface (`ffi`:
  `RelayConnection`, `RelayFileClient`, `relay_groups`). There is no vendored relay SDK any more.
- `src/browser.rs` — the wasm dispatcher used by the browser extension. It is NOT gated by the
  registry; keep its op names consistent with `commands.json`.
- `tests/` — integration tests; `tests/fixtures/` holds legacy-format fixtures (never delete).

## Adding or changing a command
1. `python3 tool/new_op.py <op> --group <g> --lock unlocked|none --param 'name?:type' --result '{ok:true}'`
   (registers it and regenerates TS/Kotlin/Swift builders; prints the handler file to edit).
2. Write the handler arm and a test (success + failure path). Locked behaviour is checked
   automatically by `unlocked_ops_refuse_while_locked`.
3. `python3 tool/core_contract.py matrix --group <g>` shows which clients use the group.

## Checks
- `bash tool/check_native.sh core` — contract check, fmt, release tests, clippy `-D warnings`.
- Single test: `cargo test -p vault-core --release <filter>`.
- Relay end to end against real Common Relay servers (v2 + v1, loopback):
  `bash tool/test_relay_live.sh` (needs Go and a local common-relay source tree).
- Changing UniFFI exports or ops used by mobile: `bash tool/build_mobile_core.sh android|ios`
  (generated bindings are ignored by Git) — `python3 tool/check_changed.py` does this for you.

## Rules
- Keep legacy readers and `tests/fixtures/` (migration compatibility); format changes need a
  migration test and an encrypted snapshot path.
- `AttachmentMeta` is AAD-bound (`deny_unknown_fields`): never add fields to it.
- Callers of `save_document_row*` must install the returned document (`commit_persisted`).
- Wire exports (`sync-*`, `export`, `relay-mesh-export`) must hydrate split notes first.
- Tests use temporary synthetic vaults only; never a real vault.
