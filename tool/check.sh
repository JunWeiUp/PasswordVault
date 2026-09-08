#!/usr/bin/env bash
# The same checks run locally and in GitHub Actions.
set -euo pipefail
cd "$(dirname "$0")/.."

check_toolchain() {
  local expected actual
  expected="$(cat .flutter-version)"
  actual="$(flutter --version --machine | python3 -c 'import json, sys; print(json.load(sys.stdin)["frameworkVersion"])')"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected Flutter %s from .flutter-version; found %s.\n' "$expected" "$actual" >&2
    exit 1
  fi
}

prepare_flutter() {
  check_toolchain
  flutter pub get --enforce-lockfile
  flutter gen-l10n
}

check_repository() {
  python3 tool/check_repository.py
  python3 -m unittest discover -s tool -p 'test_*.py'
  node --test test/extension/*.test.cjs
}

check_flutter() {
  prepare_flutter
  python3 tool/update_sqlite_wasm.py --check
  dart run build_runner build --delete-conflicting-outputs
  git diff --exit-code -- lib/core/database/app_database.g.dart
  dart format --output=none --set-exit-if-changed lib test tool
  flutter analyze --no-pub --no-fatal-infos
  flutter test --no-pub --coverage
}

case "${1:-all}" in
  repo) check_repository ;;
  flutter) check_flutter ;;
  android)
    prepare_flutter
    flutter build apk --debug --no-pub
    ;;
  web)
    check_toolchain
    ./build_extension.sh
    ;;
  all)
    check_repository
    check_flutter
    flutter build apk --debug --no-pub
    ./build_extension.sh
    ;;
  *)
    printf 'Usage: bash tool/check.sh [repo|flutter|android|web|all]\n' >&2
    exit 2
    ;;
esac
