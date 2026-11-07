#!/usr/bin/env bash
# Builds a signed development package of the Native Shell Mac preview with the
# keychain entitlement Touch ID needs. Output: native-test-output/mac-nsh-preview/
# "PasswordVault NSH Preview.app" (ignored by Git). Never installs over
# /Applications/PasswordVault.app.
#
# Signing inputs come from the ignored private/signing/macos/Signing.local.xcconfig
# (DEVELOPMENT_TEAM, CODE_SIGN_IDENTITY). A throwaway Xcode stub with the preview
# bundle ID lets Xcode's automatic signing provide a matching development profile.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/tool/cargo_fork_env.sh"
config="$root/private/signing/macos/Signing.local.xcconfig"
team="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$config" | tr -d ' ')"
bundle_id="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$root/apps/desktop/nsh.json")"
work=/tmp/pv-nsh-sign
rm -rf "$work" && mkdir -p "$work/Stub"

printf 'print("stub")\n' > "$work/Stub/main.swift"
cat > "$work/Stub/Stub.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>keychain-access-groups</key>
<array><string>\$(AppIdentifierPrefix)$bundle_id</string></array></dict></plist>
PLIST
cat > "$work/project.yml" <<YML
name: PVNSHSigningStub
options: { deploymentTarget: { macOS: "14.0" } }
targets:
  PVNSHSigningStub:
    type: application
    platform: macOS
    sources: [Stub]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $bundle_id
        DEVELOPMENT_TEAM: $team
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_ENTITLEMENTS: Stub/Stub.entitlements
        GENERATE_INFOPLIST_FILE: YES
        ENABLE_HARDENED_RUNTIME: YES
YML
(cd "$work" && xcodegen -q && xcodebuild -project PVNSHSigningStub.xcodeproj -scheme PVNSHSigningStub \
  -configuration Debug -derivedDataPath dd -allowProvisioningUpdates build >/dev/null)
stub="$(find "$work/dd" -name PVNSHSigningStub.app -maxdepth 6 | head -1)"
codesign -d --entitlements :- "$stub" 2>/dev/null > "$work/app.entitlements"
# Sign with the exact certificate Xcode chose for this profile (names can be ambiguous).
identity_name="$(codesign -dvv "$stub" 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)$/\1/p' | head -1)"

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
cp "$stub/Contents/embedded.provisionprofile" "$app/Contents/embedded.provisionprofile"

# --- Browser native messaging helper (preview bundle only) ------------------
helper_channel="$(sed -n 's/^channel = "\(.*\)"/\1/p' "$root/apps/desktop/rust-toolchain.toml")"
(cd "$copy/apps/desktop" && cargo +"$helper_channel" build --release --bin pv-browser-host)
cp "$copy/apps/desktop/target/release/pv-browser-host" "$app/Contents/MacOS/pv-browser-host"
cp "$root/apps/macos-legacy/Resources/BrowserIdentity.json" "$app/Contents/Resources/BrowserIdentity.json"
codesign --force --options runtime --timestamp=none --sign "$identity_name" "$app/Contents/MacOS/pv-browser-host"
codesign --verify --strict "$app/Contents/MacOS/pv-browser-host"
# --- End browser helper; outer app signing follows -------------------------

# --- AI MCP stdio / script helper (preview bundle only) ---------------------
# Build separately from the app runtime, then sign before the enclosing bundle.
ai_helper_channel="$(sed -n 's/^channel = "\(.*\)"/\1/p' "$root/apps/desktop/rust-toolchain.toml")"
(cd "$copy/apps/desktop" && cargo +"$ai_helper_channel" build --release --bin pv-mcp --target-dir "$copy/apps/desktop/target")
cp "$copy/apps/desktop/target/release/pv-mcp" "$app/Contents/MacOS/pv-mcp"
codesign --force --options runtime --timestamp=none --sign "$identity_name" "$app/Contents/MacOS/pv-mcp"
codesign --verify --strict "$app/Contents/MacOS/pv-mcp"
# --- End AI helper ---------------------------------------------------------

codesign --force --options runtime --timestamp=none --entitlements "$work/app.entitlements" \
  --sign "$identity_name" "$app"
codesign --verify --strict "$app"
printf 'Signed preview: %s\n' "$app"
