#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export RUSTUP_TOOLCHAIN=1.96.0
source "$(dirname "$0")/cargo_fork_env.sh"
fixture_root=$(mktemp -d /tmp/passwordvault-peer-interop.XXXXXX)
trap 'rm -rf "$fixture_root"' EXIT
cargo build -p vault-core --example peer_fixture --locked
cp target/debug/examples/peer_fixture "$fixture_root/native-fixture"
cp -R tool/peer-fixture-swift "$fixture_root/swift"
mkdir -p "$fixture_root/swift/CommonRelay"
cp vendor/common-relay/swift/Package.swift vendor/common-relay/swift/Package.resolved "$fixture_root/swift/CommonRelay/"
cp -R vendor/common-relay/swift/Sources "$fixture_root/swift/CommonRelay/"
swift build --package-path "$fixture_root/swift" -c debug
TMPDIR="$fixture_root" PEER_NATIVE_FIXTURE="$fixture_root/native-fixture" PEER_SWIFT_FIXTURE="$fixture_root/swift/.build/debug/PeerFixture" node --test apps/browser/tests/peer-interop.test.mjs
