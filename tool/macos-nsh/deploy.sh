#!/usr/bin/env bash
# Fast local deployment of PasswordVault to /Applications/PasswordVault.app.
#
# Modes:
#   --auto (default): uses --ui-only (~3-5s) when Rust sources/manifests match the
#                     installed app fingerprint; otherwise runs --full.
#   --ui-only:        rebuilds only QuickJS bytecode (bundle.nshc), replaces it in
#                     /Applications/PasswordVault.app, re-signs the outer bundle,
#                     and relaunches PasswordVault (never touches pv-background or
#                     vault data).
#   --full:           packages signed app + helpers, stops PasswordVault & helpers,
#                     takes a hardlink-accelerated backup under private/archive/,
#                     installs, verifies SHA-256 + codesign + pv-mcp tools/list,
#                     prunes old deploy-* backups (keeps latest 5 by default),
#                     and launches.
#
# Options:
#   --no-launch        do not open /Applications/PasswordVault.app afterwards
#   --refresh-signing  force rebuilding cached Xcode provisioning profile
#   --force-helpers    force rebuilding pv-mcp / pv-browser-host / pv-background
#
# Environment:
#   PV_DEPLOY_KEEP_BACKUPS  number of recent deploy-* backups to keep (default: 5; 0 disables pruning)
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
mode="auto"
launch=1
keep_backups="${PV_DEPLOY_KEEP_BACKUPS:-5}"
if ! [[ "$keep_backups" =~ ^[0-9]+$ ]]; then
  echo "invalid PV_DEPLOY_KEEP_BACKUPS (expected non-negative integer): $keep_backups" >&2
  exit 2
fi
for arg in "$@"; do
  case "$arg" in
    --auto) mode="auto" ;;
    --ui-only) mode="ui" ;;
    --full) mode="full" ;;
    --no-launch) launch=0 ;;
    --refresh-signing) export PV_REFRESH_SIGNING=1 ;;
    --force-helpers) export PV_FORCE_HELPERS=1 ;;
    -h|--help)
      sed -n '2,23p' "$0"
      exit 0
      ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

app_dst="/Applications/PasswordVault.app"
cache_dir="$root/private/signing/macos/.cache"
mkdir -p "$cache_dir"
chmod 700 "$cache_dir"
fp_file="$cache_dir/installed-rust.sha256"

rust_fingerprint() {
  python3 - "$root" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
h = hashlib.sha256()
roots = [
    root / "crates/vault-core/src",
    root / "crates/vault-core/Cargo.toml",
    root / "apps/desktop/src",
    root / "apps/desktop/helpers",
    root / "apps/desktop/Cargo.toml",
    root / "apps/desktop/Cargo.lock",
    root / "apps/desktop/nsh.json",
    root / "apps/browser/identity.json",
    root / "assets/branding",
]
files = []
for p in roots:
    if p.is_file():
        files.append(p)
    elif p.is_dir():
        for f in sorted(p.rglob("*")):
            if f.is_file() and ".nsh" not in f.parts and "target" not in f.parts:
                files.append(f)
for f in sorted(set(files)):
    rel = f.relative_to(root).as_posix()
    h.update(rel.encode("utf-8"))
    h.update(b"\0")
    h.update(f.read_bytes())
    h.update(b"\0")
print(h.hexdigest())
PY
}

current_fp="$(rust_fingerprint)"
if [[ "$mode" == "auto" ]]; then
  if [[ -f "$app_dst/Contents/Resources/nsh/bundle.nshc" ]] \
    && [[ -f "$fp_file" ]] \
    && [[ "$(cat "$fp_file")" == "$current_fp" ]]; then
    mode="ui"
  else
    mode="full"
  fi
fi

t0="$(python3 -c 'import time; print(f"{time.monotonic():.3f}")')"
source "$root/tool/macos-nsh/signing-cache.sh"
ensure_signing_cache

if [[ "$mode" == "ui" ]]; then
  if [[ ! -f "$app_dst/Contents/Resources/nsh/bundle.nshc" ]]; then
    echo "UI-only deploy requires an existing installed $app_dst; run with --full first." >&2
    exit 1
  fi
  echo "[deploy] mode=ui-only (Rust fingerprint unchanged — fast QuickJS bundle swap)"
  out_tmp="/tmp/pv-nsh-ui-bundle-$$"
  trap 'rm -rf "$out_tmp"' EXIT
  rm -rf "$out_tmp"
  bash "$root/tool/nsh_mac.sh" build App.tsx --release -o "$out_tmp"
  [[ -f "$out_tmp/bundle.nshc" ]] || { echo "missing built bundle.nshc" >&2; exit 1; }

  # Quit only the UI process; pv-background & pv-mcp keep running safely.
  osascript -e 'tell application "PasswordVault" to quit' 2>/dev/null || true
  for _ in 1 2 3 4 5 6; do
    if ! pgrep -f "/Applications/PasswordVault\.app/Contents/MacOS/PasswordVault" >/dev/null; then
      break
    fi
    sleep 0.25
  done
  pkill -TERM -f "/Applications/PasswordVault\.app/Contents/MacOS/PasswordVault" 2>/dev/null || true

  cp "$out_tmp/bundle.nshc" "$app_dst/Contents/Resources/nsh/bundle.nshc"
  cp "$out_tmp/capabilities.json" "$app_dst/Contents/Resources/nsh/capabilities.json"
  codesign --force --options runtime --timestamp=none \
    --entitlements "$PV_SIGN_ENTITLEMENTS" \
    --sign "$PV_SIGN_IDENTITY" "$app_dst"
  codesign --verify --deep --strict "$app_dst"
  if [[ "$launch" -eq 1 ]]; then
    open "$app_dst"
  fi
  elapsed="$(python3 -c "import time; print(f'{time.monotonic() - float($t0):.2f}s')")"
  echo "[deploy] ui-only complete in $elapsed (codesign strict OK)"
  exit 0
