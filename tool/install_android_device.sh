#!/usr/bin/env bash
# Build and install the matching-signature ARM64 APK onto connected Android device(s).
# Automatically inspects each device's installed com.securepass.vault.nativepreview
# versionName (-preview -> debug, otherwise -> previewRelease) so installs never hit
# signature conflicts or require uninstalling user data.
#
#   bash tool/install_android_device.sh                    # all connected physical devices
#   bash tool/install_android_device.sh --serial 41988b4c  # one specific device/emulator
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SERIAL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) SERIAL="${2:?missing serial}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

DEVICES=()
if [[ -n "$SERIAL" ]]; then
  DEVICES=("$SERIAL")
else
  while IFS= read -r serial; do
    [[ -n "$serial" && "$serial" != emulator-* ]] && DEVICES+=("$serial")
  done < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
fi

if [[ ${#DEVICES[@]} -eq 0 ]]; then
  echo "No connected physical Android device found (pass --serial <id> to target an emulator)." >&2
  exit 1
fi

if [[ ! -f apps/android/app/src/main/jniLibs/arm64-v8a/libvault_core.so ]]; then
  echo "==> Building Android arm64-v8a vault-core..."
  PASSWORDVAULT_ANDROID_ABI=arm64-v8a bash tool/build_mobile_core.sh android
fi

NEED_DEBUG=0
NEED_RELEASE=0
VARIANTS=()
for d in "${DEVICES[@]}"; do
  vname="$(adb -s "$d" shell dumpsys package com.securepass.vault.nativepreview 2>/dev/null | sed -n 's/.*versionName=\([^[:space:]]*\).*/\1/p' | head -n 1 || true)"
  if [[ -n "$vname" && "$vname" != *-preview ]]; then
    VARIANTS+=("previewRelease")
    NEED_RELEASE=1
    echo "==> $d (installed: $vname) -> previewRelease"
  else
    VARIANTS+=("debug")
    NEED_DEBUG=1
    echo "==> $d (installed: ${vname:-none}) -> debug"
  fi
done

TASKS=()
[[ "$NEED_DEBUG" -eq 1 ]] && TASKS+=(:app:assembleDebug)
[[ "$NEED_RELEASE" -eq 1 ]] && TASKS+=(:app:assemblePreviewRelease)
./apps/android/gradlew -p apps/android "${TASKS[@]}" -PtargetAbi=arm64-v8a --quiet

for i in "${!DEVICES[@]}"; do
  d="${DEVICES[$i]}"
  v="${VARIANTS[$i]}"
  if [[ "$v" == "previewRelease" ]]; then
    apk="apps/android/app/build/outputs/apk/previewRelease/app-previewRelease.apk"
  else
    apk="apps/android/app/build/outputs/apk/debug/app-debug.apk"
  fi
  echo "==> Installing $v onto $d..."
  adb -s "$d" install -r "$apk"
done
echo "✓ Android install complete"
