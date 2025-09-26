#!/usr/bin/env bash
# Install/update Prometheus alert rules for System-Health. Idempotent.
# Updated: 2025-09-25 PT
set -euo pipefail
RULE_DIR="/etc/prometheus/rules"
RULE_FILE="${RULE_DIR}/system-health.rules.yml"

sudo mkdir -p "$RULE_DIR"
tmp="$(mktemp "${RULE_FILE}.tmp.XXXX")"
trap 'rm -f "$tmp"' EXIT

cat >"$tmp" <<'YAML'
groups:
  - name: system-health
    rules:
      - alert: SystemHealthExporterStale
        expr: time() - system_health_metrics_generated_seconds > 120
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "System-Health exporter appears stale"
          description: "No fresh write in >2m ({{ $value }}s since last). Check user service system-health-governor-metrics.service."
      - alert: SystemHealthHighTemperature
        expr: system_health_effective_hottest_temp_c > 85
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "High temperature (effective hottest > 85°C)"
          description: "Sustained hottest temp is {{ $value }}°C > 85°C for 5m. Investigate cooling/fan governor."
YAML

sudo mv -f "$tmp" "$RULE_FILE"
sudo systemctl reload prometheus || true
echo "[ok] Rules installed at $RULE_FILE and Prometheus reloaded."
