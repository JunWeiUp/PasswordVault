"""Regression checks for release input validation and artifact handling."""
import os
from pathlib import Path
import tempfile
import unittest
import zipfile

from check_repository import validate_tag
from configure_signing import escape_property
from package_release import archive


class ReleaseToolsTest(unittest.TestCase):
    def test_tag_matches_the_current_base_version(self):
        validate_tag('v1.1.0-preview.1')
        for tag in ['v0.9.0', 'v1.1.0;echo bad', '../v1.1.0', '1.1.0', 'v1.1.0\n']:
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


if __name__ == '__main__':
    unittest.main()
