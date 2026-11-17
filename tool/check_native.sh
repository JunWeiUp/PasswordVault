#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Use the pinned rustup toolchain, not a Homebrew Rust built for the host-only SDK.
rustup_cmd="$(command -v rustup || true)"
if [[ -z "$rustup_cmd" && -x "$HOME/.cargo/bin/rustup" ]]; then rustup_cmd="$HOME/.cargo/bin/rustup"; fi
if [[ -z "$rustup_cmd" ]]; then printf 'Install rustup from https://rustup.rs first.\n' >&2; exit 1; fi
toolchain_bin="$(dirname "$("$rustup_cmd" which --toolchain 1.98.0 rustc)")"
export RUSTUP_TOOLCHAIN=1.98.0
source tool/cargo_fork_env.sh
cargo_cmd=("$CARGO")
export MACOSX_DEPLOYMENT_TARGET=13.0

core() {
  "${cargo_cmd[@]}" fmt --all --check
  "${cargo_cmd[@]}" test -p vault-core --release --locked
  "${cargo_cmd[@]}" clippy -p vault-core --all-targets -- -D warnings
}
macos() {
  # The NSH desktop client (Mac and Windows share apps/desktop).
  npm --prefix apps/shared/note-editor ci --ignore-scripts
  npm --prefix apps/shared/note-editor run build
  bash tool/nsh_mac.sh check
}
browser() {
  "${cargo_cmd[@]}" build -p vault-core --release --locked --no-default-features --features browser --target wasm32-unknown-unknown
  if [[ "${PV_BUILD_ONLY:-false}" != true ]]; then "${cargo_cmd[@]}" clippy -p vault-core --no-default-features --features browser --target wasm32-unknown-unknown --lib -- -D warnings; fi
  bindgen_cmd="$(command -v wasm-bindgen || true)"
  if [[ -z "$bindgen_cmd" ]]; then bindgen_cmd="$HOME/.cargo/bin/wasm-bindgen"; fi
  "$bindgen_cmd" --target web --out-dir apps/browser/wasm target/wasm32-unknown-unknown/release/vault_core.wasm
  if [[ "${PV_BUILD_ONLY:-false}" != true ]]; then
  "$bindgen_cmd" --target nodejs --out-dir apps/browser/wasm-test target/wasm32-unknown-unknown/release/vault_core.wasm
  mv apps/browser/wasm-test/vault_core.js apps/browser/wasm-test/vault_core.cjs
  fi
  npm --prefix apps/shared/note-editor ci --ignore-scripts
  npm --prefix apps/shared/note-editor run build
  npm --prefix apps/browser ci
  npm --prefix apps/browser run check
  npm --prefix apps/browser run build
  if [[ "${PV_BUILD_ONLY:-false}" != true ]]; then npm --prefix apps/browser test; fi
}
case "${1:-core}" in
  core) core ;;
  macos) macos ;;
  browser) browser ;;
  all) core; macos; browser ;;
  *) printf 'Usage: bash tool/check_native.sh [core|macos|browser|all]\n' >&2; exit 2 ;;
esac
