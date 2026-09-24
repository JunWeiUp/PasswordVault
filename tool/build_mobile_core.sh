#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
rust_bin="$(dirname "$(rustup which --toolchain 1.96.0 rustc)")"
export PATH="$rust_bin:$PATH"
case "$(uname -s)" in
  Darwin) host_library=libvault_core.dylib; ndk_host=darwin-x86_64 ;;
  Linux) host_library=libvault_core.so; ndk_host=linux-x86_64 ;;
  *) echo 'Build on macOS or Linux.' >&2; exit 2 ;;
esac

bindings() {
  MACOSX_DEPLOYMENT_TARGET=13.0 cargo build -p vault-core --release --locked
  MACOSX_DEPLOYMENT_TARGET=13.0 cargo run -p vault-core --features bindgen --bin uniffi-bindgen -- generate \
    --library "target/release/$host_library" --language "$1" --out-dir "$2" \
    --config crates/vault-core/uniffi.toml
}
ios() {
  mkdir -p apps/ios/Generated/Headers
  bindings swift apps/ios/Generated
  cp apps/ios/Generated/VaultCoreFFI.h apps/ios/Generated/Headers/
  cp apps/ios/Generated/VaultCoreFFI.modulemap apps/ios/Generated/Headers/module.modulemap
  for mobile_target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    IPHONEOS_DEPLOYMENT_TARGET=16.0 cargo build -p vault-core --release --locked --target "$mobile_target"
  done
  mkdir -p target/ios-simulator
  lipo -create target/aarch64-apple-ios-sim/release/libvault_core.a target/x86_64-apple-ios/release/libvault_core.a -output target/ios-simulator/libvault_core.a
  if [[ -d apps/ios/Generated/VaultCore.xcframework ]]; then
    rm -rf apps/ios/Generated/VaultCore.xcframework
  fi
  xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libvault_core.a -headers apps/ios/Generated/Headers \
    -library target/ios-simulator/libvault_core.a -headers apps/ios/Generated/Headers \
    -output apps/ios/Generated/VaultCore.xcframework
}
android() {
  local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  local ndk="${PASSWORDVAULT_NDK:-$sdk/ndk/27.0.12077973}"
  local bin="$ndk/toolchains/llvm/prebuilt/$ndk_host/bin"
  test -x "$bin/aarch64-linux-android24-clang"
  bindings kotlin apps/android/app/src/main/generated
  for mobile_target in aarch64-linux-android x86_64-linux-android; do
    local triple abi target_env
    case "$mobile_target" in
      aarch64-linux-android) triple=aarch64-linux-android; abi=arm64-v8a; target_env=AARCH64_LINUX_ANDROID ;;
      x86_64-linux-android) triple=x86_64-linux-android; abi=x86_64; target_env=X86_64_LINUX_ANDROID ;;
    esac
    env ANDROID_NDK_HOME="$ndk" PATH="$bin:$PATH" \
      "CARGO_TARGET_${target_env}_LINKER=$bin/${triple}24-clang" \
      "CC_${mobile_target//-/_}=$bin/${triple}24-clang" \
      "AR_${mobile_target//-/_}=$bin/llvm-ar" \
      RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384' \
      cargo build -p vault-core --release --locked --target "$mobile_target"
    mkdir -p "apps/android/app/src/main/jniLibs/$abi"
    cp "target/$mobile_target/release/libvault_core.so" "apps/android/app/src/main/jniLibs/$abi/"
  done
}
case "${1:-all}" in
  ios) ios ;;
  android) android ;;
  all) ios; android ;;
  *) echo 'Usage: bash tool/build_mobile_core.sh [ios|android|all]' >&2; exit 2 ;;
esac
