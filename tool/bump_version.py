#!/usr/bin/env python3
"""Synchronize release versions and build numbers across all four client stacks.

  python3 tool/bump_version.py 2.5.9
  python3 tool/bump_version.py 2.5.9 --dry-run
  python3 tool/bump_version.py --check
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tool"))
from native_release import validate_versions  # noqa: E402


def parse_semver(value: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"([2-9]\d*)\.(\d+)\.(\d+)", value)
    if not match:
        raise SystemExit(f"Invalid version {value!r}; expected major >= 2 (e.g. 2.5.9).")
    return int(match[1]), int(match[2]), int(match[3])


def compute_metadata(current: dict, new_version: str) -> dict:
    major, minor, patch = parse_semver(new_version)
    derived_code = major * 10000 + minor * 100 + patch
    android_code = max(derived_code, int(current["android_version_code"]) + 1)
    return {
        "version": new_version,
        "android_version_code": android_code,
        "macos_build": int(current["macos_build"]) + 1,
        "ios_build": int(current["ios_build"]) + 1,
    }


def replace_exact(path: Path, pattern: str, replacement: str, expected_count: int) -> None:
    text = path.read_text(encoding="utf-8")
    updated, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count != expected_count:
        raise SystemExit(
            f"{path.name}: expected {expected_count} match(es) for {pattern!r}, found {count}."
        )
    path.write_text(updated, encoding="utf-8")


def apply_bump(root: Path, new_version: str, dry_run: bool = False) -> dict:
    manifest = root / "native-version.json"
    current = json.loads(manifest.read_text(encoding="utf-8"))
    next_meta = compute_metadata(current, new_version)
    if dry_run:
        return next_meta

    manifest.write_text(json.dumps(next_meta, indent=2) + "\n", encoding="utf-8")

    # 1. Browser extension package.json & package-lock.json
    pkg_path = root / "apps/browser/package.json"
    pkg = json.loads(pkg_path.read_text(encoding="utf-8"))
    pkg["version"] = new_version
    pkg_path.write_text(json.dumps(pkg, indent=2) + "\n", encoding="utf-8")

    lock_path = root / "apps/browser/package-lock.json"
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    lock["version"] = new_version
    lock["packages"][""]["version"] = new_version
    lock_path.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")

    # 2. Desktop NSH nsh.json & Cargo.toml
    nsh_path = root / "apps/desktop/nsh.json"
    nsh = json.loads(nsh_path.read_text(encoding="utf-8"))
    nsh["version"] = new_version
    nsh["build"] = next_meta["macos_build"]
    nsh_path.write_text(json.dumps(nsh, indent=2) + "\n", encoding="utf-8")

    desktop_cargo = root / "apps/desktop/Cargo.toml"
    cargo_text = desktop_cargo.read_text(encoding="utf-8")
    head, sep, tail = cargo_text.partition("\n[")
    updated_head, count = re.subn(
        r'^version\s*=\s*"[^"]+"', f'version = "{new_version}"', head, count=1, flags=re.MULTILINE
    )
    if count != 1:
        raise SystemExit("apps/desktop/Cargo.toml: failed to update [package] version.")
    desktop_cargo.write_text(updated_head + sep + tail, encoding="utf-8")

    # 3. Android build.gradle.kts
    android_gradle = root / "apps/android/app/build.gradle.kts"
    replace_exact(android_gradle, r'versionName = "[^"]+"', f'versionName = "{new_version}"', 1)
    replace_exact(
        android_gradle,
        r"versionCode = \d+",
        f'versionCode = {next_meta["android_version_code"]}',
        1,
    )

    # 4. iOS project.yml (app + autofill extension)
    ios_yml = root / "apps/ios/project.yml"
    replace_exact(
        ios_yml,
        r'CFBundleShortVersionString: "[^"]+"',
        f'CFBundleShortVersionString: "{new_version}"',
        2,
    )
    replace_exact(
        ios_yml,
        r'CFBundleVersion: "\d+"',
        f'CFBundleVersion: "{next_meta["ios_build"]}"',
        2,
    )

    validate_versions(root)
    return next_meta


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("version", nargs="?", help="New release version (e.g. 2.5.9)")
    parser.add_argument("--dry-run", action="store_true", help="Print next version metadata without writing files")
    parser.add_argument("--check", action="store_true", help="Verify all client versions match native-version.json")
    args = parser.parse_args(argv)

    if args.check:
        data = validate_versions(ROOT)
        print(f"versions ok: {data['version']} (android={data['android_version_code']}, macos={data['macos_build']}, ios={data['ios_build']})")
        return 0
    if not args.version:
        parser.error("provide a version (e.g. 2.5.9) or --check")
    next_meta = apply_bump(ROOT, args.version, dry_run=args.dry_run)
    prefix = "[dry-run] " if args.dry_run else "updated "
    print(f"{prefix}{json.dumps(next_meta)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
