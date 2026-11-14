#!/usr/bin/env bash
# Embed a headless service with its own application identity, signed inside-out.
set -euo pipefail
app="${1:?app bundle required}"
binary="${2:?pv-background binary required}"
identity="${3:--}"
service="$app/Contents/Library/PasswordVault Background.app"
mkdir -p "$service/Contents/MacOS"
cp "$binary" "$service/Contents/MacOS/pv-background"
python3 - "$app/Contents/Info.plist" "$service/Contents/Info.plist" <<'PY'
import plistlib,sys
from pathlib import Path
main=plistlib.loads(Path(sys.argv[1]).read_bytes())
info={"CFBundleIdentifier":main["CFBundleIdentifier"]+".background","CFBundleName":"PasswordVault Background","CFBundleExecutable":"pv-background","CFBundlePackageType":"APPL","CFBundleShortVersionString":main["CFBundleShortVersionString"],"CFBundleVersion":main["CFBundleVersion"],"LSBackgroundOnly":True,"LSUIElement":True}
Path(sys.argv[2]).write_bytes(plistlib.dumps(info))
PY
codesign --force --options runtime --timestamp=none --sign "$identity" "$service"
codesign --verify --strict "$service"
