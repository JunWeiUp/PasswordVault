#!/usr/bin/env python3
"""Verify every Android release artifact against the expected public certificate."""
import os
from pathlib import Path
import re
import subprocess


def normalized(value):
    return re.sub(r'[^0-9a-f]', '', value.lower())


def main():
    expected = normalized(os.environ.get('ANDROID_CERT_SHA256', ''))
    if len(expected) != 64:
        raise SystemExit('Configure ANDROID_CERT_SHA256 with the expected signing certificate.')
    sdk = Path(os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT', ''))
    candidates = sorted(sdk.glob('build-tools/*/apksigner'), reverse=True)
    if not candidates:
        raise SystemExit('Android SDK apksigner was not found.')
    root = Path(__file__).resolve().parent.parent
    for abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']:
        path = root / f'build/app/outputs/flutter-apk/app-{abi}-release.apk'
        result = subprocess.run([str(candidates[0]), 'verify', '--print-certs', str(path)], capture_output=True, text=True, check=True)
        match = re.search(r'Signer #1 certificate SHA-256 digest: ([0-9a-fA-F:]+)', result.stdout)
        if not match or normalized(match.group(1)) != expected:
            raise SystemExit(f'Unexpected signing certificate: {path.name}')
    bundle = root / 'build/app/outputs/bundle/release/app-release.aab'
    result = subprocess.run(['jarsigner', '-J-Duser.language=en', '-verify', str(bundle)], capture_output=True, text=True, check=True)
    if 'jar verified.' not in result.stdout:
        raise SystemExit('The Android App Bundle signature could not be verified.')
    certificate = subprocess.run(['keytool', '-J-Duser.language=en', '-printcert', '-jarfile', str(bundle)], capture_output=True, text=True, check=True)
    match = re.search(r'SHA256:\s*([0-9A-Fa-f:]+)', certificate.stdout)
    if not match or normalized(match.group(1)) != expected:
        raise SystemExit('Unexpected signing certificate for Android App Bundle.')
    print('All Android release signatures match the configured certificate.')


if __name__ == '__main__':
    main()
