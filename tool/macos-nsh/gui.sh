#!/usr/bin/env bash
# Real-window tests of the Native Shell Mac preview, only on the yomado virtual
# screen named "… PasswordVault QA" (never a physical display). Runs from a
# /tmp copy with a fresh synthetic vault; screenshots go to /tmp/pv-nsh-shots.
#
#   bash tool/macos-nsh/gui.sh [test files…]
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/tool/cargo_fork_env.sh"
screen_name="${PV_QA_SCREEN:-PasswordVault QA}"

index="$(PV_WANT_SCREEN="$screen_name" swift -e '
import AppKit
let want = ProcessInfo.processInfo.environment["PV_WANT_SCREEN"] ?? ""
for (i, s) in NSScreen.screens.enumerated() where !want.isEmpty && s.localizedName.contains(want) { print(i + 1); exit(0) }
exit(1)' 2>/dev/null)" || {
  printf 'No yomado screen named "%s". Create it in yomado first; refusing to use a physical display.\n' "$screen_name" >&2
  exit 1
}

# yomado skill checkpoint: the display arrangement and main display must not change.
layout() {
  /Applications/Yomado.app/Contents/MacOS/Yomado --diagnose 2>/dev/null | python3 -c '
import json, sys
for d in sorted(json.load(sys.stdin)["displays"], key=lambda d: d["displayID"]):
    b = d["bounds"]
    print(d["displayID"], int(bool(d.get("isMain"))), b["x"], b["y"], b["width"], b["height"])'
}
before="$(layout)"

copy=/tmp/pv-nsh-gui
source "$root/tool/macos-nsh/stage.sh"
stage_nsh_sources

toolchain_bin="$(dirname "$(rustup which --toolchain "$(sed -n 's/^channel = "\(.*\)"/\1/p' "$root/apps/macos-nsh/rust-toolchain.toml")" rustc)")"
seed=/tmp/pv-nsh-qa
if [[ ! -d "$seed/vault" ]]; then
  (cd "$copy/apps/macos-nsh" && PATH="$HOME/.cargo/bin:$toolchain_bin:$PATH" RUSTUP_TOOLCHAIN=1.98.0 cargo run -q --example seed -- "$seed/vault")
fi
run=/tmp/pv-nsh-gui-vault
rm -rf "$run" && cp -R "$seed" "$run"
mkdir -p /tmp/pv-nsh-shots

cd "$copy"
# nsh 0.3.0 has no --display: the app moves its own window there (src/qa_window.rs).
printf 'QA screen: %s (screen %s)\n' "$screen_name" "$index"
status=0
PV_QA_SCREEN="$screen_name" PASSWORDVAULT_VAULT_DIRECTORY="$run/vault" \
  bash tool/nsh_mac.sh test "${@:-tests/workspace.test.tsx}" --target macos || status=$?
if [[ "$(layout)" != "$before" ]]; then
  printf 'Display layout changed during the run; stop and check yomado/main display.\n' >&2
  exit 3
fi
exit "$status"
