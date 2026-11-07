"""Failure-path coverage for native public release validation."""
import copy
import json
import os
from pathlib import Path
import plistlib
import tempfile
import subprocess
import struct
from unittest import mock
import unittest
import zipfile

from native_release import ROOT, validate_versions, verify_android_metadata, verify_app_archive, package, public_asset_names, verify_windows_archive


def windows_fixture(path, version, machine=0x8664, extra=None):
    exe = bytearray(128)
    exe[:2] = b'MZ'
    struct.pack_into('<I', exe, 60, 64)
    exe[64:68] = b'PE\0\0'
    struct.pack_into('<H', exe, 68, machine)
    with zipfile.ZipFile(path, 'w') as bundle:
        bundle.writestr('PasswordVault/PasswordVault.exe', exe)
        bundle.writestr('PasswordVault/nsh/app.json', json.dumps({'version': version, 'id': 'com.securepass.vault.nshpreview'}))
        for name in ['nsh/bundle.nshc', 'nsh/capabilities.json', 'LICENSE.txt', 'THIRD_PARTY_NOTICES.md']:
            bundle.writestr('PasswordVault/' + name, b'fixture')
        if extra: bundle.writestr(extra, b'fixture')


class NativeReleaseTests(unittest.TestCase):
    def test_macos_build_with_and_without_private_signing_config(self):
        # Execute the real script with inert build tools, including on the
        # system Bash 3.2 used by hosted Mac runners. No real vault or keychain.
        with tempfile.TemporaryDirectory(prefix='pv signing fixture ') as temp:
            root = Path(temp)
            (root / 'tool').mkdir()
            (root / 'tool/check_native.sh').write_bytes((ROOT / 'tool/check_native.sh').read_bytes())
            (root / 'tool/cargo_fork_env.sh').write_bytes((ROOT / 'tool/cargo_fork_env.sh').read_bytes())
            tools = root / 'bin'
            tools.mkdir()
            for name in ['cargo', 'npm', 'lipo', 'xcodegen']:
                path = tools / name
                path.write_text('#!/bin/sh\necho \"huacnlee/cargo fixture\"\nexit 0\n' if name == 'cargo' else '#!/bin/sh\nexit 0\n')
                path.chmod(0o755)
            rustup = tools / 'rustup'
            rustup.write_text('#!/bin/sh\nprintf \'%s/rustc\\n\' "$(dirname "$0")"\n')
            rustup.chmod(0o755)
            builder = tools / 'xcodebuild'
            builder.write_text('#!/bin/sh\nprintf \'%s\\n\' "$@" > "$PV_TEST_ARGUMENTS"\n')
            builder.chmod(0o755)
            capture = root / 'arguments.txt'
            env = {**os.environ, 'PATH': str(tools) + os.pathsep + os.defpath,
                   'PV_CARGO_FORK': str(tools / 'cargo'), 'PV_TEST_ARGUMENTS': str(capture)}
            config = root / 'private/signing/macos/Signing.local.xcconfig'
            for signed in [False, True]:
                if signed:
                    config.parent.mkdir(parents=True)
                    config.write_text('// fictional signing configuration\n')
                subprocess.run(['/bin/bash', 'tool/check_native.sh', 'macos'], cwd=root, env=env,
                               check=True, capture_output=True, text=True)
                args = capture.read_text().splitlines()
                self.assertEqual('-xcconfig' in args, signed)
                if signed:
                    self.assertEqual(args[args.index('-xcconfig') + 1], 'private/signing/macos/Signing.local.xcconfig')
                self.assertEqual(args[-1], 'build')

    def test_coordinated_versions_and_wrong_tag(self):
        data = validate_versions(ROOT)
        validate_versions(ROOT, 'v' + data['version'])
        with self.assertRaises(SystemExit):
            validate_versions(ROOT, 'v99.0.0')

    def test_mismatched_browser_lock_is_rejected(self):
        files = ['native-version.json', 'apps/browser/package.json', 'apps/browser/package-lock.json',
                 'apps/desktop/nsh.json', 'apps/macos-legacy/Info.plist', 'apps/android/app/build.gradle.kts', 'apps/ios/project.yml']
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in files:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((ROOT / name).read_bytes())
            lock_path = root / 'apps/browser/package-lock.json'
            lock = json.loads(lock_path.read_text())
            lock['packages']['']['version'] = '0.0.0'
            lock_path.write_text(json.dumps(lock))
            with self.assertRaises(SystemExit):
                validate_versions(root)

    def test_native_tag_uses_native_manifest_and_checked_commit(self):
        from validate_release_ref import resolve_release
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in ['native-version.json', 'apps/browser/package.json', 'apps/browser/package-lock.json',
                         'apps/desktop/nsh.json', 'apps/macos-legacy/Info.plist', 'apps/android/app/build.gradle.kts', 'apps/ios/project.yml']:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((ROOT / name).read_bytes())
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, text=True, stderr=subprocess.DEVNULL).strip()
            git('init', '-q')
            git('config', 'user.name', 'Release Fixture')
            git('config', 'user.email', 'fixture@example.test')
            git('add', '.')
            git('commit', '-qm', 'fixture')
            tag = 'v' + json.loads((root / 'native-version.json').read_text())['version']
            git('tag', '-a', tag, '-m', 'fixture native tag')
            with mock.patch('validate_release_ref.ROOT', root):
                self.assertEqual(resolve_release(tag, 'HEAD', native=True), git('rev-parse', 'HEAD'))
                data = json.loads((root / 'native-version.json').read_text())
                device_tag = f'{tag}-android.{data["android_version_code"]}'
                with self.assertRaises(SystemExit):
                    resolve_release(device_tag, 'HEAD', android_device=True)  # Missing tag.
                git('tag', '-a', device_tag, '-m', 'fixture device tag')
                self.assertEqual(resolve_release(device_tag, 'HEAD', android_device=True), git('rev-parse', 'HEAD'))
                for wrong_tag in (tag, device_tag + '1', 'v99.0.0-android.1'):
                    with self.assertRaises(SystemExit):
                        resolve_release(wrong_tag, 'HEAD', android_device=True)
                with self.assertRaises(SystemExit):
                    resolve_release(device_tag, 'HEAD', native=True)  # Cannot publish as a coordinated release.
                git('commit', '--allow-empty', '-qm', 'different revision')
                with self.assertRaises(SystemExit):
                    resolve_release(device_tag, 'HEAD', android_device=True)
                with self.assertRaises(SystemExit):
                    resolve_release(tag, 'HEAD', native=True)

    def test_debug_wrong_package_version_or_abi_is_rejected(self):
        data = {'version': '2.2.0', 'android_version_code': 22001}
        good = "package: name='com.securepass.vault.nativepreview' versionCode='22001' versionName='2.2.0'\nnative-code: 'arm64-v8a'\n"
        verify_android_metadata(good, data, 'arm64-v8a')
        for invalid in (good + 'application-debuggable\n', good.replace('.nativepreview', ''),
                        good.replace('22001', '21010'), good.replace('2.2.0', '2.1.8'),
                        good.replace("native-code: 'arm64-v8a'", "native-code: 'arm64-v8a' 'x86_64'")):
            with self.subTest(invalid=invalid), self.assertRaises(SystemExit):
                verify_android_metadata(invalid, data, 'arm64-v8a')

    def test_simulator_archive_requires_version_platform_and_permissions(self):
        good = {'CFBundleShortVersionString': '2.2.0', 'CFBundleExecutable': 'PasswordVault', 'CFBundleSupportedPlatforms': ['iPhoneSimulator']}
        def make(path, metadata, mode):
            with zipfile.ZipFile(path, 'w') as bundle:
                bundle.writestr('PasswordVault.app/Info.plist', plistlib.dumps(metadata))
                executable = zipfile.ZipInfo('PasswordVault.app/PasswordVault')
                executable.external_attr = mode << 16
                bundle.writestr(executable, b'fixture executable')
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'app.zip'
            make(path, good, 0o100755)
            verify_app_archive(path, '2.2.0', simulator=True)
            for changes, mode in [({}, 0o100644), ({'CFBundleSupportedPlatforms': ['iPhoneOS']}, 0o100755), ({'CFBundleShortVersionString': '2.1.1'}, 0o100755)]:
                info = copy.deepcopy(good)
                info.update(changes)
                make(path, info, mode)
                with self.assertRaises(SystemExit):
                    verify_app_archive(path, '2.2.0', simulator=True)

    def test_nsh_archive_rejects_missing_helpers_and_wrong_identity(self):
        info = {'CFBundleShortVersionString': '2.4.0', 'CFBundleExecutable': 'PasswordVault',
                'CFBundleIdentifier': 'com.securepass.vault.nshpreview', 'PVVaultDirectoryName': 'PasswordVaultNative'}
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'app.zip'
            def make(helpers=True, identity='com.securepass.vault.nshpreview'):
                metadata = dict(info, CFBundleIdentifier=identity)
                with zipfile.ZipFile(path, 'w') as bundle:
                    bundle.writestr('PasswordVault.app/Contents/Info.plist', plistlib.dumps(metadata))
                    exe = zipfile.ZipInfo('PasswordVault.app/Contents/MacOS/PasswordVault')
                    exe.external_attr = 0o100755 << 16
                    bundle.writestr(exe, b'fixture')
                    if helpers:
                        for name in ['Contents/MacOS/pv-browser-host', 'Contents/MacOS/pv-mcp', 'Contents/Resources/BrowserIdentity.json']:
                            bundle.writestr('PasswordVault.app/' + name, b'fixture')
            make()
            verify_app_archive(path, '2.4.0', nsh=True)
            make(helpers=False)
            with self.assertRaises(SystemExit): verify_app_archive(path, '2.4.0', nsh=True)
            make(identity='wrong.app')
            with self.assertRaises(SystemExit): verify_app_archive(path, '2.4.0', nsh=True)

    def test_windows_archive_rejects_wrong_version_architecture_and_private_files(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'windows.zip'
            windows_fixture(path, '2.4.1')
            verify_windows_archive(path, '2.4.1')
            for version, machine, extra in [('2.4.0', 0x8664, None), ('2.4.1', 0xaa64, None),
                    ('2.4.1', 0x8664, 'PasswordVault/../private'), ('2.4.1', 0x8664, 'PasswordVault/vault/header.json'),
                    ('2.4.1', 0x8664, 'PasswordVault/credentials.enc')]:
                windows_fixture(path, version, machine, extra)
                with self.assertRaises(SystemExit): verify_windows_archive(path, '2.4.1')

    def test_release_packages_exactly_one_download_per_platform(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in ['native-version.json', 'apps/browser/package.json', 'apps/browser/package-lock.json',
                         'apps/desktop/nsh.json', 'apps/android/app/build.gradle.kts', 'apps/ios/project.yml',
                         'config/signing/android-release-certificate.sha256']:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((ROOT / name).read_bytes())
            data = validate_versions(root)
            tag = 'v' + data['version']
            inputs = root / 'incoming'
            inputs.mkdir()
            (inputs / 'android-arm64-v8a.apk').write_bytes(b'synthetic signed-input fixture')
            for filename, simulator in [('PasswordVault-macos-arm64.zip', False), ('PasswordVault-ios-simulator.zip', True)]:
                info = {'CFBundleShortVersionString': data['version'], 'CFBundleExecutable': 'PasswordVault'}
                info.update({'CFBundleSupportedPlatforms': ['iPhoneSimulator']} if simulator else
                            {'CFBundleIdentifier': 'com.securepass.vault.nshpreview', 'PVVaultDirectoryName': 'PasswordVaultNative'})
                with zipfile.ZipFile(inputs / filename, 'w') as bundle:
                    bundle.writestr('PasswordVault.app/' + ('Info.plist' if simulator else 'Contents/Info.plist'), plistlib.dumps(info))
                    executable = zipfile.ZipInfo('PasswordVault.app/' + ('' if simulator else 'Contents/MacOS/') + 'PasswordVault')
                    executable.external_attr = 0o100755 << 16
                    bundle.writestr(executable, b'synthetic executable')
                    if not simulator:
                        for path in ['Contents/MacOS/pv-browser-host', 'Contents/MacOS/pv-mcp', 'Contents/Resources/BrowserIdentity.json']:
                            bundle.writestr('PasswordVault.app/' + path, b'fixture')
            windows_fixture(inputs / 'PasswordVault-windows-x64.zip', data['version'])
            browser = inputs / 'browser'
            browser.mkdir()
            (browser / 'manifest.json').write_text(json.dumps({'version': data['version']}))
            (browser / 'index.html').write_text('<html>synthetic fixture</html>')
            with mock.patch('native_release.subprocess.check_output', return_value='a' * 40):
                package(root, inputs, tag)
            output = root / 'release_assets'
            downloads = sorted(path.name for path in output.iterdir() if path.suffix in ('.apk', '.zip'))
            self.assertEqual(downloads, sorted(public_asset_names(tag)))
            self.assertEqual(len(downloads), 6)
            self.assertFalse(any('source.zip' in name or 'x86-' in name for name in downloads))
            self.assertTrue((output / 'SHA256SUMS').is_file())


if __name__ == '__main__':
    unittest.main()
