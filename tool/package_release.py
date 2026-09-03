#!/usr/bin/env python3
"""Package expected release assets and produce a deterministic checksum manifest."""
import hashlib
import os
from pathlib import Path
import shutil
import zipfile
from check_repository import ROOT, validate_tag


def archive(source, target):
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive_file:
        for path in sorted(source.rglob('*')):
            if path.is_file() and path.suffix not in {'.map', '.deps', '.dart'}:
                archive_file.write(path, path.relative_to(source))


def main():
    os.chdir(ROOT)
    tag = os.environ.get('RELEASE_TAG', '')
    validate_tag(tag)
    output = ROOT / 'release_assets'
    if output.exists() and any(output.iterdir()):
        raise SystemExit('release_assets must be empty to avoid mixing versions.')
    output.mkdir(exist_ok=True)
    prefix = f'PasswordVault-{tag}'
    for abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']:
        shutil.copyfile(ROOT / f'build/app/outputs/flutter-apk/app-{abi}-release.apk', output / f'{prefix}-android-{abi}.apk')
    shutil.copyfile(ROOT / 'build/app/outputs/bundle/release/app-release.aab', output / f'{prefix}-android.aab')
    for source, name in [('build/web', 'web'), ('build/chrome_extension', 'chrome-extension')]:
        if not (ROOT / source / 'index.html').exists():
            raise SystemExit(f'Missing build: {source}')
        archive(ROOT / source, output / f'{prefix}-{name}.zip')
    shutil.copyfile(ROOT / 'android/release-certificate.sha256', output / 'SIGNING-CERTIFICATE-SHA256.txt')
    lines = []
    for path in sorted(output.iterdir()):
        with path.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        lines.append(f'{digest}  {path.name}\n')
    (output / 'SHA256SUMS').write_text(''.join(lines))
    print(f'Packaged {len(lines)} assets with SHA-256 checksums.')


if __name__ == '__main__':
    main()
