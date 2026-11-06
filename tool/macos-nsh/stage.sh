#!/usr/bin/env bash
# Shared synthetic-test/package prerequisites; caller sets root and copy.
stage_nsh_sources() {
mkdir -p "$copy/apps" "$copy/crates" "$copy/tool"
rsync -a --delete --exclude target --exclude .nsh "$root/apps/macos-nsh/" "$copy/apps/macos-nsh/"
rsync -a --delete --exclude target "$root/crates/vault-core/" "$copy/crates/vault-core/"
cp "$root/Cargo.toml" "$root/rust-toolchain.toml" "$copy/"
cp "$root/tool/nsh_mac.sh" "$root/tool/cargo_fork_env.sh" "$copy/tool/"
mkdir -p "$copy/tool/nsh-cargo"
cp "$root/tool/nsh-cargo/cargo" "$copy/tool/nsh-cargo/"
}
