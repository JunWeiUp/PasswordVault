#!/usr/bin/env python3
"""Select an available iPhone matching the selected Xcode simulator SDK."""
import argparse
import json
import re
import sys


RUNTIME = re.compile(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+)-(\d+)')


def select_simulator(data, sdk_version, nearest=False):
    """Exact runtime by default (CI). `nearest` (local only) falls back to the newest
    installed runtime not newer than the SDK, so a point-release SDK still finds a phone."""
    match = re.fullmatch(r'(\d+)\.(\d+)(?:\.\d+)?', sdk_version.strip())
    if not match:
        raise ValueError('Expected an iOS simulator SDK version')
    target = f'com.apple.CoreSimulator.SimRuntime.iOS-{match[1]}-{match[2]}'
    devices = data.get('devices', {}).get(target, [])
    if nearest and not _phones(devices):
        sdk = (int(match[1]), int(match[2]))
        runtimes = sorted(((int(m[1]), int(m[2])), key) for key in data.get('devices', {})
                          if (m := RUNTIME.fullmatch(key)) and (int(m[1]), int(m[2])) <= sdk
                          and _phones(data['devices'][key]))
        if runtimes:
            devices = data['devices'][runtimes[-1][1]]
    return _pick(devices, sdk_version)


def _phones(devices):
    return [device for device in devices if device.get('isAvailable', True)
            and device.get('name', '').startswith('iPhone') and device.get('udid')]


def _pick(devices, sdk_version):
    phones = _phones(devices)
    if not phones:
        raise ValueError(f'No available iPhone for SDK {sdk_version}; install its matching simulator runtime')
    phones.sort(key=lambda device: (device.get('state') != 'Booted', device['name'], device['udid']))
    return phones[0]['udid']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--nearest', action='store_true', help='local only: fall back to the newest older runtime')
    args = parser.parse_args()
    try:
        print(select_simulator(json.load(sys.stdin), args.sdk, args.nearest))
    except (ValueError, KeyError) as error:
        parser.exit(1, f'{error}\n')
