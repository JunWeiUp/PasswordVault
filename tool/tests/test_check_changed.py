import unittest
from check_changed import plan


class CheckChangedPlanTests(unittest.TestCase):
    def test_docs_only_needs_nothing(self):
        self.assertEqual(plan(["README.md", "docs/x.md"]), [])

    def test_core_change_rebuilds_mobile_bindings_before_mobile_checks(self):
        steps = plan(["crates/vault-core/src/lib.rs"])
        self.assertEqual(steps, ["core", "desktop", "browser", "android-core", "android", "ios-core", "ios"])

    def test_contract_change_also_runs_tool_tests(self):
        self.assertIn("tools", plan(["crates/vault-core/contract/commands.json"]))

    def test_client_change_stays_on_that_client(self):
        self.assertEqual(plan(["apps/android/app/src/main/java/A.kt"]), ["android"])
        self.assertEqual(plan(["apps/ios/Sources/A.swift"]), ["ios"])
        self.assertEqual(plan(["apps/desktop/ui/App.tsx"]), ["desktop"])
        self.assertEqual(plan(["apps/browser/src/app.tsx"]), ["browser"])

    def test_tool_script_runs_only_tool_tests(self):
        self.assertEqual(plan(["tool/select_ios_simulator.py"]), ["tools"])

    def test_ios_relay_code_checks_ios(self):
        self.assertIn("ios", plan(["apps/ios/Relay/VaultRelay.swift"]))


if __name__ == "__main__":
    unittest.main()
