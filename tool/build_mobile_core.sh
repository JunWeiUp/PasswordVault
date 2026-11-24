#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
rust_bin="$(dirname "$(rustup which --toolchain 1.98.0 rustc)")"
export RUSTUP_TOOLCHAIN=1.98.0
source tool/cargo_fork_env.sh
case "$(uname -s)" in
  Darwin) host_library=libvault_core.dylib; ndk_host=darwin-x86_64 ;;
  Linux) host_library=libvault_core.so; ndk_host=linux-x86_64 ;;
  *) echo 'Build on macOS or Linux.' >&2; exit 2 ;;
esac

mobile_editor_built=false
bundle_editor() {
  if [[ "$mobile_editor_built" == true ]]; then return; fi
  local dir="apps/shared/note-editor"
  local lock="$dir/package-lock.json"
  local stamp="$dir/node_modules/.package-lock.stamp"
  if [[ -n "${CI:-}" || ! -d "$dir/node_modules" || ! -f "$stamp" ]] || ! cmp -s "$lock" "$stamp"; then
    npm --prefix "$dir" ci --ignore-scripts
    if [[ -d "$dir/node_modules" && -f "$lock" ]]; then
      cp "$lock" "$stamp"
    fi
  fi
  npm --prefix "$dir" run build
  mobile_editor_built=true
}
bindings() {
  MACOSX_DEPLOYMENT_TARGET=13.0 cargo build -p vault-core --release --locked
  MACOSX_DEPLOYMENT_TARGET=13.0 cargo run -p vault-core --features bindgen --bin uniffi-bindgen -- generate \
    --library "target/release/$host_library" --language "$1" --out-dir "$2" \
    --config crates/vault-core/uniffi.toml
}
ios() {
  local simulator_arch="${PASSWORDVAULT_IOS_SIM_ARCH:-host}"
  if [[ "$simulator_arch" == host ]]; then simulator_arch="$(uname -m)"; fi
  local simulator_targets
  case "$simulator_arch" in
    universal) simulator_targets=(aarch64-apple-ios-sim x86_64-apple-ios) ;;
    arm64) simulator_targets=(aarch64-apple-ios-sim) ;;
    x86_64) simulator_targets=(x86_64-apple-ios) ;;
    *) echo 'Invalid PASSWORDVAULT_IOS_SIM_ARCH; use universal, host, arm64 or x86_64.' >&2; return 2 ;;
  esac
  local ios_targets_mode="${PASSWORDVAULT_IOS_TARGETS:-all}"
  local build_targets=()
  case "$ios_targets_mode" in
    all) build_targets=(aarch64-apple-ios "${simulator_targets[@]}") ;;
    simulator) build_targets=("${simulator_targets[@]}") ;;
    *) echo 'Invalid PASSWORDVAULT_IOS_TARGETS; use all or simulator.' >&2; return 2 ;;
  esac
  bundle_editor
  mkdir -p apps/ios/Generated/Headers
  bindings swift apps/ios/Generated
  cp apps/ios/Generated/VaultCoreFFI.h apps/ios/Generated/Headers/
  cp apps/ios/Generated/VaultCoreFFI.modulemap apps/ios/Generated/Headers/module.modulemap
  for mobile_target in "${build_targets[@]}"; do
    IPHONEOS_DEPLOYMENT_TARGET=16.0 cargo build -p vault-core --release --locked --target "$mobile_target"
  done
  mkdir -p target/ios-simulator
  if [[ ${#simulator_targets[@]} -eq 2 ]]; then
    lipo -create target/aarch64-apple-ios-sim/release/libvault_core.a target/x86_64-apple-ios/release/libvault_core.a -output target/ios-simulator/libvault_core.a
  else
    cp "target/${simulator_targets[0]}/release/libvault_core.a" target/ios-simulator/libvault_core.a
  fi
  if [[ -d apps/ios/Generated/VaultCore.xcframework ]]; then
    rm -rf apps/ios/Generated/VaultCore.xcframework
  fi
  if [[ "$ios_targets_mode" == simulator ]]; then
    xcodebuild -create-xcframework \
      -library target/ios-simulator/libvault_core.a -headers apps/ios/Generated/Headers \
      -output apps/ios/Generated/VaultCore.xcframework
  else
    xcodebuild -create-xcframework \
      -library target/aarch64-apple-ios/release/libvault_core.a -headers apps/ios/Generated/Headers \
      -library target/ios-simulator/libvault_core.a -headers apps/ios/Generated/Headers \
      -output apps/ios/Generated/VaultCore.xcframework
  fi
}
android() {
  local android_targets
  case "${PASSWORDVAULT_ANDROID_ABI:-arm64-v8a}" in
    all) android_targets=(aarch64-linux-android x86_64-linux-android) ;;
    arm64-v8a) android_targets=(aarch64-linux-android) ;;
    x86_64) android_targets=(x86_64-linux-android) ;;
    *) echo 'Invalid PASSWORDVAULT_ANDROID_ABI; use all, arm64-v8a or x86_64.' >&2; return 2 ;;
  esac
  local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  local ndk="${PASSWORDVAULT_NDK:-$sdk/ndk/27.0.12077973}"
  local bin="$ndk/toolchains/llvm/prebuilt/$ndk_host/bin"
  test -x "$bin/aarch64-linux-android24-clang"
  bundle_editor
  bindings kotlin apps/android/app/src/main/generated
  for mobile_target in "${android_targets[@]}"; do
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
