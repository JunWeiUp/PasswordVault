#!/usr/bin/env python3
"""Verify every Android release artifact against the expected public certificate."""
import os
from pathlib import Path
import re
import subprocess


def normalized(value):
    return re.sub(r'[^0-9a-f]', '', value.lower())


def verify_apk_certificates(output, expected, name):
    # Build Tools 37 uses "V2 Signer:" / "V3 Signer:" instead of "Signer #1".
    # Require every printed signing certificate to match, across all schemes.
    digests = re.findall(r'^.*? certificate SHA-256 digest: ([0-9a-fA-F:]+)\s*$', output, re.MULTILINE)
    actual = {normalized(value) for value in digests}
    if actual != {expected}:
        observed = ', '.join(sorted(actual)) or 'no certificate digest found'
        raise SystemExit(f'Unexpected signing certificate: {name} ({observed})')


def main():
    root = Path(__file__).resolve().parent.parent
    expected = normalized(os.environ.get('ANDROID_CERT_SHA256', ''))
    published = normalized((root / 'android/release-certificate.sha256').read_text())
    if expected != published:
        raise SystemExit('Configured signing certificate differs from the reviewed public fingerprint.')
    if len(expected) != 64:
        raise SystemExit('Configure ANDROID_CERT_SHA256 with the expected signing certificate.')
    sdk = Path(os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT', ''))
    candidates = sorted(sdk.glob('build-tools/*/apksigner'), reverse=True)
    if not candidates:
        raise SystemExit('Android SDK apksigner was not found.')
    for abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']:
        path = root / f'build/app/outputs/flutter-apk/app-{abi}-release.apk'
        result = subprocess.run([str(candidates[0]), 'verify', '--print-certs', str(path)], capture_output=True, text=True, check=True)
        verify_apk_certificates(result.stdout, expected, path.name)
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
