#!/usr/bin/env bash
# Public development artifact: ad-hoc signed, no provisioning/private credentials.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source tool/cargo_fork_env.sh
bash tool/nsh_mac.sh package App.tsx --target macos
channel="$(sed -n 's/^channel = "\(.*\)"/\1/p' apps/macos-nsh/rust-toolchain.toml)"
RUSTUP_TOOLCHAIN="$channel" "$CARGO" build --manifest-path apps/macos-nsh/Cargo.toml --release --bin pv-browser-host --bin pv-mcp --locked
app="$root/apps/macos-nsh/.nsh/out/PasswordVault.app"
bash tool/macos-nsh/icon.sh "$app"
cp apps/macos-nsh/target/release/pv-browser-host apps/macos-nsh/target/release/pv-mcp "$app/Contents/MacOS/"
cp apps/macos-legacy/Resources/BrowserIdentity.json "$app/Contents/Resources/"
/usr/libexec/PlistBuddy -c 'Add :PVVaultDirectoryName string PasswordVaultNative' "$app/Contents/Info.plist"
for helper in pv-browser-host pv-mcp; do
  codesign --force --sign - "$app/Contents/MacOS/$helper"
done
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
lipo "$app/Contents/MacOS/PasswordVault" -verify_arch arm64
mkdir -p native-test-output/release
zip="$root/native-test-output/release/PasswordVault-macos-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
printf 'Packaged %s\n' "$zip"
