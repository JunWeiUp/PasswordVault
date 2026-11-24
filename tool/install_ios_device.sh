#!/usr/bin/env bash
# Build and install PasswordVault onto a connected physical iPhone using a temporary
# personal-team spec (no AutoFill extension / App Group entitlements). Restores the
# tracked XcodeGen project automatically on exit.
#
#   bash tool/install_ios_device.sh
#   bash tool/install_ios_device.sh --udid 00008140-000203D202BA801C
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

UDID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="${2:?missing UDID}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$UDID" ]]; then
  UDID="$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /available/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')"
fi
if [[ -z "$UDID" ]]; then
  echo "No available physical iPhone found. Connect/unlock your iPhone or pass --udid <UDID>." >&2
  exit 1
fi
echo "==> Target physical iPhone: $UDID"

if [[ ! -d apps/ios/Generated/VaultCore.xcframework/ios-arm64 ]]; then
  echo "==> Building iOS device vault-core slice..."
  bash tool/build_mobile_core.sh ios
fi

TMP_SPEC="apps/ios/project.personal.tmp.yml"
cleanup() {
  rm -f "$TMP_SPEC"
  xcodegen generate --quiet --spec apps/ios/project.yml || true
}
trap cleanup EXIT

python3 - "$TMP_SPEC" <<'PY'
import pathlib, re, sys
src = pathlib.Path("apps/ios/project.yml").read_text()
src = src.split("\n  PasswordVaultAutofill:\n", 1)[0] + "\n"
src = src.replace("      - target: PasswordVaultAutofill\n", "")
src = src.replace("    CODE_SIGN_ENTITLEMENTS: Vault.entitlements\n", '    CODE_SIGN_ENTITLEMENTS: ""\n')
src = re.sub(r"^\s*VAULT_APP_GROUP:.*\n", "", src, flags=re.MULTILINE)
src = re.sub(r"^\s*VaultAppGroup:.*\n", "", src, flags=re.MULTILINE)
pathlib.Path(sys.argv[1]).write_text(src)
PY

xcodegen generate --quiet --spec "$TMP_SPEC"
xcodebuild \
  -project apps/ios/PasswordVault.xcodeproj \
  -scheme PasswordVault \
  -configuration Debug \
  -derivedDataPath /tmp/pv-ios-device-build \
  -destination "id=$UDID" \
  -allowProvisioningUpdates \
  build | tail -n 15

xcrun devicectl device install app \
  --device "$UDID" \
  /tmp/pv-ios-device-build/Build/Products/Debug-iphoneos/PasswordVault.app
echo "✓ Installed PasswordVault onto iPhone $UDID"