fi

echo "[deploy] mode=full (building signed package + helpers, backing up vault, installing)"
bash "$root/tool/macos-nsh/package.sh"

# Stop UI, background service, and browser host cleanly (leave external Codex pv-mcp shims alone).
osascript -e 'tell application "PasswordVault" to quit' 2>/dev/null || true
sleep 0.6
pkill -TERM -f "/Applications/PasswordVault.*\.app/Contents/MacOS/PasswordVault" 2>/dev/null || true
pkill -TERM -f "/Applications/PasswordVault.*\.app/Contents/Library/PasswordVault Background\.app/Contents/MacOS/pv-background" 2>/dev/null || true
pkill -TERM -f "/Applications/PasswordVault.*\.app/Contents/MacOS/pv-browser-host" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8; do
  if ! pgrep -f "/Applications/PasswordVault.*\.app/Contents/.*MacOS/(PasswordVault|pv-background|pv-browser-host)" >/dev/null; then
    break
  fi
  sleep 0.3
done

ts="$(date +%Y%m%d-%H%M%S)"
bk="private/archive/deploy-$ts"

# Find the most recent existing backup before creating $bk so --link-dest actually hits it.
prev_bk="$(find "$root/private/archive" -mindepth 2 -maxdepth 2 -type d -name PasswordVaultNative 2>/dev/null | grep -vxF "$root/$bk/PasswordVaultNative" | sort | tail -1 || true)"

mkdir -p "$root/$bk/browser-manifests" "$root/$bk/PasswordVaultNative"
chmod 700 "$root/$bk"

rsync_args=(-a --no-specials --no-devices)
if [[ -n "$prev_bk" && -d "$prev_bk" ]]; then
  rsync_args+=(--link-dest="$prev_bk")
fi
rsync "${rsync_args[@]}" "$HOME/Library/Application Support/PasswordVaultNative/" "$root/$bk/PasswordVaultNative/"

for b in "Google/Chrome" "Microsoft Edge" "Microsoft Edge Beta" "ego lite"; do
  f="$HOME/Library/Application Support/$b/NativeMessagingHosts/com.securepass.vault.native_v2.json"
  [[ -f "$f" ]] || continue
  safe="${b//\//_}"
  cp "$f" "$root/$bk/browser-manifests/${safe}.json"
done

(cd "$HOME/Library/Application Support/PasswordVaultNative" && find . -type f | sort | xargs shasum -a 256) > "$root/$bk/before.sha256"
bash "$root/tool/macos-nsh/install.sh" "$bk"
(cd "$HOME/Library/Application Support/PasswordVaultNative" && find . -type f | sort | xargs shasum -a 256) > "$root/$bk/after.sha256"
diff -u "$root/$bk/before.sha256" "$root/$bk/after.sha256" >/dev/null

codesign --verify --deep --strict "$app_dst"
printf '%s\n' "$current_fp" > "$fp_file"

# Quick protocol smoke on installed pv-mcp
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"deploy","version":"1"}}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n' \
  | "$app_dst/Contents/MacOS/pv-mcp" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    obj = json.loads(line)
    if obj.get("id") == 2:
        n = len(obj["result"]["tools"])
        print(f"[deploy] pv-mcp tools/list OK ({n} tools)")
'

if [[ "$keep_backups" -gt 0 ]]; then
  python3 - "$root/private/archive" "$(basename "$bk")" "$keep_backups" <<'PY'
import pathlib, re, shutil, sys

archive = pathlib.Path(sys.argv[1])
current = sys.argv[2]
keep = int(sys.argv[3])
pat = re.compile(r"^deploy-\d{8}-\d{6}$")

if archive.is_dir():
    backups = sorted(
        p for p in archive.iterdir()
        if p.is_dir() and not p.is_symlink() and pat.match(p.name)
    )
    stale = [p for p in backups[:-keep] if p.name != current]
    for p in stale:
        shutil.rmtree(p)
    if stale:
        print(f"[deploy] pruned {len(stale)} old deploy backup(s) (kept latest {keep})")
PY
fi

if [[ "$launch" -eq 1 ]]; then
  open "$app_dst"
fi
elapsed="$(python3 -c "import time; print(f'{time.monotonic() - float($t0):.2f}s')")"
echo "[deploy] full install complete in $elapsed (backup: $bk, vault hashes identical)"
