#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${HOME}/.local/state/system-health"
METRICS_DIR="${STATE_DIR}/metrics"
STATUS="${STATE_DIR}/status.json"
OUT="${METRICS_DIR}/governor.prom"

mkdir -p "${METRICS_DIR}"

# Defaults if status.json missing
t_eff=""
cpu=""
gpu=""
nvme=""
level=""; mode=""; enabled=""

if [[ -f "${STATUS}" ]]; then
  # Pull core fields (jq is a dependency you already have)
  t_eff=$(jq -r '.t_eff // empty' "${STATUS}")
  cpu=$(jq -r '.temps.cpu // empty' "${STATUS}")
  gpu=$(jq -r '.temps.gpu // empty' "${STATUS}")
  nvme=$(jq -r '.temps.nvme // empty' "${STATUS}")
  # Ask tempctl for fan snapshot (or read your status if you embed level there)
  mapfile -t lines < <(tempctl status 2>/dev/null || true)
  # Parse quick-and-dirty
  # Example lines you showed:
  # fan: mode=thinkpad_acpi level=auto status=enabled
  for l in "${lines[@]}"; do
    if [[ "${l}" =~ fan:\ mode=([^[:space:]]+)\ level=([^[:space:]]+)\ status=([^[:space:]]+) ]]; then
      mode="${BASH_REMATCH[1]}"
      level="${BASH_REMATCH[2]}"
      enabled="${BASH_REMATCH[3]}"
    fi
  done
fi

# Normalize numerics
num() { [[ -n "$1" ]] && [[ "$1" != "null" ]] && printf "%s" "$1" || printf "NaN"; }

# Convert level tags to numeric buckets when possible (auto/full-speed -> NaN)
level_num="NaN"
case "${level}" in
  0|1|2|3|4|5|6|7) level_num="${level}";;
esac

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

  echo "# HELP system_health_fan_level Fan level if numeric (0-7), NaN if auto/full-speed."
  echo "# TYPE system_health_fan_level gauge"
  printf "system_health_fan_level %s\n" "${level_num}"

  echo "# HELP system_health_fan_info Labeled info about fan state."
  echo "# TYPE system_health_fan_info gauge"
  printf 'system_health_fan_info{mode="%s",level="%s",status="%s"} 1\n' "${mode:-}" "${level:-}" "${enabled:-}"

  echo "# HELP system_health_metrics_generated_seconds Unix time when this file was written."
  echo "# TYPE system_health_metrics_generated_seconds gauge"
  date +%s | awk '{print "system_health_metrics_generated_seconds "$1}'
} > "${OUT}.tmp"

mv -f "${OUT}.tmp" "${OUT}"
