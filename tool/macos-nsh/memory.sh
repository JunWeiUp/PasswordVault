#!/usr/bin/env bash
# Samples the preview host's memory footprint per page while tests/memory.test.tsx
# runs on the yomado QA screen. Usage: bash tool/macos-nsh/memory.sh <seeded /tmp vault copy>
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
vault="$1"
rm -f /tmp/pv-nsh-mem-mark /tmp/pv-nsh-mem.csv
seed_backup=/tmp/pv-nsh-qa
( PV_QA_SCREEN="${PV_QA_SCREEN:-PasswordVault QA}" bash -c "
  rm -rf /tmp/pv-nsh-qa-mem-swap && mv $seed_backup /tmp/pv-nsh-qa-mem-swap && cp -R \"\$(dirname $vault)\" $seed_backup
  bash $root/tool/macos-nsh/gui.sh tests/memory.test.tsx; status=\$?
  rm -rf $seed_backup && mv /tmp/pv-nsh-qa-mem-swap $seed_backup; exit \$status" > /tmp/pv-nsh-mem-run.log 2>&1 ) &
runner=$!
while kill -0 "$runner" 2>/dev/null; do
  pid="$(pgrep -f 'macos-host|nsh-app-nsh-app-passwordvault-m' | head -1 || true)"
  if [[ -n "$pid" ]]; then
    fp="$(footprint "$pid" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]* [KMG]B\).*/\1/p' | head -1)"
    printf '%s,%s,%s\n' "$(date +%s)" "$pid" "$fp" >> /tmp/pv-nsh-mem.csv
  fi
  sleep 1
done
wait "$runner" || true
grep 'tests:\|✗' /tmp/pv-nsh-mem-run.log || true
cat /tmp/pv-nsh-mem.csv
