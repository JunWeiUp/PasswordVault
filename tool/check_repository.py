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
    match = re.search(r'^version: (\d+\.\d+\.\d+)\+(\d+)\s*$', Path('pubspec.yaml').read_text(), re.M)
    require(match, 'pubspec.yaml must contain a numeric version and build number.')
    return match.group(1)


def validate_tag(tag):
    require(re.fullmatch(r'v\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?', tag), 'Invalid release tag.')
    require(tag[1:].split('-')[0] == version(), 'Release tag does not match pubspec.yaml.')


def main():
    if '--pr-title' in sys.argv:
        title = os.environ.get('PR_TITLE', '')
        require(re.fullmatch(r'(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9_/-]+\))?!?: [A-Za-z].+', title), 'Use an English Conventional Commit PR title.')
        require(not re.search(r'[\u3400-\u9fff]', title), 'PR titles default to English.')
        print('PR title is valid.')
        return

    english = load('lib/l10n/app_en.arb')
    keys = {key for key in english if not key.startswith('@')}
    for path in Path('lib/l10n').glob('app_*.arb'):
        messages = load(path)
        require({key for key in messages if not key.startswith('@')} == keys, f'{path}: localization keys differ.')
        for key in keys:
            require(isinstance(messages[key], str) and messages[key].strip(), f'{path}: empty message {key}')
            require(set(re.findall(r'\{(\w+)(?:\}|,)', english[key])) == set(re.findall(r'\{(\w+)(?:\}|,)', messages[key])), f'{path}: placeholders differ for {key}')

    manifest = load('chrome/manifest.json')
    require(manifest['version'] == version(), 'Chrome and Flutter versions differ.')
    require(manifest.get('default_locale') == 'en', 'Extension fallback locale must be English.')
    require('<all_urls>' not in manifest['permissions'], 'Host patterns belong in host_permissions.')
    base_messages = load('chrome/_locales/en/messages.json')
    for path in Path('chrome/_locales').glob('*/messages.json'):
        messages = load(path)
        require(messages.keys() == base_messages.keys(), f'{path}: extension message keys differ.')
        for key, value in messages.items():
            require(re.findall(r'\$\d+', value['message']) == re.findall(r'\$\d+', base_messages[key]['message']), f'{path}: substitutions differ for {key}')
    for key in re.findall(r'__MSG_(\w+)__', json.dumps(manifest)):
        require(key in base_messages, f'Missing manifest message: {key}')

    tracked = subprocess.check_output(['git', 'ls-files', '-z'], text=True).split('\0')
    forbidden = [path for path in tracked if re.search(r'(?:^|/)(?:key\.properties|\.env(?:\..*)?|Kim_AGENTS\.md)$|\.(?:jks|keystore|p12|pfx|pem|bundle)$', path) and not path.endswith('.example')]
    require(not forbidden, 'Private files are still tracked: ' + ', '.join(forbidden))
    require(Path('LICENSE').exists(), 'Missing license.')
    require('## Run from source' in Path('README.md').read_text(), 'English README must be the default.')

    if '--release' in sys.argv:
        validate_tag(os.environ.get('RELEASE_TAG', ''))
    if '--extension-build' in sys.argv:
        folder = Path('build/chrome_extension')
        for name in ['manifest.json', 'background.js', 'content.js', 'bridge.js', 'index.html', 'flutter_bootstrap.js', 'main.dart.js', 'sqlite3.wasm', 'drift_worker.js', '_locales/en/messages.json', '_locales/zh_CN/messages.json', 'canvaskit/canvaskit.wasm']:
            require((folder / name).is_file(), f'Missing extension asset: {name}')
        require(load(folder / 'manifest.json') == manifest, 'Packaged manifest differs from source.')
        require(not list(folder.rglob('*.map')), 'Do not distribute source maps.')
        require('script-src' in manifest['content_security_policy']['extension_pages'], 'Missing extension CSP.')
    print('Repository checks passed.')


if __name__ == '__main__':
    main()
