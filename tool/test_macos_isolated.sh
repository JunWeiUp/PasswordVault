#!/usr/bin/env bash
# Run XCTest from a copied /tmp tree, with a distinct QA identity. Never launch
# a test host from Documents or grant it access to the installed vault.
set -euo pipefail
cd "$(dirname "$0")/.."
test_root=$(mktemp -d /tmp/passwordvault-tests.XXXXXX)
python3 - "$test_root" <<'PY'
from pathlib import Path
import plistlib, shutil, sys
root = Path.cwd()
out = Path(sys.argv[1])
paths = [
    'apps/macos/Sources', 'apps/macos/Tests', 'apps/macos/Bridge',
    'apps/macos/Generated', 'apps/macos/Resources', 'apps/macos/project.yml',
    'apps/macos/Info.plist', 'apps/macos/Keychain.entitlements',
    'apps/shared/Relay', 'apps/shared/RelayTests',
    'vendor/common-relay/swift', 'vendor/common-relay/protocol',
    'target/universal/libvault_core.a',
]
for name in paths:
    src, dst = root / name, out / name
    if not src.exists():
        raise SystemExit(f'Missing build prerequisite: {name}; run bash tool/check_native.sh macos first.')
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        shutil.copytree(src, dst, ignore=shutil.ignore_patterns('.build', '.swiftpm', 'build'))
    else:
        shutil.copy2(src, dst)
project = out / 'apps/macos/project.yml'
project.write_text(project.read_text().replace('com.securepass.vault.macos', 'com.securepass.vault.qa'))
info = out / 'apps/macos/Info.plist'
p = plistlib.loads(info.read_bytes())
p['CFBundleDisplayName'] = p['CFBundleName'] = 'PasswordVault QA'
info.write_bytes(plistlib.dumps(p))
PY
cd "$test_root"
printf 'Isolated test snapshot: %s\n' "$test_root"
xcodegen generate --spec apps/macos/project.yml
xcodebuild -project apps/macos/PasswordVault.xcodeproj -scheme PasswordVault \
  -configuration Debug -derivedDataPath "$test_root/build" \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 "$@" test
