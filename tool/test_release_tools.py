"""Regression checks for release input validation and artifact handling."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile
from unittest import mock

from check_repository import validate_tag, version
from configure_signing import escape_property, write_signing_files
from package_release import archive, package, verify_checksums
from verify_android_signatures import verify_apk_certificates
from validate_release_ref import resolve_release


class ReleaseToolsTest(unittest.TestCase):
    def test_apk_certificate_output_across_build_tools_versions(self):
        expected = 'ab' * 32
        for label in ['Signer #1', 'V2 Signer:', 'V3 Signer:']:
            verify_apk_certificates(f'{label} certificate SHA-256 digest: {expected}\n', expected, 'test.apk')
        verify_apk_certificates(
            f'V2 Signer: certificate SHA-256 digest: {expected}\n'
            f'V3 Signer: certificate SHA-256 digest: {expected}\n', expected, 'test.apk')

    def test_apk_certificate_check_rejects_missing_or_additional_identity(self):
        expected = 'ab' * 32
        for output in ['', f'Signer #1 public key SHA-256 digest: {expected}\n',
                       'V2 Signer: certificate SHA-256 digest: ab\n',
                       f'Signer #1 certificate SHA-256 digest: {expected}\n'
                       f'Signer #2 certificate SHA-256 digest: {"cd" * 32}\n']:
            with self.assertRaises(SystemExit):
                verify_apk_certificates(output, expected, 'test.apk')

    def test_tag_matches_the_current_base_version(self):
        validate_tag(f'v{version()}-preview.1')
        for tag in ['v0.0.0', 'v1.1.0;echo bad', '../v1.1.0', '1.1.0', 'v1.1.0\n']:
            with self.assertRaises(SystemExit):
                validate_tag(tag)

    def test_signing_properties_preserve_special_characters(self):
        self.assertEqual(escape_property('a b:c=d\\e\nf'), r'a\ b\:c\=d\\e\nf')
        self.assertEqual(escape_property('密码🔒'), r'\u5bc6\u7801\ud83d\udd12')
        self.assertEqual(escape_property('!#'), r'\!\#')

    def test_archives_keep_runtime_files_but_exclude_debug_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            source.mkdir()
            for name in ['index.html', 'app.js', 'app.js.map', 'worker.dart', 'worker.js.deps', 'NOTICES.Z']:
                (source / name).write_text('synthetic fixture')
            archive(source, root / 'release.zip')
            with zipfile.ZipFile(root / 'release.zip') as result:
                self.assertEqual(set(result.namelist()), {'index.html', 'app.js', 'NOTICES.Z'})


    def test_signing_setup_preserves_existing_material(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key = root / 'key.jks'
            props = root / 'key.properties'
            for existing in [key, props]:
                existing.write_bytes(b'existing private fixture')
                with self.assertRaises(SystemExit):
                    write_signing_files(key, props, b'new fixture', 'storeFile=fixture')
                self.assertEqual(existing.read_bytes(), b'existing private fixture')
                self.assertFalse((props if existing == key else key).exists())
                existing.unlink()
            write_signing_files(key, props, b'new fixture', 'storeFile=fixture')
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            self.assertEqual(props.stat().st_mode & 0o777, 0o600)

    def test_signing_setup_cleans_up_after_partial_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key = root / 'key.jks'
            with self.assertRaises(SystemExit):
                write_signing_files(key, root / 'absent' / 'key.properties', b'fixture', 'fixture')
            self.assertFalse(key.exists())

    def test_archives_are_stable_across_input_timestamps(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            source.mkdir()
            file = source / 'index.html'
            file.write_text('synthetic fixture')
            archive(source, root / 'first.zip')
            os.utime(file, (1700000000, 1700000000))
            archive(source, root / 'second.zip')
            self.assertEqual((root / 'first.zip').read_bytes(), (root / 'second.zip').read_bytes())

    def test_checksums_reject_tampering_and_unsafe_inventories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = b'synthetic fixture'
            checksum = hashlib.sha256(payload).hexdigest()
            asset = root / 'preview.zip'
            manifest = root / 'SHA256SUMS'
            valid = f'{checksum}  preview.zip\n'
            asset.write_bytes(payload)
            manifest.write_text(valid)
            verify_checksums(root)
            for content in [f'{checksum}  ../preview.zip\n', valid + valid, '', f'{checksum}  SHA256SUMS\n']:
                manifest.write_text(content)
                with self.assertRaises(SystemExit):
                    verify_checksums(root)
            manifest.write_text(valid)
            asset.write_bytes(b'changed')
            with self.assertRaises(SystemExit):
                verify_checksums(root)
            asset.write_bytes(payload)
            (root / 'unexpected.zip').write_bytes(payload)
            with self.assertRaises(SystemExit):
                verify_checksums(root)
            (root / 'unexpected.zip').unlink()
            asset.unlink()
            with self.assertRaises(SystemExit):
                verify_checksums(root)


class ReleaseRevisionTest(unittest.TestCase):
    def test_release_requires_existing_tag_at_checked_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            git = ['git', '-C', str(root)]
            commit = [*git, '-c', 'user.name=Release Test', '-c', 'user.email=test@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'fixture']
            subprocess.run(commit, check=True)
            tag = f'v{version()}-preview.1'
            subprocess.run([*git, 'tag', tag], check=True)
            with mock.patch('validate_release_ref.ROOT', root):
                expected = subprocess.check_output([*git, 'rev-parse', 'HEAD'], text=True).strip()
                self.assertEqual(resolve_release(tag, 'HEAD'), expected)
                with self.assertRaises(SystemExit):
                    resolve_release(f'v{version()}-preview.missing', 'HEAD')
                subprocess.run(commit, check=True)
                with self.assertRaises(SystemExit):
                    resolve_release(tag, 'HEAD')


class ReleasePackagingTest(unittest.TestCase):
    def test_complete_package_and_failed_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=Release Test', '-c', 'user.email=test@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'fixture'], check=True)
            files = ['.flutter-version', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
                     'docs/RELEASE_NOTES.md', 'android/release-certificate.sha256',
                     'build/app/outputs/bundle/release/app-release.aab',
                     'build/web/index.html', 'build/chrome_extension/index.html']
            files += [f'build/app/outputs/flutter-apk/app-{abi}-release.apk' for abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']]
            for name in files:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('synthetic fixture')
            missing = root / files[-1]
            missing.unlink()
            with self.assertRaises(SystemExit):
                package(root, f'v{version()}-preview.1')
            self.assertFalse((root / 'release_assets').exists())
            missing.write_text('synthetic fixture')
            package(root, f'v{version()}-preview.1')
            output = root / 'release_assets'
            verify_checksums(output)
            metadata = json.loads((output / 'BUILD.json').read_text())
            self.assertEqual(metadata['tag'], f'v{version()}-preview.1')
            self.assertEqual(metadata['status'], 'developer-preview')
            self.assertEqual(len(metadata['commit']), 40)
            self.assertEqual(len(list(output.iterdir())), 12)
            original = (output / 'SHA256SUMS').read_bytes()
            with self.assertRaises(SystemExit):
                package(root, f'v{version()}-preview.2')
            self.assertEqual((output / 'SHA256SUMS').read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
