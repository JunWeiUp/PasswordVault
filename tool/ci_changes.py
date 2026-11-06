"""Select CI components from Git diffs; unknown inputs conservatively run all checks."""
import json
import os
from pathlib import Path
import re
import subprocess

SCOPES = ('core', 'macos', 'browser', 'android', 'ios')
NATIVE = {'core', 'macos', 'browser', 'android', 'ios'}


def classify(paths):
    selected = set()
    for path in paths:
        if not path:
            continue
        if path.startswith('docs/') or path.endswith('.md') or path in {
            'LICENSE', '.gitignore', '.gitleaks.toml', '.gitattributes',
        }:
            continue
        if path.startswith(('crates/', '.cargo/')) or path in {'Cargo.toml', 'Cargo.lock', 'rust-toolchain.toml'}:
            selected |= NATIVE
        elif path in {'.github/workflows/native.yml', '.github/workflows/native-release.yml', 'tool/check_native.sh', 'native-version.json', 'tool/native_release.py', 'tool/test_native_release.py'}:
            selected |= NATIVE
        elif path == 'tool/build_mobile_core.sh':
            selected |= {'android', 'ios'}
        elif path.startswith('apps/shared/note-editor/'):
            selected |= {'macos', 'ios', 'android', 'browser'}
        elif path.startswith('services/'):
            continue  # Native workflow always runs the dedicated Node service job.
        elif path.startswith('apps/macos-nsh/'):
            selected |= {'macos'}
        elif path.startswith('apps/macos-legacy/'):
            if path.startswith('apps/macos-legacy/Resources/'):
                selected |= {'macos', 'browser'}
            elif path in {'apps/macos-legacy/Sources/Models.swift', 'apps/macos-legacy/Sources/WebDAVListing.swift', 'apps/macos-legacy/Tests/WebDAVListingTests.swift'}:
                selected |= {'ios'}
        elif path.startswith('apps/'):
            component = path.split('/')[1]
            selected |= {component} if component in NATIVE else set(SCOPES)
        elif path.startswith('assets/'):
            selected |= NATIVE
        else:
            selected |= set(SCOPES)
    return selected


def select(event_name, event, git_diff):
    if event_name == 'pull_request':
        base = event['pull_request']['base']['sha']
        head = event['pull_request']['head']['sha']
        comparison = '...'
    elif event_name == 'push' and not event.get('ref', '').startswith('refs/tags/'):
        base, head = event.get('before', ''), event.get('after', '')
        comparison = '..'
    else:
        return set(SCOPES)  # Manual runs and release workflow_call are always complete.
    if not all(re.fullmatch(r'[0-9a-f]{40}', sha) and set(sha) != {'0'} for sha in (base, head)):
        return set(SCOPES)
    try:
        paths = git_diff(base + comparison + head)
    except subprocess.CalledProcessError:
        return set(SCOPES)
    return classify(paths)


def main():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    selected = select(os.environ['GITHUB_EVENT_NAME'], event, lambda revision: subprocess.check_output(
        ['git', 'diff', '--name-only', '--no-renames', '-z', revision, '--'], text=True).split('\0'))
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for scope in SCOPES:
            output.write(f'{scope}={str(scope in selected).lower()}\n')
    print('Selected components: ' + (', '.join(sorted(selected)) or 'repository checks only'))


if __name__ == '__main__':
    main()
