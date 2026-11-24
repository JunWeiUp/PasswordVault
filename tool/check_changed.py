#!/usr/bin/env python3
"""Run only the checks that the current change needs.

  python3 tool/check_changed.py              # working tree (staged, unstaged, untracked) vs HEAD
  python3 tool/check_changed.py --base main  # everything since main, plus the working tree
  python3 tool/check_changed.py --dry-run    # print the plan only
  python3 tool/check_changed.py --only ios,android

Path → scope rules are shared with CI (tool/ci_changes.py). A core change selects every
client because each one embeds vault-core; mobile bindings are rebuilt before their checks.
Windows cannot be checked on a Mac: the desktop step covers the shared code, the Windows
VM build stays manual.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tool"))
from ci_changes import classify  # noqa: E402

# Tooling scripts own unit tests; they do not need native builds.
TOOL_ONLY = ("tool/core_contract.py", "tool/check_changed.py", "tool/select_ios_simulator.py",
             "tool/ci_changes.py", "tool/native_release.py", "tool/package_release.py",
             "tool/validate_release_ref.py", "tool/update_security_catalog.py",
             "tool/bump_version.py")

STEPS = {
    "tools": ["python3", "-m", "unittest", "discover", "-s", "tool", "-p", "test_*.py", "-q"],
    "core": ["bash", "tool/check_native.sh", "core"],
    "desktop": ["bash", "tool/check_quick.sh", "desktop"],
    "browser": ["bash", "tool/check_native.sh", "browser"],
    "android-core": ["bash", "tool/build_mobile_core.sh", "android"],
    "android": ["bash", "tool/check_quick.sh", "android"],
    "ios-core": ["env", "PASSWORDVAULT_IOS_TARGETS=simulator", "bash", "tool/build_mobile_core.sh", "ios"],
    "ios": ["bash", "tool/check_quick.sh", "ios-test"],
}
ORDER = list(STEPS)


def git(*args: str) -> list[str]:
    out = subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if line]


def changed(base: str | None) -> list[str]:
    paths = set(git("diff", "--name-only", "HEAD"))
    paths |= set(git("ls-files", "--others", "--exclude-standard"))
    if base:
        paths |= set(git("diff", "--name-only", f"{base}...HEAD"))
    return sorted(paths)


def plan(paths: list[str]) -> list[str]:
    steps: set[str] = set()
    native = []
    for path in paths:
        if path in TOOL_ONLY or (path.startswith("tool/test_") and path.endswith(".py")):
            steps.add("tools")
        else:
            native.append(path)
    scopes = classify(native)
    core_changed = any(p.startswith(("crates/", "Cargo.", "rust-toolchain")) or p == "tool/build_mobile_core.sh" for p in native)
    if "core" in scopes and core_changed:
        steps.add("core")
    if scopes & {"macos", "windows"}:
        steps.add("desktop")
    if "browser" in scopes:
        steps.add("browser")
    for mobile in ("android", "ios"):
        if mobile in scopes:
            steps.add(mobile)
            if core_changed:
                steps.add(f"{mobile}-core")
    if any(p.startswith("tool/") for p in native) or "crates/vault-core/contract/commands.json" in paths:
        steps.add("tools")
    return [s for s in ORDER if s in steps]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", help="also include commits since this ref (e.g. main)")
    parser.add_argument("--only", help="comma-separated subset of steps: " + ",".join(ORDER))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    paths = changed(args.base)
    steps = plan(paths)
    if args.only:
        wanted = set(args.only.split(","))
        unknown = wanted - set(STEPS)
        if unknown:
            parser.error(f"unknown steps: {', '.join(sorted(unknown))}")
        steps = [s for s in steps if s in wanted or s.removesuffix("-core") in wanted]
    print(f"{len(paths)} changed path(s) → " + (", ".join(steps) or "no checks needed (docs only)"))
    if args.dry_run:
        for step in steps:
            print(f"  {step}: {' '.join(STEPS[step])}")
        return 0
    for step in steps:
        print(f"\n==> {step}: {' '.join(STEPS[step])}", flush=True)
        if subprocess.run(STEPS[step], cwd=ROOT).returncode != 0:
            print(f"\n✗ {step} failed", file=sys.stderr)
            return 1
    print("\n✓ all selected checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
