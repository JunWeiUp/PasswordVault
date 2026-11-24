"""Classify Git diffs for local tooling and select explicit CI build components."""
import os
import sys

SCOPES = ('core', 'macos', 'windows', 'browser', 'android', 'ios')
NATIVE = {'core', 'macos', 'windows', 'browser', 'android', 'ios'}


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
        elif path.startswith(('apps/shared/Relay/', 'apps/shared/RelayTests/', 'apps/shared/Capabilities/')):
            selected |= {'ios'}  # Swift sources compiled only by apps/ios/project.yml.
        elif path.startswith('apps/shared/note-editor/'):
            selected |= {'ios', 'android', 'browser'}  # Desktop uses NSH's own editor.
        elif path.startswith('apps/desktop/'):
            selected |= {'macos', 'windows'}
        elif path.startswith(('tool/macos-nsh/', 'tool/nsh-cargo/')) or path in {'tool/nsh_mac.sh', 'tool/test_background_service.py', 'tool/test_desktop_search.mjs', 'tool/test_ui_polling.mjs'}:
            selected |= {'macos'}
        elif path.startswith('tool/windows-desktop/') or path == 'tool/nsh_windows.ps1':
            selected |= {'windows'}
        elif path in {'tool/test_relay_live.sh', 'tool/core_contract.py', 'tool/new_op.py', 'tool/test_core_contract.py'}:
            selected |= {'core'}
        elif path == 'tool/select_ios_simulator.py':
            selected |= {'ios'}
        elif path == 'apps/browser/identity.json':
            selected |= {'macos', 'browser'}  # The Mac bundle embeds it as BrowserIdentity.json.
        elif path.startswith('apps/'):
            component = path.split('/')[1]
            selected |= {component} if component in NATIVE else set(SCOPES)
        elif path.startswith('assets/'):
            selected |= NATIVE
        else:
            selected |= set(SCOPES)
    return selected


def requested(component):
    allowed = set(SCOPES)
    if component == 'release':
        return {'macos', 'windows', 'ios', 'browser'}  # Android is signed once by the caller.
    if component == 'all':
        return allowed
    if component in allowed:
        return {component}
    raise ValueError(f'Unknown CI component: {component}')


def main():
    if '--requested' not in sys.argv:
        raise SystemExit('Usage: python3 tool/ci_changes.py --requested')
    selected = requested(os.environ['CI_COMPONENT'])
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for scope in SCOPES:
            output.write(f'{scope}={str(scope in selected).lower()}\n')
    print('Requested components: ' + ', '.join(sorted(selected)))


if __name__ == '__main__':
    main()
