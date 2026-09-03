#!/usr/bin/env python3
"""Keep the Web SQLite binary aligned with the resolved sqlite3 package."""
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urljoin, urlparse
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent.parent


def expected_asset():
    config_path = ROOT / '.dart_tool/package_config.json'
    config = json.loads(config_path.read_text())
    package = next(item for item in config['packages'] if item['name'] == 'sqlite3')
    uri = urlparse(urljoin(config_path.as_uri(), package['rootUri']))
    if uri.scheme != 'file':
        raise SystemExit('Expected a local resolved sqlite3 package.')
    hashes = (Path(unquote(uri.path)) / 'lib/src/hook/asset_hashes.dart').read_text()
    tag = re.search(r"releaseTag = '(sqlite3-[0-9.]+)'", hashes)
    digest = re.search(r"'sqlite3.wasm': '([0-9a-f]{64})'", hashes)
    if not tag or not digest:
        raise SystemExit('SQLite asset metadata changed; review the upstream package before updating.')
    return tag.group(1), digest.group(1)


def check():
    _, expected = expected_asset()
    path = ROOT / 'web/sqlite3.wasm'
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit('SQLite WASM does not match pubspec.lock. Run python3 tool/update_sqlite_wasm.py, review, and commit the asset.')


def main():
    if '--check' in sys.argv:
        check()
    else:
        tag, expected = expected_asset()
        url = f'https://github.com/simolus3/sqlite3.dart/releases/download/{tag}/sqlite3.wasm'
        with urlopen(url, timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != expected:
            raise SystemExit('SQLite download checksum mismatch; existing asset was not changed.')
        (ROOT / 'web/sqlite3.wasm').write_bytes(data)
    print('SQLite WASM matches the resolved package checksum.')


if __name__ == '__main__':
    main()
