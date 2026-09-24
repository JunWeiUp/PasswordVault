#!/usr/bin/env python3
"""Validate and package the native release; never read private signing material."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile

from package_release import archive, digest, verify_checksums
from verify_android_signatures import normalized, verify_apk_certificates

ROOT = Path(__file__).resolve().parent.parent


def validate_versions(root, tag=None):
    data = json.loads((root / 'native-version.json').read_text())
    version = data['version']
    if not re.fullmatch(r'[2-9]\d*\.\d+\.\d+', version):
        raise SystemExit('Expected a native release version, major 2 or later.')
    if tag is not None and tag != f'v{version}':
        raise SystemExit('Native release tag does not match native-version.json.')
    package = json.loads((root / 'apps/browser/package.json').read_text())
    lock = json.loads((root / 'apps/browser/package-lock.json').read_text())
    if any(value != version for value in (package['version'], lock['version'], lock['packages']['']['version'])):
        raise SystemExit('Browser package and lockfile must match the native release.')
    mac = plistlib.loads((root / 'apps/macos/Info.plist').read_bytes())
    if (mac['CFBundleShortVersionString'], mac['CFBundleVersion']) != (version, str(data['macos_build'])):
        raise SystemExit('Mac version/build differs from the native release.')
    android = (root / 'apps/android/app/build.gradle.kts').read_text()
    if f'versionName = "{version}"' not in android or f'versionCode = {data["android_version_code"]}\n' not in android:
        raise SystemExit('Android version/build differs from the native release.')
    ios = (root / 'apps/ios/project.yml').read_text()
    if re.findall(r'CFBundleShortVersionString: "([^"]+)"', ios) != [version, version] or re.findall(r'CFBundleVersion: "([^"]+)"', ios) != [str(data['ios_build'])] * 2:
        raise SystemExit('iOS app and extension versions must match the native release.')
    return data


def verify_android(root, directory):
    expected = normalized(os.environ.get('ANDROID_CERT_SHA256', ''))
    published = normalized((root / 'android/release-certificate.sha256').read_text())
    if len(expected) != 64 or expected != published:
        raise SystemExit('Release signing identity differs from the reviewed certificate.')
    sdk = Path(os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT', ''))
    signer = sdk / 'build-tools/36.0.0/apksigner'
    aapt = sdk / 'build-tools/36.0.0/aapt2'
    data = validate_versions(root)
    for abi in ('arm64-v8a', 'x86_64'):
        apk = directory / f'android-{abi}.apk'
        result = subprocess.check_output([str(signer), 'verify', '--print-certs', str(apk)], text=True)
        verify_apk_certificates(result, expected, apk.name)
        badging = subprocess.check_output([str(aapt), 'dump', 'badging', str(apk)], text=True)
        verify_android_metadata(badging, data, abi)
        with zipfile.ZipFile(apk) as bundle:
            if f'lib/{abi}/libvault_core.so' not in bundle.namelist():
                raise SystemExit('Native vault core missing from APK.')
    print('Both native APKs have the reviewed release signature and non-debuggable isolated package.')


def verify_android_metadata(badging, data, abi):
    expected = (f"name='com.securepass.vault.nativepreview'", f"versionCode='{data['android_version_code']}'", f"versionName='{data['version']}'")
    package_line = next((line for line in badging.splitlines() if line.startswith('package: ')), '')
    if not all(value in package_line for value in expected) or 'application-debuggable' in badging:
        raise SystemExit('APK package/version/debuggable validation failed.')
    if next((line.strip() for line in badging.splitlines() if line.startswith("native-code:")), "") != f"native-code: '{abi}'":
        raise SystemExit('APK contains unexpected native architectures.')


def verify_app_archive(path, version, simulator=False):
    with zipfile.ZipFile(path) as bundle:
        prefix = 'PasswordVault.app/'
        info = plistlib.loads(bundle.read(prefix + ('Info.plist' if simulator else 'Contents/Info.plist')))
        if info.get('CFBundleShortVersionString') != version:
            raise SystemExit('Apple archive version differs from release.')
        executable = prefix + ('' if simulator else 'Contents/MacOS/') + info['CFBundleExecutable']
        if not (bundle.getinfo(executable).external_attr >> 16) & 0o111:
            raise SystemExit('Apple archive lost executable permissions.')
        if simulator and info.get('CFBundleSupportedPlatforms') != ['iPhoneSimulator']:
            raise SystemExit('Expected an iOS Simulator application, not a device IPA.')
        if not simulator and prefix + 'Contents/MacOS/PasswordVaultBridge' not in bundle.namelist():
            raise SystemExit('Mac browser bridge is missing.')


def package(root, inputs, tag):
    data = validate_versions(root, tag)
    output = root / 'release_assets'
    if output.exists():
        raise SystemExit('Refusing to mix release assets with an existing directory.')
    prefix = f'PasswordVault-{tag}'
    sources = {
        f'{prefix}-android-arm64-v8a.apk': inputs / 'android-arm64-v8a.apk',
        f'{prefix}-android-x86_64.apk': inputs / 'android-x86_64.apk',
        f'{prefix}-macos-universal-development.zip': inputs / 'PasswordVault-macos-universal.zip',
        f'{prefix}-ios-simulator.zip': inputs / 'PasswordVault-ios-simulator.zip',
        'INSTALL.md': root / 'docs/NATIVE-RELEASE-NOTES.md',
        'LICENSE': root / 'LICENSE',
        'THIRD_PARTY_NOTICES.md': root / 'THIRD_PARTY_NOTICES.md',
        'SIGNING-CERTIFICATE-SHA256.txt': root / 'android/release-certificate.sha256',
    }
    for path in sources.values():
        if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
            raise SystemExit(f'Missing release input: {path.name}')
    verify_app_archive(inputs / 'PasswordVault-macos-universal.zip', data['version'])
    verify_app_archive(inputs / 'PasswordVault-ios-simulator.zip', data['version'], simulator=True)
    browser = inputs / 'browser'
    manifest = json.loads((browser / 'manifest.json').read_text())
    if manifest['version'] != data['version'] or not (browser / 'index.html').is_file():
        raise SystemExit('Browser release version or entry point is invalid.')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    with tempfile.TemporaryDirectory(prefix='.native-release-', dir=root) as directory:
        staging = Path(directory) / 'assets'
        staging.mkdir()
        for name, source in sources.items():
            shutil.copyfile(source, staging / name)
        archive(browser, staging / f'{prefix}-chromium-extension.zip')
        archive(browser, staging / f'{prefix}-web.zip')
        # Only committed files enter the source archive, never ignored vaults/keys/builds.
        subprocess.run(['git', 'archive', '--format=zip', f'--prefix=PasswordVault-{tag}/', '-o', str(staging / f'{prefix}-source.zip'), 'HEAD'], cwd=root, check=True)
        metadata = dict(data, product='PasswordVault', status='developer-preview', tag=tag, commit=commit,
                        android_package='com.securepass.vault.nativepreview', macos_distribution='ad-hoc-signed, not notarized',
                        ios_distribution='simulator only; not installable on iPhone',
                        android_certificate_sha256=(root / 'android/release-certificate.sha256').read_text().strip())
        if os.environ.get('GITHUB_RUN_ID'):
            metadata['workflow_run'] = f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
        (staging / 'BUILD.json').write_text(json.dumps(metadata, indent=2) + '\n')
        (staging / 'SHA256SUMS').write_text(''.join(f'{digest(path)}  {path.name}\n' for path in sorted(staging.iterdir())))
        verify_checksums(staging)
        staging.replace(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['versions', 'android', 'package', 'verify'])
    parser.add_argument('--inputs', type=Path, default=ROOT / 'release-input')
    args = parser.parse_args()
    tag = os.environ.get('RELEASE_TAG')
    if args.action == 'versions':
        print(json.dumps(validate_versions(ROOT, tag)))
    elif args.action == 'android':
        verify_android(ROOT, args.inputs)
    elif args.action == 'verify':
        verify_checksums(args.inputs)
    else:
        if not tag:
            raise SystemExit('RELEASE_TAG is required.')
        package(ROOT, args.inputs, tag)


if __name__ == '__main__':
    main()
