"""Unit tests for tool/bump_version.py."""
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from bump_version import apply_bump, compute_metadata
from native_release import validate_versions

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILES = [
    "native-version.json",
    "apps/browser/package.json",
    "apps/browser/package-lock.json",
    "apps/desktop/nsh.json",
    "apps/desktop/Cargo.toml",
    "apps/desktop/Cargo.lock",
    "apps/android/app/build.gradle.kts",
    "apps/ios/project.yml",
]


class BumpVersionTests(unittest.TestCase):
    def test_compute_metadata_increments_builds_and_android_code(self):
        current = {"version": "2.5.8", "android_version_code": 25008, "macos_build": 48, "ios_build": 24}
        self.assertEqual(
            compute_metadata(current, "2.5.11"),
            {"version": "2.5.11", "android_version_code": 25011, "macos_build": 49, "ios_build": 25},
        )
        # Same version still monotonically bumps build numbers / android versionCode
        self.assertEqual(
            compute_metadata(current, "2.5.8"),
            {"version": "2.5.8", "android_version_code": 25009, "macos_build": 49, "ios_build": 25},
        )

    def test_apply_bump_updates_all_manifests_and_passes_release_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            sandbox = Path(tmp)
            for rel in VERSION_FILES:
                dst = sandbox / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / rel, dst)
            meta = apply_bump(sandbox, "2.6.0")
            self.assertEqual(meta["version"], "2.6.0")
            self.assertEqual(validate_versions(sandbox, tag="v2.6.0"), meta)
            self.assertEqual(json.loads((sandbox / "apps/browser/package.json").read_text())["version"], "2.6.0")

    def test_invalid_version_is_rejected(self):
        with self.assertRaises(SystemExit):
            compute_metadata({"version": "2.5.8", "android_version_code": 25008, "macos_build": 48, "ios_build": 24}, "1.0.0")


if __name__ == "__main__":
    unittest.main()
