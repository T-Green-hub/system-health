cat > ~/.local/bin/system-health-governor-metrics.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${HOME}/.local/state/system-health"
METRICS_DIR="${STATE_DIR}/metrics"
STATUS="${STATE_DIR}/status.json"
OUT="${METRICS_DIR}/governor.prom"

mkdir -p "${METRICS_DIR}"

# Defaults
t_eff=""; cpu=""; gpu=""; nvme=""
mode=""; level=""; enabled=""
level_num="NaN"

# Read temps from status.json if present
if [[ -f "${STATUS}" ]]; then
  # Use jq only if JSON is non-empty and valid
  if [[ -s "${STATUS}" ]]; then
    t_eff=$(jq -r '(.t_eff // empty)' "${STATUS}" 2>/dev/null || true)
    cpu=$(jq -r '(.temps.cpu // empty)' "${STATUS}" 2>/dev/null || true)
    gpu=$(jq -r '(.temps.gpu // empty)' "${STATUS}" 2>/dev/null || true)
    nvme=$(jq -r '(.temps.nvme // empty)' "${STATUS}" 2>/dev/null || true)
  fi
fi

# Scrape `tempctl status` for fan state; tolerate absence
# Expected line example:
#   fan: mode=thinkpad_acpi level=auto status=enabled
if command -v tempctl >/dev/null 2>&1; then
  # Read all lines safely
  mapfile -t lines < <(tempctl status 2>/dev/null || true)
  for l in "${lines[@]}"; do
    if [[ "${l}" =~ fan:\ mode=([^[:space:]]+)\ level=([^[:space:]]+)\ status=([^[:space:]]+) ]]; then
      mode="${BASH_REMATCH[1]}"
      level="${BASH_REMATCH[2]}"
      enabled="${BASH_REMATCH[3]}"
      break
    fi
  done
fi

# numeric helper (Prometheus accepts NaN)
num() {
  local v="${1:-}"
  if [[ -n "$v" && "$v" != "null" ]]; then
    printf "%s" "$v"
  else
    printf "NaN"
  fi
}

# If level is a number 0..7, expose as gauge; if it's "auto" or "full-speed", keep NaN.
case "${level}" in
  0|1|2|3|4|5|6|7) level_num="${level}";;
esac

# Write atomically
tmp="${OUT}.tmp"
{
  echo "# HELP system_health_effective_hottest_temp_c Effective hottest temperature (C)."
  echo "# TYPE system_health_effective_hottest_temp_c gauge"
  printf "system_health_effective_hottest_temp_c %s\n" "$(num "${t_eff}")"

  echo "# HELP system_health_cpu_temp_c CPU temperature (C)."
  echo "# TYPE system_health_cpu_temp_c gauge"
  printf "system_health_cpu_temp_c %s\n" "$(num "${cpu}")"

  echo "# HELP system_health_gpu_temp_c GPU temperature (C) if present."
  echo "# TYPE system_health_gpu_temp_c gauge"
  printf "system_health_gpu_temp_c %s\n" "$(num "${gpu}")"

  echo "# HELP system_health_nvme_temp_c NVMe temperature (C) if present."
  echo "# TYPE system_health_nvme_temp_c gauge"
  printf "system_health_nvme_temp_c %s\n" "$(num "${nvme}")"

  echo "# HELP system_health_fan_level Fan level if numeric (0-7); NaN if auto/full-speed."
  echo "# TYPE system_health_fan_level gauge"
  printf "system_health_fan_level %s\n" "${level_num}"

  echo "# HELP system_health_governor_state Labeled info about fan governor state."
  echo "# TYPE system_health_governor_state gauge"
  printf 'system_health_governor_state{mode="%s",level="%s",status="%s"} 1\n' "${mode:-}" "${level:-}" "${enabled:-}"

  echo "# HELP system_health_metrics_generated_seconds Unix time when this file was written."
  echo "# TYPE system_health_metrics_generated_seconds gauge"
  date +%s | awk '{print "system_health_metrics_generated_seconds "$1}'
} > "${tmp}"

mv -f "${tmp}" "${OUT}"
EOF

chmod +x ~/.local/bin/system-health-governor-metrics.sh
