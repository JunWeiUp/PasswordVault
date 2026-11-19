#!/usr/bin/env bash
# Runs the nsh CLI for the Native Shell Mac preview (apps/desktop) with the
# pinned rustc and required huacnlee/cargo fork. The artifact bridge adapts
# NSH runner lookup while keeping build outputs managed by the fork.
#
#   bash tool/nsh_mac.sh check
#   bash tool/nsh_mac.sh run App.tsx --target macos
#   bash tool/nsh_mac.sh test [nsh test args...]           # requires PASSWORDVAULT_VAULT_DIRECTORY=/tmp/...
#   bash tool/nsh_mac.sh test-fast <name|path|--rust pat>  # auto-seeds /tmp vault, runs 1 suite (~6-10s) or Rust filter (~2s)
#   bash tool/nsh_mac.sh test-smoke                        # auto-seeds /tmp vault, full suite skipping 27s memory test
#   bash tool/nsh_mac.sh test-full                         # auto-seeds /tmp vault, full suite including memory test
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
# Desktop is a separate workspace with its own lockfile; isolate dependency metadata from core.
export CARGO_SHARED_DEPS="${CARGO_SHARED_DEPS:-0}"
export CARGO="$root/tool/nsh-cargo/cargo"
if ! "$CARGO" --version | grep -q 'huacnlee/cargo'; then
  printf 'huacnlee/cargo is required: https://huacnlee.github.io/cargo/\n' >&2
  exit 2
fi
nsh_cmd="${NSH_BIN:-$HOME/.nsh-0.6.0/bin/nsh}"
if [[ ! -x "$nsh_cmd" ]] || [[ "$("$nsh_cmd" --version)" != 'nsh 0.6.0 '* ]]; then
  printf 'NSH 0.6.0 is required; set NSH_BIN to its executable.\n' >&2
  exit 2
fi
cd "$app"

# Prepares a cached clean synthetic vault in /tmp and copies a disposable instance for this test run.
prepare_temp_seed_vault() {
  local prefix="${1:-pv-nsh-test}"
  local seed_hash cache_root cached_vault run_dir
  seed_hash="$(python3 - "$root" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
h = hashlib.sha256()
for p in [root / "apps/desktop/examples/seed.rs", *(root / "crates/vault-core/src").rglob("*.rs")]:
    if p.is_file():
        h.update(p.relative_to(root).as_posix().encode())
        h.update(b"\0")
        h.update(p.read_bytes())
print(h.hexdigest()[:16])
PY
)"
  cache_root="/tmp/pv-nsh-seed-cache"
  cached_vault="$cache_root/$seed_hash/vault"
  if [[ ! -d "$cached_vault" ]]; then
    rm -rf "$cache_root"
    mkdir -p "$cache_root/$seed_hash"
    "$CARGO" run --quiet --example seed -- "$cached_vault"
  fi
  run_dir="/tmp/${prefix}-$$"
  rm -rf "$run_dir" && mkdir -p "$run_dir"
  cp -R "$cached_vault" "$run_dir/vault"
  export PASSWORDVAULT_VAULT_DIRECTORY="$run_dir/vault"
  mkdir -p "/tmp/pv-ai-test-$$" && chmod 700 "/tmp/pv-ai-test-$$"
  export PASSWORDVAULT_AI_SOCKET="/tmp/pv-ai-test-$$/mcp.sock"
  export PV_DISABLE_HOTKEY=1
  export PV_ALLOW_LOCAL_SESSION=1
  trap "rm -rf '$run_dir' '/tmp/pv-ai-test-$$'" EXIT
}

cmd="${1:-}"
case "$cmd" in
  test-fast)
    shift
    if [[ "${1:-}" == "--rust" ]]; then
      shift
      exec "$CARGO" test --lib "$@"
    fi
    target="${1:?usage: test-fast <suite-name|tests/file.test.tsx|--rust pattern>}"
    shift
    if [[ ! -f "$target" ]]; then
      if [[ -f "tests/${target}.test.tsx" ]]; then
        target="tests/${target}.test.tsx"
      elif [[ -f "tests/${target}.test.ts" ]]; then
        target="tests/${target}.test.ts"
      elif [[ -f "tests/${target}" ]]; then
        target="tests/${target}"
      else
        printf 'Unknown test suite: %s\nAvailable: ' "$target" >&2
        ls tests/*.test.tsx tests/*.test.ts 2>/dev/null | sed 's|tests/||;s|\.test\.tsx\?$||' | tr '\n' ' ' >&2
        printf '\n' >&2
        exit 2
      fi
    fi
    prepare_temp_seed_vault
    "$nsh_cmd" test "$target" "$@"
    exit $?
    ;;
  test-smoke)
    shift
    prepare_temp_seed_vault pv-nsh-smoke
    "$nsh_cmd" test "$@"
    exit $?
    ;;
  test-full)
    shift
    prepare_temp_seed_vault pv-nsh-full
    "$nsh_cmd" test "$@"
    exit $?
    ;;
  test)
    # Never let a test open the default preview or daily-use vault.
    case "${PASSWORDVAULT_VAULT_DIRECTORY:-}" in
      /tmp/*|/private/tmp/*|"${TMPDIR:-/tmp/}"*) ;;
      *) printf 'Tests require PASSWORDVAULT_VAULT_DIRECTORY pointing to a fresh synthetic vault in a temporary directory (or use test-fast / test-smoke / test-full).\n' >&2; exit 2 ;;
    esac
    export PV_DISABLE_HOTKEY=1
    # Component tests use an explicit temporary fixture; signed process/IPC checks
    # run separately via tool/test_background_service.py.
    export PV_ALLOW_LOCAL_SESSION=1
    # Never collide with an installed preview's fixed AI socket.
    mkdir -p "/tmp/pv-ai-test-$$" && chmod 700 "/tmp/pv-ai-test-$$"
    export PASSWORDVAULT_AI_SOCKET="/tmp/pv-ai-test-$$/mcp.sock"
    trap 'rm -rf "/tmp/pv-ai-test-$$"' EXIT
    "$nsh_cmd" "$@"
    exit $?
    ;;
esac

exec "$nsh_cmd" "$@"
