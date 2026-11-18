#!/usr/bin/env bash
# Builds the experimental mobile NSH UI bundle (experiments/mobile-nsh/ui) into ui/build/nsh,
# which the iOS app copies as a folder resource and the Android app as assets.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
nsh_cmd="${NSH_BIN:-$HOME/.nsh-0.5.1/bin/nsh}"
if [[ ! -x "$nsh_cmd" ]] || [[ "$("$nsh_cmd" --version)" != 'nsh 0.5.1 '* ]]; then
  printf 'NSH 0.5.1 is required; set NSH_BIN to its executable.\n' >&2
  exit 2
fi
cd "$root/experiments/mobile-nsh/ui"
rm -rf build/nsh
"$nsh_cmd" build App.tsx --release --out build/nsh
test -f build/nsh/bundle.nshc
echo "$root/experiments/mobile-nsh/ui/build/nsh"
