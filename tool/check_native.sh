#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Use the pinned rustup toolchain, not a Homebrew Rust built for the host-only SDK.
rustup_cmd="$(command -v rustup || true)"
if [[ -z "$rustup_cmd" && -x "$HOME/.cargo/bin/rustup" ]]; then rustup_cmd="$HOME/.cargo/bin/rustup"; fi
if [[ -z "$rustup_cmd" ]]; then printf 'Install rustup from https://rustup.rs first.\n' >&2; exit 1; fi
toolchain_bin="$(dirname "$("$rustup_cmd" which --toolchain 1.96.0 rustc)")"
export PATH="$toolchain_bin:$PATH"
cargo_cmd=("$toolchain_bin/cargo")
export MACOSX_DEPLOYMENT_TARGET=13.0

core() {
  "${cargo_cmd[@]}" fmt --all --check
  "${cargo_cmd[@]}" test -p vault-core --release --locked
  "${cargo_cmd[@]}" clippy -p vault-core --all-targets -- -D warnings
}
macos() {
  npm --prefix apps/macos/NoteEditor ci --ignore-scripts
  npm --prefix apps/macos/NoteEditor run build
  "${cargo_cmd[@]}" build -p vault-core --release --locked
  "${cargo_cmd[@]}" run -p vault-core --features bindgen --bin uniffi-bindgen -- generate \
    --library target/release/libvault_core.dylib --language swift \
    --out-dir apps/macos/Generated --config crates/vault-core/uniffi.toml
  for native_target in aarch64-apple-darwin x86_64-apple-darwin; do
    "${cargo_cmd[@]}" build -p vault-core --release --locked --target "$native_target"
  done
  mkdir -p target/universal
  lipo -create target/aarch64-apple-darwin/release/libvault_core.a target/x86_64-apple-darwin/release/libvault_core.a -output target/universal/libvault_core.a
  xcodegen generate --spec apps/macos/project.yml
  xcodebuild -project apps/macos/PasswordVault.xcodeproj -scheme PasswordVault \
    -configuration Release -derivedDataPath "${PASSWORDVAULT_DERIVED_DATA:-apps/macos/build}" \
    -destination 'platform=macOS,arch=arm64' build
}
browser() {
  "${cargo_cmd[@]}" build -p vault-core --release --locked --no-default-features --features browser --target wasm32-unknown-unknown
  "${cargo_cmd[@]}" clippy -p vault-core --no-default-features --features browser --target wasm32-unknown-unknown --lib -- -D warnings
  bindgen_cmd="$(command -v wasm-bindgen || true)"
  if [[ -z "$bindgen_cmd" ]]; then bindgen_cmd="$HOME/.cargo/bin/wasm-bindgen"; fi
  "$bindgen_cmd" --target web --out-dir apps/browser/wasm target/wasm32-unknown-unknown/release/vault_core.wasm
  "$bindgen_cmd" --target nodejs --out-dir apps/browser/wasm-test target/wasm32-unknown-unknown/release/vault_core.wasm
  mv apps/browser/wasm-test/vault_core.js apps/browser/wasm-test/vault_core.cjs
  npm --prefix apps/browser ci
  npm --prefix apps/browser run check
  npm --prefix apps/browser run build
  npm --prefix apps/browser test
}
case "${1:-core}" in
  core) core ;;
  macos) macos ;;
  browser) browser ;;
  all) core; macos; browser ;;
  *) printf 'Usage: bash tool/check_native.sh [core|macos|browser|all]\n' >&2; exit 2 ;;
esac
