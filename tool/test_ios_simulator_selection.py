import unittest
from select_ios_simulator import select_simulator


class IOSSimulatorSelectionTests(unittest.TestCase):
    def fixtures(self):
        return {'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-18-5': [{'name': 'iPhone 16', 'udid': 'old', 'isAvailable': True}],
            'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [
                {'name': 'iPad Pro', 'udid': 'tablet', 'isAvailable': True},
                {'name': 'iPhone 16', 'udid': 'unavailable', 'isAvailable': False},
                {'name': 'iPhone 17', 'udid': 'correct', 'isAvailable': True}],
        }}

    def test_uses_matching_sdk_instead_of_first_installed_runtime(self):
        self.assertEqual(select_simulator(self.fixtures(), '26.2'), 'correct')
        self.assertEqual(select_simulator(self.fixtures(), '26.2.1'), 'correct')

    def test_missing_runtime_fails_instead_of_silently_running_an_old_os(self):
        with self.assertRaisesRegex(ValueError, 'No available iPhone'):
            select_simulator(self.fixtures(), '26.3')

    def test_rejects_malformed_sdk(self):
        with self.assertRaises(ValueError):
            select_simulator(self.fixtures(), '')
