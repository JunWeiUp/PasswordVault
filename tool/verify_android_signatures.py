#!/usr/bin/env python3
"""Verify every Android release artifact against the expected public certificate."""
import re


def normalized(value):
    return re.sub(r'[^0-9a-f]', '', value.lower())


def verify_apk_certificates(output, expected, name):
    # Build Tools 37 uses "V2 Signer:" / "V3 Signer:" instead of "Signer #1".
    # Require every printed signing certificate to match, across all schemes.
    digests = re.findall(r'^.*? certificate SHA-256 digest: ([0-9a-fA-F:]+)\s*$', output, re.MULTILINE)
    actual = {normalized(value) for value in digests}
    if actual != {expected}:
        observed = ', '.join(sorted(actual)) or 'no certificate digest found'
        raise SystemExit(f'Unexpected signing certificate: {name} ({observed})')


def main():
    import argparse
    from pathlib import Path
    from native_release import ROOT, verify_android
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, help='Directory containing native android-<abi>.apk files.')
    verify_android(ROOT, parser.parse_args().directory)


if __name__ == '__main__':
    main()
