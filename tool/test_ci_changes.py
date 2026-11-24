"""Regression coverage for CI routing, including fail-safe and release paths."""
import re
from pathlib import Path
import unittest

from ci_changes import NATIVE, SCOPES, classify, requested


class CIChangesTests(unittest.TestCase):
    def test_documentation_does_not_build_clients(self):
        self.assertEqual(classify(['README.md', 'docs/design/hero.png', 'apps/android/README.md', '']), set())

    def test_native_platform_changes_stay_scoped(self):
        for platform in ['macos', 'browser', 'android', 'ios']:
            self.assertEqual(classify([f'apps/{platform}/src/example.code']), {platform})

    def test_shared_inputs_cover_every_consumer(self):
        self.assertEqual(classify(['apps/ios/Sources/Models.swift']), {'ios'})
        self.assertEqual(classify(['apps/browser/identity.json']), {'macos', 'browser'})
        self.assertEqual(classify(['assets/branding/AppIcon.appiconset/icon_512_2.png']), {'core', 'macos', 'windows', 'browser', 'android', 'ios'})
        self.assertEqual(classify(['apps/desktop/ui/Detail.tsx']), {'macos', 'windows'})

    def test_core_and_toolchain_changes_cover_every_native_consumer(self):
        for path in ['crates/vault-core/src/model.rs', 'Cargo.lock', '.cargo/config.toml', 'rust-toolchain.toml']:
            self.assertEqual(classify([path]), NATIVE)

    def test_shared_assets_and_unknown_files_fail_safe(self):
        for path in ['assets/branding/icon.png', 'new-build.config', 'apps/new-platform/main.code']:
            self.assertEqual(classify([path]), set(SCOPES))

    def test_editor_bundle_changes_cover_all_embedding_clients(self):
        self.assertEqual(classify(['apps/shared/note-editor/editor.js']), {'ios', 'android', 'browser'})
        self.assertEqual(classify(['apps/ios/Relay/VaultRelay.swift']), {'ios'})
        self.assertEqual(classify(['apps/shared/note-editor/package-lock.json']), {'ios', 'android', 'browser'})

    def test_native_runs_are_requested_and_tests_are_opt_in(self):
        self.assertEqual(requested('release'), {'macos', 'windows', 'ios', 'browser'})
        self.assertEqual(requested('macos'), {'macos'})
        self.assertEqual(requested('all'), set(SCOPES))
        for retired in ('services', 'typo'):
            with self.assertRaises(ValueError):
                requested(retired)
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/native.yml').read_text()
        self.assertNotIn('capability-services', workflow)
        section = re.split(r'(?m)^  [a-z][a-z0-9-]*:', workflow.split('  macos-nsh:', 1)[1])[0]
        self.assertIn('if: inputs.run_tests', section)

    def test_multiple_platform_changes_are_unioned(self):
        self.assertEqual(classify(['apps/android/a.kt', 'apps/browser/a.ts']), {'android', 'browser'})

    def test_build_scripts_and_workflows_cover_their_consumers(self):
        self.assertEqual(classify(['tool/build_mobile_core.sh']), {'android', 'ios'})
        self.assertEqual(classify(['tool/check_native.sh']), NATIVE)
        self.assertEqual(classify(['.github/workflows/native.yml']), NATIVE)
        self.assertEqual(classify(['.github/workflows/ci.yml']), NATIVE)
        self.assertEqual(classify(['tool/ci_changes.py']), set(SCOPES))
        self.assertEqual(classify(['tool/nsh_mac.sh', 'tool/macos-nsh/deploy.sh']), {'macos'})
        self.assertEqual(classify(['tool/windows-desktop/package.ps1']), {'windows'})
        self.assertEqual(classify(['tool/test_relay_live.sh']), {'core'})

    def test_native_workflow_does_not_trigger_on_pull_request(self):
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/native.yml').read_text()
        self.assertNotIn('pull_request:', workflow)


if __name__ == '__main__':
    unittest.main()
