#!/usr/bin/env bash
# Builds a signed development package of the Native Shell Mac preview with the
# keychain entitlement Touch ID needs. Output: native-test-output/mac-nsh-preview/
# "PasswordVault NSH Preview.app" (ignored by Git). Never installs over
# /Applications/PasswordVault.app.
#
# Signing artifacts are cached under private/signing/macos/.cache/ via
# signing-cache.sh; pass PV_REFRESH_SIGNING=1 to force refreshing the profile.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/tool/cargo_fork_env.sh"
source "$root/tool/macos-nsh/signing-cache.sh"
ensure_signing_cache

# Package from a /tmp copy (apps are not built or launched from the Documents checkout).
copy=/tmp/pv-nsh-gui
source "$root/tool/macos-nsh/stage.sh"
stage_nsh_sources
(cd "$copy" && bash tool/nsh_mac.sh package App.tsx --target macos)

out="$root/native-test-output/mac-nsh-preview"
app="$out/PasswordVault NSH Preview.app"
mkdir -p "$out" && rm -rf "$app"
cp -R "$copy/apps/desktop/.nsh/out/PasswordVault.app" "$app"
bash "$root/tool/macos-nsh/icon.sh" "$app"
/usr/libexec/PlistBuddy -c "Set :CFBundleName PasswordVault NSH Preview" "$app/Contents/Info.plist"
cp "$PV_SIGN_PROFILE" "$app/Contents/embedded.provisionprofile"

helper_channel="$(sed -n 's/^channel = "\(.*\)"/\1/p' "$root/apps/desktop/rust-toolchain.toml")"

# --- Lightweight standalone helpers (pv-browser-host + pv-mcp) --------------
# Built as separate workspace members so they never compile the full UI library.
(cd "$copy/apps/desktop" && RUSTUP_TOOLCHAIN="$helper_channel" "$CARGO" build --release -p pv-browser-host -p pv-mcp --locked)
cp "$copy/apps/desktop/target/release/pv-browser-host" "$app/Contents/MacOS/pv-browser-host"
cp "$copy/apps/desktop/target/release/pv-mcp" "$app/Contents/MacOS/pv-mcp"
cp "$root/apps/browser/identity.json" "$app/Contents/Resources/BrowserIdentity.json"
for helper in pv-browser-host pv-mcp; do
  codesign --force --options runtime --timestamp=none --sign "$PV_SIGN_IDENTITY" "$app/Contents/MacOS/$helper"
  codesign --verify --strict "$app/Contents/MacOS/$helper"
done

# --- Headless vault owner (pv-background) -----------------------------------
(cd "$copy/apps/desktop" && RUSTUP_TOOLCHAIN="$helper_channel" "$CARGO" build --release --no-default-features --features background-service --bin pv-background --locked)
bash "$root/tool/macos-nsh/embed-service.sh" "$app" "$copy/apps/desktop/target/release/pv-background" "$PV_SIGN_IDENTITY"

codesign --force --options runtime --timestamp=none --entitlements "$PV_SIGN_ENTITLEMENTS" \
  --sign "$PV_SIGN_IDENTITY" "$app"
codesign --verify --strict "$app"
printf 'Signed preview: %s\n' "$app"
