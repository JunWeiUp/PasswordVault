#!/usr/bin/env bash
# Caches the Xcode-generated development provisioning profile, entitlements, and
# signing identity under ignored private/signing/macos/.cache/ so repeated builds
# avoid running xcodegen + xcodebuild on every package/deploy.
#
# Usage (sourced by package.sh and deploy.sh; caller sets `root`):
#   source "$root/tool/macos-nsh/signing-cache.sh"
#   ensure_signing_cache
#
# Exports:
#   PV_SIGN_IDENTITY     - exact Apple Development signing identity string
#   PV_SIGN_ENTITLEMENTS - path to cached app.entitlements
#   PV_SIGN_PROFILE      - path to cached embedded.provisionprofile

ensure_signing_cache() {
  local config="$root/private/signing/macos/Signing.local.xcconfig"
  if [[ ! -f "$config" ]]; then
    echo "missing signing config: $config" >&2
    return 1
  fi
  local team bundle_id cache_dir key_file prof ent ident key
  team="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$config" | tr -d ' ')"
  bundle_id="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$root/apps/desktop/nsh.json")"
  cache_dir="$root/private/signing/macos/.cache"
  mkdir -p "$cache_dir"
  chmod 700 "$cache_dir"
  key_file="$cache_dir/cache.key"
  prof="$cache_dir/embedded.provisionprofile"
  ent="$cache_dir/app.entitlements"
  ident="$cache_dir/identity.txt"
  key="$(printf '%s\n%s\n' "$bundle_id" "$(shasum -a 256 "$config" | awk '{print $1}')" | shasum -a 256 | awk '{print $1}')"

  local hit=0
  if [[ "${PV_REFRESH_SIGNING:-0}" != "1" ]] \
    && [[ -f "$key_file" && -s "$prof" && -s "$ent" && -s "$ident" ]] \
    && [[ "$(cat "$key_file")" == "$key" ]]; then
    if python3 - "$prof" <<'PY'
import datetime, plistlib, subprocess, sys
raw = subprocess.check_output(["security", "cms", "-D", "-i", sys.argv[1]], stderr=subprocess.DEVNULL)
pl = plistlib.loads(raw)
exp = pl.get("ExpirationDate")
if not isinstance(exp, datetime.datetime):
    sys.exit(1)
if exp.tzinfo is None:
    exp = exp.replace(tzinfo=datetime.timezone.utc)
now = datetime.datetime.now(datetime.timezone.utc)
sys.exit(0 if (exp - now) > datetime.timedelta(days=7) else 1)
PY
    then
      hit=1
    fi
  fi

  if [[ "$hit" -eq 0 ]]; then
    local work="/tmp/pv-nsh-sign-$$"
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
    local stub
    stub="$(find "$work/dd" -name PVNSHSigningStub.app -maxdepth 6 | head -1)"
    codesign -d --entitlements :- "$stub" 2>/dev/null > "$ent"
    codesign -dvv "$stub" 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)$/\1/p' | head -1 > "$ident"
    cp "$stub/Contents/embedded.provisionprofile" "$prof"
    printf '%s\n' "$key" > "$key_file"
    rm -rf "$work"
  fi

  PV_SIGN_IDENTITY="$(cat "$ident")"
  PV_SIGN_ENTITLEMENTS="$ent"
  PV_SIGN_PROFILE="$prof"
  export PV_SIGN_IDENTITY PV_SIGN_ENTITLEMENTS PV_SIGN_PROFILE
}
