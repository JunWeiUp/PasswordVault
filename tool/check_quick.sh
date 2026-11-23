#!/usr/bin/env bash
# Fast multi-platform check wrapper for local dev and AI-assisted iterations.
# Usage: bash tool/check_quick.sh [core|desktop|android|ios|all]
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
  echo "==> [android] Kotlin debug + unit-test compilation"
  (cd "$ROOT/apps/android" && ./gradlew :app:compileDebugKotlin :app:compileDebugUnitTestKotlin --quiet)
}

run_ios() {
  echo "==> [ios] iOS Simulator arm64 build (VaultCore.xcframework is arm64-only)"
  xcodebuild \
    -project "$ROOT/apps/ios/PasswordVault.xcodeproj" \
    -scheme PasswordVault \
    -destination 'generic/platform=iOS Simulator' \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
    build | tail -n 15
}

case "$TARGET" in
  core)    run_core ;;
  desktop) run_desktop ;;
  android) run_android ;;
  ios)     run_ios ;;
  all)
    run_core
    run_desktop
    run_android
    run_ios
    ;;
  *)
    echo "Usage: bash tool/check_quick.sh [core|desktop|android|ios|all]" >&2
    exit 2
    ;;
esac
echo "✓ check_quick ($TARGET) passed"
