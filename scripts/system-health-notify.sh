#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${HOME}/.local/state/system-health"
STATUS="${STATE_DIR}/status.json"
LAST="${STATE_DIR}/.last_state"

# derive discrete state from t_eff (match your governor thresholds)
get_state() {
  local t="$1"
  if   (( $(printf "%.0f" "$t") >= 78 )); then echo "hot"
  elif (( $(printf "%.0f" "$t") >= 64 )); then echo "warm"
  else echo "cool"
  fi
}

[[ -f "${STATUS}" ]] || exit 0
t_eff=$(jq -r '.t_eff // empty' "${STATUS}") || true
[[ -n "${t_eff}" ]] || exit 0

now_state=$(get_state "${t_eff}")
prev_state=""

[[ -f "${LAST}" ]] && prev_state="$(cat "${LAST}" || true)"
echo "${now_state}" > "${LAST}.tmp"
mv -f "${LAST}.tmp}" "${LAST}" 2>/dev/null || mv -f "${LAST}.tmp" "${LAST}"

# Only notify on change
if [[ "${now_state}" != "${prev_state}" ]]; then
  # Fan snapshot (optional pretties)
  fan="$(tempctl status 2>/dev/null | awk -F'fan: ' 'NF>1{print $2; exit}')"
  notify-send "System-Health: ${now_state^^}" "t_eff=${t_eff}°C${fan:+ | $fan}"
fi
