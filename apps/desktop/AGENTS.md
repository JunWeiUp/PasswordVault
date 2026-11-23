# Desktop (Mac + Windows, NSH) — agent notes

NSH app: TypeScript/TSX UI in `ui/` over a thin Rust layer in `src/` that embeds vault-core.
Put UI, view-models, formatting and validation in TypeScript; keep Rust for crypto, files,
OS services and IPC policy.

## Where things are
- `ui/store.ts` — app state and `call()`: typed vault-core requests (`CoreRequest`) whose
  result type comes from `crates/vault-core/contract/commands.json` unless you pass `call<T>()`.
- `ui/api/core.ts` — `coreApi` facade; `ui/api/coreContract.generated.ts` is generated
  (`python3 tool/core_contract.py generate`), never edit it by hand.
- `ui/api/nativeBridge.ts` — typed wrappers for Rust modules (attachments, relay, markdown).
- `src/relay/` — desktop relay runtime: sync loop and credentials over vault-core's relay (SDK connection, journal, files, groups).
- `src/ai/`, `helpers/pv-mcp`, `helpers/pv-browser-host` — MCP and browser-host helpers.
- `tests/*.test.tsx` — NSH UI tests with harnesses in `ui/**/TestHarness.tsx`.

## Where new logic goes
- Used by more than one client (desktop + a phone, or the browser) → `crates/vault-core`, exposed
  as a registered command (`tool/new_op.py`). Relay protocol, group state machine and retry/exit
  policy already live there (`vault_core::relay_protocol`).
- Desktop-only behaviour → TypeScript in `ui/` first; Rust in `src/` only for OS services, file
  streaming, crypto/storage access or IPC policy. Existing desktop-only Rust (`markdown.rs`,
  `text_extract.rs`, `backup.rs`, ...) stays here until a second client
  needs it — move it into the core then, with its tests, instead of porting it.

## Checks
- `bash tool/nsh_mac.sh check` — typecheck + Rust check.
- `bash tool/nsh_mac.sh test-fast <suite|path|--rust filter>` — one suite on a cached `/tmp`
  synthetic vault (~7 s); `test-smoke` runs everything except the slow memory test.
- Or from the repo root: `python3 tool/check_changed.py`.

## Rules
- Do NOT run `cargo fmt` in `apps/desktop`: the crate is not rustfmt-clean and ~50 files would
  be rewritten. Format only what you touch (TS/TSX: `prettier --write <file>` with the local
  `.prettierrc.json`).
- Tests: wait for positive conditions with `app.waitUntil(...)`/`waitFor`, not fixed
  `app.wait(ms)` (debounced saves make sleeps flaky). Fixed waits are fine before asserting
  that something did NOT appear.
- Never test against a real vault or launch test apps from a Documents-based working copy; use
  `tool/macos-nsh/gui.sh` for real-window checks (it stages a `/tmp` copy).
- `rust-toolchain.toml` must stay identical to the repository root one.
- Deploys: `tool/macos-nsh/deploy.sh` (`--ui-only` for TS-only changes).
