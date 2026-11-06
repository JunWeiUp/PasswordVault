#!/usr/bin/env python3
"""Select an available iPhone matching the selected Xcode simulator SDK."""
import argparse
import json
import re
import sys


def select_simulator(data, sdk_version):
    match = re.fullmatch(r'(\d+)\.(\d+)(?:\.\d+)?', sdk_version.strip())
    if not match:
        raise ValueError('Expected an iOS simulator SDK version')
    target = f'com.apple.CoreSimulator.SimRuntime.iOS-{match[1]}-{match[2]}'
    devices = data.get('devices', {}).get(target, [])
    phones = [device for device in devices if device.get('isAvailable', True)
              and device.get('name', '').startswith('iPhone') and device.get('udid')]
    if not phones:
        raise ValueError(f'No available iPhone for SDK {sdk_version}; install its matching simulator runtime')
    phones.sort(key=lambda device: (device.get('state') != 'Booted', device['name'], device['udid']))
    return phones[0]['udid']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', required=True)
    args = parser.parse_args()
    try:
        print(select_simulator(json.load(sys.stdin), args.sdk))
    except (ValueError, KeyError) as error:
        parser.exit(1, f'{error}\n')
