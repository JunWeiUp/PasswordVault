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

npm_ci_if_changed() {
  local dir="$1"
  shift
  local lock="$dir/package-lock.json"
  local stamp="$dir/node_modules/.package-lock.stamp"
  if [[ -z "${CI:-}" && -d "$dir/node_modules" && -f "$stamp" ]] && cmp -s "$lock" "$stamp"; then
    return 0
  fi
  npm --prefix "$dir" ci "$@"
  if [[ -d "$dir/node_modules" && -f "$lock" ]]; then
    cp "$lock" "$stamp"
  fi
}

core() {
  python3 tool/core_contract.py check
  "${cargo_cmd[@]}" fmt --all --check
  if [[ -n "${CI:-}" || "${PV_TEST_PROFILE:-}" == release ]]; then
    "${cargo_cmd[@]}" test -p vault-core --release --locked
  else
    "${cargo_cmd[@]}" test -p vault-core --locked
  fi
  "${cargo_cmd[@]}" clippy -p vault-core --all-targets -- -D warnings
}
macos() {
  # The NSH desktop client (Mac and Windows share apps/desktop; it uses NSH's own editor).
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
  npm_ci_if_changed apps/shared/note-editor --ignore-scripts
  npm --prefix apps/shared/note-editor run build
  npm_ci_if_changed apps/browser
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
