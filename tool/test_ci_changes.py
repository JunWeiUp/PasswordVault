"""Regression coverage for CI routing, including fail-safe and release paths."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from ci_changes import LEGACY, NATIVE, SCOPES, classify, select

BASE, HEAD = 'a' * 40, 'b' * 40


class CIChangesTests(unittest.TestCase):
    def test_documentation_does_not_build_clients(self):
        self.assertEqual(classify(['README.md', 'docs/design/hero.png', 'apps/android/README.md', '']), set())

    def test_native_platform_changes_stay_scoped(self):
        for platform in ['macos', 'browser', 'android', 'ios']:
            self.assertEqual(classify([f'apps/{platform}/src/example.code']), {platform})

    def test_core_and_toolchain_changes_cover_every_native_consumer(self):
        for path in ['crates/vault-core/src/model.rs', 'Cargo.lock', '.cargo/config.toml', 'rust-toolchain.toml']:
            self.assertEqual(classify([path]), NATIVE)

    def test_shared_assets_and_unknown_files_fail_safe(self):
        for path in ['assets/branding/icon.png', 'new-build.config', 'apps/new-platform/main.code']:
            self.assertEqual(classify([path]), set(SCOPES))

    def test_legacy_platform_and_shared_changes(self):
        self.assertEqual(classify(['lib/main.dart']), LEGACY)
        self.assertEqual(classify(['android/app/build.gradle']), {'legacy', 'legacy_android'})
        self.assertEqual(classify(['web/index.html']), {'legacy', 'legacy_web'})
        self.assertEqual(classify(['test/widget_test.dart']), {'legacy'})
        self.assertEqual(classify(['test/extension/content.test.cjs']), set())

    def test_multiple_platform_changes_are_unioned(self):
        self.assertEqual(classify(['apps/android/a.kt', 'apps/browser/a.ts']), {'android', 'browser'})

    def test_build_scripts_and_workflows_cover_their_consumers(self):
        self.assertEqual(classify(['tool/build_mobile_core.sh']), {'android', 'ios'})
        self.assertEqual(classify(['tool/check_native.sh']), NATIVE)
        self.assertEqual(classify(['.github/workflows/native.yml']), NATIVE)
        self.assertEqual(classify(['.github/workflows/ci.yml']), LEGACY)
        self.assertEqual(classify(['tool/ci_changes.py']), set(SCOPES))

    def test_pull_request_uses_merge_base_not_target_branch_only_changes(self):
        diff = mock.Mock(return_value=['apps/browser/package.json'])
        event = {'pull_request': {'base': {'sha': BASE}, 'head': {'sha': HEAD}}}
        self.assertEqual(select('pull_request', event, diff), {'browser'})
        diff.assert_called_once_with(BASE + '...' + HEAD)

    def test_push_uses_exact_before_after_range(self):
        diff = mock.Mock(return_value=['apps/android/deleted.kt', 'docs/moved.md'])
        self.assertEqual(select('push', {'before': BASE, 'after': HEAD, 'ref': 'refs/heads/main'}, diff), {'android'})
        diff.assert_called_once_with(BASE + '..' + HEAD)

    def test_manual_release_and_initial_push_are_complete(self):
        for event_name, event in [
            ('workflow_dispatch', {}), ('workflow_call', {}),
            ('push', {'ref': 'refs/tags/v1.1.0'}),
            ('push', {'before': '0' * 40, 'after': HEAD}),
            ('push', {'before': '--unsafe', 'after': HEAD}),
        ]:
            self.assertEqual(select(event_name, event, mock.Mock()), set(SCOPES))

    def test_unavailable_diff_runs_all_checks(self):
        diff = mock.Mock(side_effect=subprocess.CalledProcessError(128, 'git'))
        self.assertEqual(select('push', {'before': BASE, 'after': HEAD}, diff), set(SCOPES))

    def test_actual_git_rename_delete_and_nul_output(self):
        script = Path(__file__).with_name('ci_changes.py').resolve()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', '-C', directory, *args], text=True).strip()
            git('init', '-q')
            git('config', 'user.email', 'fixture@example.test')
            git('config', 'user.name', 'CI fixture')
            source = root / 'apps/browser/source.ts'
            source.parent.mkdir(parents=True)
            source.write_text('fixture')
            git('add', '.')
            git('commit', '-qm', 'fixture base')
            before = git('rev-parse', 'HEAD')
            target = root / 'apps/android/moved.kt'
            target.parent.mkdir(parents=True)
            source.rename(target)
            git('add', '-A')
            git('commit', '-qm', 'move between components')
            event = root / 'event.json'
            event.write_text(json.dumps({'before': before, 'after': git('rev-parse', 'HEAD'), 'ref': 'refs/heads/main'}))
            output = root / 'outputs'
            subprocess.run(['python3', str(script)], cwd=root, env={**os.environ,
                'GITHUB_EVENT_PATH': str(event), 'GITHUB_EVENT_NAME': 'push', 'GITHUB_OUTPUT': str(output)}, check=True, capture_output=True)
            values = dict(line.split('=') for line in output.read_text().splitlines())
            self.assertEqual({key for key, value in values.items() if value == 'true'}, {'android', 'browser'})
            self.assertEqual(set(values), set(SCOPES))


if __name__ == '__main__':
    unittest.main()
