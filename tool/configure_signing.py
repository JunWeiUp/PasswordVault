#!/usr/bin/env python3
"""Write ephemeral CI signing configuration without logging secret values."""
import base64
import os
from pathlib import Path


def escape_property(value):
    escaped = (value.replace('\\', '\\\\').replace('\n', '\\n').replace('\r', '\\r')
            .replace('\t', '\\t').replace(' ', '\\ ').replace('=', '\\=').replace(':', '\\:')
            .replace('#', '\\#').replace('!', '\\!'))
    # java.util.Properties reads Latin-1; escape Unicode as UTF-16 code units.
    return ''.join(chr(unit) if unit < 128 else f'\\u{unit:04x}'
                   for unit in [int.from_bytes(escaped.encode('utf-16-be')[i:i + 2], 'big')
                                for i in range(0, len(escaped.encode('utf-16-be')), 2)])


def write_signing_files(path, target, data, props):
    # Exclusive creation preserves existing local credentials, including symlinks.
    if path.exists() or path.is_symlink() or target.exists() or target.is_symlink():
        raise SystemExit('Refusing to overwrite existing signing material or configuration.')
    created = []
    try:
        for filename, content in [(path, data), (target, props.encode('utf-8'))]:
            descriptor = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            created.append(filename)
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(content)
    except OSError:
        for filename in created:
            filename.unlink(missing_ok=True)
        raise SystemExit('Unable to create ephemeral signing files; newly created files were removed.') from None


def main():
    names = ['ANDROID_KEYSTORE_BASE64', 'ANDROID_STORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD', 'RUNNER_TEMP']
    if any(not os.environ.get(key) for key in names):
        raise SystemExit('Release signing is not configured. See docs/RELEASING.md.')
    path = Path(os.environ['RUNNER_TEMP']) / 'passwordvault-release.jks'
    try:
        data = base64.b64decode(''.join(os.environ['ANDROID_KEYSTORE_BASE64'].split()), validate=True)
    except ValueError:
        raise SystemExit('Invalid keystore encoding.') from None
    if not data:
        raise SystemExit('Empty keystore.')
    props = {'storeFile': str(path.resolve()), 'storePassword': os.environ['ANDROID_STORE_PASSWORD'], 'keyAlias': os.environ['ANDROID_KEY_ALIAS'], 'keyPassword': os.environ['ANDROID_KEY_PASSWORD']}
    target = Path(__file__).resolve().parent.parent / 'android/key.properties'
    write_signing_files(path, target, data, ''.join(f'{key}={escape_property(value)}\n' for key, value in props.items()))
    print('Ephemeral signing configuration created.')


if __name__ == '__main__':
    main()
