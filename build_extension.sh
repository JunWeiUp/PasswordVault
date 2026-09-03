#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

printf 'Building PasswordVault Web and Chromium extension…\n'
flutter pub get --enforce-lockfile
flutter gen-l10n
python3 tool/update_sqlite_wasm.py --check
# Keep the Drift worker compatible with the version in pubspec.lock.
dart compile js -O4 web/drift_worker.dart -o web/drift_worker.js
flutter build web --release --no-pub --no-tree-shake-icons --no-wasm-dry-run --no-web-resources-cdn

extension_dir="build/chrome_extension"
rm -rf "$extension_dir"
mkdir -p "$extension_dir"
cp -R build/web/. "$extension_dir/"
cp chrome/manifest.json chrome/background.js chrome/content.js chrome/bridge.js chrome/popup.css "$extension_dir/"
cp chrome/popup.html "$extension_dir/index.html"
cp -R chrome/icons chrome/_locales "$extension_dir/"
# Debugging sources and development workers do not belong in distributed bundles.
python3 - <<'PY'
from pathlib import Path
for root in (Path('build/web'), Path('build/chrome_extension')):
    for p in root.rglob('*'):
        if p.is_file() and (p.suffix in {'.map', '.deps', '.dart'}):
            p.unlink()
PY
python3 tool/check_repository.py --extension-build
printf 'Extension ready: %s\n' "$extension_dir"
