#!/usr/bin/env bash
# Downloads the pinned Native Shell embedding SDKs (iOS xcframework, Android aar) into
# the ignored vendor/nsh-embed/<version>/ and verifies the published SHA-256 checksums.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
version="${NSH_EMBED_VERSION:-v0.5.1}"
dest="$root/vendor/nsh-embed/$version"
mkdir -p "$dest"
for asset in nsh-embed-ios.zip nsh-embed-android.zip; do
  if [[ -f "$dest/$asset.ok" ]]; then continue; fi
  base="https://github.com/longbridge/nsh/releases/download/$version/$asset"
  curl --fail --location --silent --show-error -o "$dest/$asset" "$base"
  expected="$(curl --fail --location --silent --show-error "$base.sha256" | awk '{print $1}')"
  actual="$(shasum -a 256 "$dest/$asset" | awk '{print $1}')"
  if [[ "$expected" != "$actual" ]]; then rm -f "$dest/$asset"; echo "checksum mismatch for $asset" >&2; exit 1; fi
  rm -rf "$dest/${asset%.zip}" && mkdir -p "$dest/${asset%.zip}"
  unzip -q "$dest/$asset" -d "$dest/${asset%.zip}"
  rm -f "$dest/$asset"
  touch "$dest/$asset.ok"
done
echo "$dest"
