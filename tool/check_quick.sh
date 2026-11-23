#!/usr/bin/env bash
# Fast multi-platform check wrapper for local dev and AI-assisted iterations.
# Usage: bash tool/check_quick.sh [core|desktop|android|ios|ios-test|all]
# Prefer `python3 tool/check_changed.py`, which picks the targets from your diff.
# Android/iOS use the generated core bindings: after changing crates/, first run
# `bash tool/build_mobile_core.sh android|ios` (check_changed does this for you).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-all}"

run_core() {
  echo "==> [core] fmt + clippy + release tests"
  bash "$ROOT/tool/check_native.sh" core
}

run_desktop() {
  echo "==> [desktop] NSH typecheck + Rust check + smoke tests"
  bash "$ROOT/tool/nsh_mac.sh" check
  bash "$ROOT/tool/nsh_mac.sh" test-smoke
}

run_android() {
  echo "==> [android] Kotlin debug + instrumented-test compilation + JVM unit tests"
  (cd "$ROOT/apps/android" && ./gradlew :app:compileDebugKotlin :app:compileDebugAndroidTestKotlin :app:testDebugUnitTest --quiet)
}

# The Xcode project is generated (and ignored): regenerate so new/removed files are picked up.
ios_project() {
  command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)" >&2; exit 2; }
  xcodegen generate --quiet --spec "$ROOT/apps/ios/project.yml"
}

run_ios() {
  echo "==> [ios] iOS Simulator arm64 build (VaultCore.xcframework is arm64-only)"
  ios_project
  xcodebuild \
    -project "$ROOT/apps/ios/PasswordVault.xcodeproj" \
    -scheme PasswordVault \
    -destination 'generic/platform=iOS Simulator' \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
    build | tail -n 15
}

run_ios_test() {
  echo "==> [ios] unit tests on the nearest installed iPhone simulator"
  ios_project
  local sdk sim log
  sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
  sim="$(xcrun simctl list devices available -j | python3 "$ROOT/tool/select_ios_simulator.py" --sdk "$sdk" --nearest)"
  log="$(mktemp -t pv-ios-test)"
  if ! xcodebuild -project "$ROOT/apps/ios/PasswordVault.xcodeproj" -scheme PasswordVault -configuration Debug \
      -derivedDataPath /tmp/pv-ios-build -destination "platform=iOS Simulator,id=$sim" \
      -only-testing:PasswordVaultTests test >"$log" 2>&1; then
    grep -E "error: -\[|Test Case.*failed|error:" "$log" | head -40
    echo "full log: $log" >&2
    xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true
    exit 1
  fi
  grep -E "Executed [0-9]+ tests" "$log" | tail -1
  xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true
}

case "$TARGET" in
  core)    run_core ;;
  desktop) run_desktop ;;
  android) run_android ;;
  ios)     run_ios ;;
  ios-test) run_ios_test ;;
  all)
    run_core
    run_desktop
    run_android
    run_ios
    ;;
  *)
    echo "Usage: bash tool/check_quick.sh [core|desktop|android|ios|ios-test|all]" >&2
    exit 2
    ;;
esac
echo "✓ check_quick ($TARGET) passed"
