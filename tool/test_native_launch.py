"""Exercise native-host cold launch using a disposable macOS app, never a vault.

Run: python3 tool/test_native_launch.py
Optional --bridge-source accepts an older helper source for regression verification.
"""
import argparse
import json
import os
import pathlib
import plistlib
import signal
import struct
import subprocess
import tempfile
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
ORIGIN = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"


def request(helper, operation, origin=ORIGIN):
    body = json.dumps({"version": 2, "op": operation}).encode()
    # EOF after the one request reproduces sendNativeMessage's short-lived host.
    result = subprocess.run(
        [str(helper), origin], input=struct.pack("<I", len(body)) + body,
        capture_output=True, timeout=20,
    )
    assert len(result.stdout) >= 4, "Missing native response"
    length = struct.unpack("<I", result.stdout[:4])[0]
    assert len(result.stdout) == length + 4, "Invalid native framing"
    return json.loads(result.stdout[4:])


def await_file(path):
    deadline = time.monotonic() + 5
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    assert path.exists(), f"App did not produce {path.name}"
    return path.read_text()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge-source", type=pathlib.Path,
                        default=ROOT / "apps/macos/Bridge/main.swift")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="passwordvault-launch-test-") as directory:
        root = pathlib.Path(directory)
        application = root / "Launch Fixture.app"
        contents = application / "Contents"
        binaries = contents / "MacOS"
        resources = contents / "Resources"
        binaries.mkdir(parents=True)
        resources.mkdir()
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.example.launch-fixture." + uuid.uuid4().hex,
            "CFBundleExecutable": "LaunchFixture", "CFBundlePackageType": "APPL",
            "CFBundleName": "Launch Fixture", "LSUIElement": True,
        }))
        (resources / "BrowserIdentity.json").write_text(json.dumps({
            "extensionId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        }))
        fixture = root / "fixture.swift"
        fixture.write_text('''import AppKit
import Foundation
let root = Bundle.main.bundleURL.deletingLastPathComponent()
class Delegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    try! String(ProcessInfo.processInfo.processIdentifier).write(
      to: root.appendingPathComponent("launched"), atomically: true, encoding: .utf8)
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    try! "reopened".write(to: root.appendingPathComponent("reopened"), atomically: true, encoding: .utf8)
    return true
  }
}
let delegate = Delegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
''')
        helper = binaries / "PasswordVaultBridge"
        subprocess.run(["xcrun", "swiftc", str(fixture), "-o", str(binaries / "LaunchFixture")], check=True)
        subprocess.run(["xcrun", "swiftc", str(args.bridge_source), "-o", str(helper)], check=True)
        pid = None
        try:
            assert request(helper, "open", "chrome-extension://invalid/") == {
                "ok": False, "error": "invalid-origin"}
            assert not (root / "launched").exists(), "Invalid origin launched app"
            print("PASS: invalid extension origin rejected", flush=True)
            response = request(helper, "open")
            assert response == {"ok": True}, response
            pid = int(await_file(root / "launched"))
            os.kill(pid, 0)
            print("PASS: cold launch completes with stdin already closed", flush=True)
            assert request(helper, "open") == {"ok": True}
            await_file(root / "reopened")
            assert int((root / "launched").read_text()) == pid
            print("PASS: existing app reopened without duplicate process", flush=True)
            # Independent malformed bundle exercises an actual Launch Services error.
            broken = root / "Broken Fixture.app/Contents"
            (broken / "MacOS").mkdir(parents=True)
            (broken / "Resources").mkdir()
            import shutil
            shutil.copy2(helper, broken / "MacOS/PasswordVaultBridge")
            shutil.copy2(resources / "BrowserIdentity.json", broken / "Resources/BrowserIdentity.json")
            (broken / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.example.broken." + uuid.uuid4().hex,
                "CFBundleExecutable": "MissingExecutable", "CFBundlePackageType": "APPL",
            }))
            assert request(broken / "MacOS/PasswordVaultBridge", "open") == {
                "ok": False, "error": "native-unavailable"}
            print("PASS: launch failure returns error instead of false success", flush=True)
        finally:
            if pid is None and (root / "launched").exists():
                pid = int((root / "launched").read_text())
            if pid is not None:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    main()
