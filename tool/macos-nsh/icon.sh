#!/usr/bin/env bash
# Install the shared macOS icon before signing an NSH application bundle.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
app="${1:?application bundle required}"
work="$(mktemp -d /tmp/pv-icon.XXXXXX)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/AppIcon.iconset" "$app/Contents/Resources"
python3 - "$root/apps/macos-legacy/Resources/Assets.xcassets/AppIcon.appiconset" "$work/AppIcon.iconset" <<'PY'
import json, pathlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:])
for entry in json.loads((source / 'Contents.json').read_text())['images']:
    suffix = '@2x' if entry['scale'] == '2x' else ''
    shutil.copyfile(source / entry['filename'], target / f"icon_{entry['size']}{suffix}.png")
PY
iconutil -c icns "$work/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    info = plistlib.load(f)
info['CFBundleIconFile'] = 'AppIcon.icns'
with open(path, 'wb') as f:
    plistlib.dump(info, f)
PY
