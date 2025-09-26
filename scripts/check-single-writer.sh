#!/usr/bin/env bash
# Enforce: single writer to system_health.prom + atomic tmp→mv pattern.
# Exit nonzero on violation. Updated: 2025-09-25 PT
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[check] exactly one writer of system_health.prom"
hits=$(grep -R --line-number --fixed-strings '/var/lib/node_exporter/textfile_collector/system_health.prom' "$ROOT" || true)
echo "$hits"
# Count ExecStart + direct writer references
count=$(printf "%s\n" "$hits" | grep -E 'ExecStart|system-health-metrics\.sh' | wc -l | tr -d ' ')
if [ "${count:-0}" -gt 1 ]; then
  echo "ERROR: More than one thing references system_health.prom"; exit 1
fi

echo "[check] exporter uses mktemp → mv (atomic)"
if ! grep -R -nE 'mktemp.+\.tmp' "$ROOT/scripts/system-health-metrics.sh" >/dev/null; then
  echo "ERROR: exporter missing mktemp temp file"; exit 1
fi
if ! grep -R -nE 'mv -f .+\.tmp' "$ROOT/scripts/system-health-metrics.sh" >/dev/null; then
  echo "ERROR: exporter missing atomic mv -f *.tmp → final"; exit 1
fi

echo "[ok] single-writer + atomic write verified"
