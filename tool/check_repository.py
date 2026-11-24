#!/usr/bin/env python3
"""Fast, dependency-free source/package checks used locally and in CI."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def load(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def version():
    value = load('native-version.json')['version']
    require(re.fullmatch(r'[2-9]\d*\.\d+\.\d+', value), 'Invalid native version.')
    return value


def validate_tag(tag):
    require(re.fullmatch(r'v\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?', tag), 'Invalid release tag.')
    require(tag[1:].split('-')[0] == version(), 'Release tag does not match native-version.json.')


def main():
    package = load('apps/browser/package.json')
    lock = load('apps/browser/package-lock.json')
    require(package['version'] == lock['version'] == lock['packages']['']['version'],
            'Browser package and lockfile versions differ.')
    version()
    for path in ['crates/vault-core/Cargo.toml', 'apps/ios/project.yml', 'apps/android/settings.gradle.kts']:
        require(Path(path).is_file(), f'Missing native source input: {path}')

    tracked = subprocess.check_output(['git', 'ls-files', '-z'], text=True).split('\0')
    forbidden = [path for path in tracked if re.search(r'(?:^|/)(?:key\.properties|\.env(?:\..*)?|Kim_AGENTS\.md)$|\.(?:jks|keystore|p12|pfx|pem|bundle)$', path) and not path.endswith('.example')]
    require(not forbidden, 'Private files are still tracked: ' + ', '.join(forbidden))
    require(Path('LICENSE').exists(), 'Missing license.')
    require('## Run from source' in Path('README.md').read_text(), 'English README must be the default.')

    if '--release' in sys.argv:
        validate_tag(os.environ.get('RELEASE_TAG', ''))
    print('Repository checks passed.')


if __name__ == '__main__':
    main()
