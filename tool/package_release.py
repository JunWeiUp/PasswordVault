#!/usr/bin/env python3
"""Package reviewed release assets and verify the complete checksum inventory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile

from check_repository import ROOT, validate_tag


def archive(source, target):
    """Use stable ZIP metadata; exclude development-only sources."""
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive_file:
        for path in sorted(source.rglob('*')):
            if path.is_file() and path.suffix not in {'.map', '.deps', '.dart'}:
                if path.is_symlink():
                    raise SystemExit(f'Release archives must not contain symlinks: {path.name}')
                info = zipfile.ZipInfo(path.relative_to(source).as_posix())
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                archive_file.writestr(info, path.read_bytes())


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify_checksums(folder):
    """Reject tampering, missing files, extra files, and unsafe manifest paths."""
    manifest = folder / 'SHA256SUMS'
    if not manifest.is_file() or manifest.is_symlink():
        raise SystemExit('Missing checksum manifest.')
    expected = {}
    for line in manifest.read_text(encoding='utf-8').splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)', line)
        if not match or match[2] in expected or match[2] == 'SHA256SUMS':
            raise SystemExit('Invalid checksum manifest entry.')
        expected[match[2]] = match[1]
    actual = {path.name for path in folder.iterdir() if path.name != 'SHA256SUMS'}
    if not expected or actual != set(expected):
        raise SystemExit('Release asset inventory differs from SHA256SUMS.')
    for name, expected_digest in expected.items():
        path = folder / name
        if path.is_symlink() or not path.is_file() or digest(path) != expected_digest:
            raise SystemExit(f'Release checksum failed: {name}')
    print(f'Verified {len(expected)} release assets.')


def package(root, tag):
    """Stage atomically so a failed package cannot leave a partial release."""
    output = root / 'release_assets'
    if output.is_symlink() or (output.exists() and (not output.is_dir() or any(output.iterdir()))):
        raise SystemExit('release_assets must be empty to avoid mixing versions.')
    prefix = f'PasswordVault-{tag}'
    files = {
        f'{prefix}-android-{abi}.apk': root / f'build/app/outputs/flutter-apk/app-{abi}-release.apk'
        for abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']
    }
    files.update({
        f'{prefix}-android.aab': root / 'build/app/outputs/bundle/release/app-release.aab',
        'SIGNING-CERTIFICATE-SHA256.txt': root / 'android/release-certificate.sha256',
        'LICENSE': root / 'LICENSE',
        'THIRD_PARTY_NOTICES.md': root / 'THIRD_PARTY_NOTICES.md',
        'INSTALL.md': root / 'docs/RELEASE_NOTES.md',
    })
    builds = {'web': root / 'build/web', 'chrome-extension': root / 'build/chrome_extension'}
    for path in [*files.values(), *(folder / 'index.html' for folder in builds.values())]:
        if not path.is_file() or path.is_symlink() or not path.stat().st_size:
            raise SystemExit(f'Missing or invalid release input: {path.relative_to(root)}')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    metadata = {
        'product': 'PasswordVault',
        'status': 'developer-preview',
        'tag': tag,
        'commit': commit,
        'flutter': (root / '.flutter-version').read_text().strip(),
        'android_certificate_sha256': (root / 'android/release-certificate.sha256').read_text().strip(),
        'platforms': ['Android', 'Web', 'Chromium extension'],
    }
    if os.environ.get('GITHUB_RUN_ID') and os.environ.get('GITHUB_REPOSITORY'):
        metadata['workflow_run'] = (
            f'{os.environ.get("GITHUB_SERVER_URL", "https://github.com")}/'
            f'{os.environ["GITHUB_REPOSITORY"]}/actions/runs/{os.environ["GITHUB_RUN_ID"]}'
        )
    with tempfile.TemporaryDirectory(prefix='.release-stage-', dir=root) as directory:
        staging = Path(directory) / 'assets'
        staging.mkdir()
        for name, path in files.items():
            shutil.copyfile(path, staging / name)
        for name, folder in builds.items():
            archive(folder, staging / f'{prefix}-{name}.zip')
        (staging / 'BUILD.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
        (staging / 'SHA256SUMS').write_text(''.join(
            f'{digest(path)}  {path.name}\n' for path in sorted(staging.iterdir())
        ), encoding='utf-8')
        verify_checksums(staging)
        if output.exists():
            output.rmdir()  # Only an empty, pre-existing output directory is permitted.
        staging.replace(output)
    print(f'Packaged developer preview {tag} at {commit}.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', type=Path, metavar='DIRECTORY', help='Verify a downloaded release asset directory.')
    args = parser.parse_args()
    if args.verify is not None:
        verify_checksums(args.verify)
        return
    os.chdir(ROOT)
    tag = os.environ.get('RELEASE_TAG', '')
    validate_tag(tag)
    package(ROOT, tag)


if __name__ == '__main__':
    main()
