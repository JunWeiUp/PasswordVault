#!/usr/bin/env bash
# Installs the signed Native Shell build as the daily PasswordVault, keeping the
# SwiftUI app as "PasswordVault (SwiftUI).app" for rollback.
#   bash tool/macos-nsh/install.sh <backup dir under private/archive>
# Before running: quit both apps and back up ~/Library/Application Support/PasswordVaultNative.
# Rollback: quit, delete /Applications/PasswordVault.app, rename the SwiftUI app back,
# and restore the browser manifests from <backup>/browser-manifests.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
backup="${1:?backup directory required}"
[[ -d "$root/$backup/PasswordVaultNative/vault" ]] || { echo "missing vault backup in $backup" >&2; exit 1; }
if pgrep -f "/Applications/PasswordVault.*\.app/Contents/MacOS/" >/dev/null; then
  echo "quit PasswordVault first" >&2; exit 1
fi
built="$root/native-test-output/mac-nsh-preview/PasswordVault NSH Preview.app"
stage="$(mktemp -d /tmp/pv-daily.XXXXXX)/PasswordVault.app"
cp -R "$built" "$stage"
plist="$stage/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :PVVaultDirectoryName" "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :PVVaultDirectoryName string PasswordVaultNative" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName PasswordVault" "$plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string PasswordVault" "$plist"
# Re-sign the outer bundle (helpers keep their signatures) with the same identity
# and keychain entitlements the package step used.
identity="$(codesign -dvv "$built" 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)$/\1/p' | head -1)"
codesign -d --entitlements :- "$built" 2>/dev/null > "$stage.entitlements"
codesign --force --options runtime --timestamp=none --entitlements "$stage.entitlements" --sign "$identity" "$stage"
codesign --verify --deep --strict "$stage"

if [[ -d /Applications/PasswordVault.app ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/PasswordVault.app/Contents/Info.plist)" == "com.securepass.vault.macos" ]]; then
  [[ -e "/Applications/PasswordVault (SwiftUI).app" ]] && { echo "SwiftUI copy already exists; refusing to overwrite" >&2; exit 1; }
  mv /Applications/PasswordVault.app "/Applications/PasswordVault (SwiftUI).app"
fi
rm -rf /Applications/PasswordVault.app
cp -R "$stage" /Applications/PasswordVault.app
codesign --verify --deep --strict /Applications/PasswordVault.app

host=/Applications/PasswordVault.app/Contents/MacOS/pv-browser-host
for b in "Google/Chrome" "Microsoft Edge" "Microsoft Edge Beta" "ego lite"; do
  f="$HOME/Library/Application Support/$b/NativeMessagingHosts/com.securepass.vault.native_v2.json"
  [[ -f "$f" ]] || continue
  python3 - "$f" "$host" <<'PY'
import json, sys
path, host = sys.argv[1], sys.argv[2]
data = json.load(open(path))
data["path"] = host
open(path, "w").write(json.dumps(data, indent=2) + "\n")
PY
  echo "browser manifest updated: $b"
done
echo "installed daily PasswordVault (vault: PasswordVaultNative)"
