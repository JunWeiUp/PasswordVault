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
    os.umask(0o077)
    path.write_bytes(data)
    props = {'storeFile': str(path.resolve()), 'storePassword': os.environ['ANDROID_STORE_PASSWORD'], 'keyAlias': os.environ['ANDROID_KEY_ALIAS'], 'keyPassword': os.environ['ANDROID_KEY_PASSWORD']}
    target = Path(__file__).resolve().parent.parent / 'android/key.properties'
    if target.exists():
        raise SystemExit('Refusing to overwrite existing signing configuration.')
    target.write_text(''.join(f'{key}={escape_property(value)}\n' for key, value in props.items()), encoding='utf-8')
    print('Ephemeral signing configuration created.')


if __name__ == '__main__':
    main()
