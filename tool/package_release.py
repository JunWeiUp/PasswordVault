#!/usr/bin/env python3
"""Shared archive/checksum helpers for native releases."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile



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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', type=Path, required=True, metavar='DIRECTORY',
                        help='Verify a downloaded release asset directory.')
    args = parser.parse_args()
    verify_checksums(args.verify)


if __name__ == '__main__':
    main()
