# Browser extension (Chromium, TypeScript) — agent notes

## Where things are
- `src/background.ts` (service worker), `src/popup.tsx` / `src/app.tsx` (UI), content scripts
  (`content.ts`, `login-observer.ts`, `inline-fields.ts`), `src/core.ts` (wasm vault-core).
- The core runs as wasm (`wasm/`, built from `crates/vault-core` with `--features browser`).
  Its dispatcher is `crates/vault-core/src/browser.rs`, separate from the native registry;
  `src/core.ts` serializes UI requests; which ops skip the encrypted snapshot save is decided
  by the core (`isReadOnlyOp`, `READ_ONLY_OPS` in `browser.rs`).

## Checks
- `bash tool/check_native.sh browser` — wasm build, clippy, typecheck, build and tests.
- From the repo root: `python3 tool/check_changed.py`.

## Rules
- Every delivered change bumps the version with `npm --prefix apps/browser run release:local`
  (package + lockfile). Manifest and popup versions come from package metadata only.
- The loaded unpacked extension lives at `native-test-output/dist`; keep that path.
- Matching is by exact hostname; never weaken HTTPS→HTTP or cross-origin frame protections.
