#!/usr/bin/env bash
# Builds Common Relay from a local source tree and runs the vault-core live relay tests on
# loopback: protocol v2 with the current server, and protocol v1 with the last server that
# still served it (the parent of upstream commit bca2745, exported with `git archive`).
#   bash tool/test_relay_live.sh [path/to/common-relay]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="${1:-${COMMON_RELAY_SOURCE:-$HOME/Documents/code/common-relay}}"
[[ -f "$source_dir/cmd/common-relay/main.go" ]] || { echo "Common Relay source not found: $source_dir" >&2; exit 2; }
work="$(mktemp -d -t pv-relay)"
trap 'rm -rf "$work"' EXIT
(cd "$source_dir" && go build -o "$work/common-relay" ./cmd/common-relay)
if v1_commit="$(git -C "$source_dir" rev-parse --verify --quiet 'bca2745^')"; then
  mkdir "$work/v1"
  git -C "$source_dir" archive "$v1_commit" | tar -x -C "$work/v1"
  (cd "$work/v1" && go build -o "$work/common-relay-v1" ./cmd/common-relay)
  export COMMON_RELAY_V1_BIN="$work/common-relay-v1"
fi
cd "$root"
export RUSTUP_TOOLCHAIN=1.98.0
source tool/cargo_fork_env.sh
COMMON_RELAY_BIN="$work/common-relay" "$CARGO" test -p vault-core --release --test relay_live -- --nocapture
