#!/usr/bin/env bash
# Repository checks are independent of platform build dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-repo}" in
  repo)
    python3 tool/check_repository.py
    python3 -m unittest discover -s tool -p 'test_*.py'
    ;;
  *)
    printf 'Usage: bash tool/check.sh repo (platform checks: bash tool/check_native.sh core|macos|browser)\n' >&2
    exit 2
    ;;
esac
