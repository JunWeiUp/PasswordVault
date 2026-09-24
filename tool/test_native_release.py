"""Failure-path coverage for native public release validation."""
import copy
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

from native_release import ROOT, validate_versions, verify_android_metadata, verify_app_archive


class NativeReleaseTests(unittest.TestCase):
    def test_coordinated_versions_and_wrong_tag(self):
        data = validate_versions(ROOT)
        validate_versions(ROOT, 'v' + data['version'])
        with self.assertRaises(SystemExit):
            validate_versions(ROOT, 'v99.0.0')

    def test_mismatched_browser_lock_is_rejected(self):
        files = ['native-version.json', 'apps/browser/package.json', 'apps/browser/package-lock.json',
                 'apps/macos/Info.plist', 'apps/android/app/build.gradle.kts', 'apps/ios/project.yml']
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


if __name__ == '__main__':
    unittest.main()
