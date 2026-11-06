#!/usr/bin/env bash
# Source this after choosing RUSTUP_TOOLCHAIN. Never fall back to upstream Cargo.
export CARGO="${PV_CARGO_FORK:-$HOME/.cargo/bin/cargo}"
export PATH="$(dirname "$CARGO"):$PATH"
if ! "$CARGO" --version | grep -q 'huacnlee/cargo'; then
  printf 'This project requires huacnlee/cargo: https://huacnlee.github.io/cargo/\n' >&2
  return 2 2>/dev/null || exit 2
fi
