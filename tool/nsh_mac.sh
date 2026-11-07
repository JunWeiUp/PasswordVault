#!/usr/bin/env bash
# Runs the nsh CLI for the Native Shell Mac preview (apps/desktop) with the
# pinned rustc and required huacnlee/cargo fork. The artifact bridge adapts
# NSH runner lookup while keeping build outputs managed by the fork.
#
#   bash tool/nsh_mac.sh check
#   bash tool/nsh_mac.sh run App.tsx --target macos
#   bash tool/nsh_mac.sh test
#   bash tool/nsh_mac.sh package App.tsx --target macos
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/apps/desktop"
rustup_cmd="${RUSTUP:-$(command -v rustup || echo "$HOME/.cargo/bin/rustup")}"
channel="$(sed -n 's/^channel = "\(.*\)"/\1/p' "$app/rust-toolchain.toml")"
toolchain_bin="$(dirname "$("$rustup_cmd" which --toolchain "$channel" rustc)")"
# Keep the fork ahead of the toolchain's official Cargo, while pinning rustc.
export PATH="$root/tool/nsh-cargo:$HOME/.cargo/bin:$toolchain_bin:$PATH"
export RUSTUP_TOOLCHAIN="$channel"
# Core and desktop pin different rustc versions; isolate dependency metadata.
export CARGO_SHARED_DEPS="${CARGO_SHARED_DEPS:-0}"
export CARGO="$root/tool/nsh-cargo/cargo"
if ! "$CARGO" --version | grep -q 'huacnlee/cargo'; then
  printf 'huacnlee/cargo is required: https://huacnlee.github.io/cargo/\n' >&2
  exit 2
fi
nsh_cmd="${NSH_BIN:-$HOME/.nsh-0.4.0/bin/nsh}"
if [[ ! -x "$nsh_cmd" ]] || [[ "$("$nsh_cmd" --version)" != 'nsh 0.4.0 '* ]]; then
  printf 'NSH 0.4.0 is required; set NSH_BIN to its executable.\n' >&2
  exit 2
fi
cd "$app"
# Test hosts must not take the installed app's global Quick Access shortcut.
if [[ "${1:-}" == "test" ]]; then
  # Never let a test open the default preview or daily-use vault.
  case "${PASSWORDVAULT_VAULT_DIRECTORY:-}" in
    /tmp/*|/private/tmp/*|"${TMPDIR:-/tmp/}"*) ;;
    *) printf 'Tests require PASSWORDVAULT_VAULT_DIRECTORY pointing to a fresh synthetic vault in a temporary directory.\n' >&2; exit 2 ;;
  esac
  export PV_DISABLE_HOTKEY=1
  # Never collide with an installed preview's fixed AI socket.
  mkdir -p "/tmp/pv-ai-test-$$" && chmod 700 "/tmp/pv-ai-test-$$"
  export PASSWORDVAULT_AI_SOCKET="/tmp/pv-ai-test-$$/mcp.sock"
fi
exec "$nsh_cmd" "$@"
