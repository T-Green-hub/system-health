#!/usr/bin/env bash
# System-Health — tempmon-governor.sh (upgraded)
# No sudo. Uses systemd+Polkit to start fan-apply@<level>.service.
set -euo pipefail

CFG_DIR="${HOME}/.config/system-health"
STATE_DIR="${HOME}/.local/state/system-health"
LOG_DIR="${HOME}/.local/share/system-health/logs"
STATUS_JSON="${STATE_DIR}/status.json"
HOLD_JSON="${STATE_DIR}/hold.json"
mkdir -p "$LOG_DIR"

log() { printf "%s %s\n" "$(date '+%F %T')" "$*" >> "${LOG_DIR}/governor.log"; }

get_conf() {
  local key="$1" file="${2}"
  grep -E "^\s*${key}\s*=" "$file" 2>/dev/null | tail -n1 | sed -E "s/^\s*${key}\s*=\s*//"
}

get_levels_block() {
  local file="$1"
  awk '
    /LEVELS="/ {inblock=1; next}
    inblock && /"/ {inblock=0; next}
    inblock {print}
  ' "$file" 2>/dev/null || true
}

parse_level_line() {
  local line="$1"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" || "$line" =~ ^# ]] && return 1
  local range="${line%%=*}"
  local lv="${line#*=}"
  local min="${range%%..*}"
  local max="${range##*..}"
  echo "$min $max $lv"
}

read_power() {
  if [[ -r /sys/class/power_supply/AC/online ]]; then
    [[ "$(cat /sys/class/power_supply/AC/online)" == "1" ]] && echo "AC" || echo "BAT"; return
  fi
  if command -v acpi >/dev/null 2>&1; then
    acpi -a | grep -q on-line && echo "AC" || echo "BAT"; return
  fi
  echo "UNKNOWN"
}

apply_level() {
  local level="$1"
  /bin/systemctl start "fan-apply@${level}.service"
  local rc=$?
  log "[apply] level=${level} rc=${rc}"
  return $rc
}

# Config defaults
dwell_secs="$(get_conf dwell_secs "${CFG_DIR}/governor.conf" || echo 8)"
hyst_deg="$(get_conf hyst_deg "${CFG_DIR}/governor.conf" || echo 3)"
warn="$(get_conf warn "${CFG_DIR}/governor.conf" || echo 75)"
hot="$(get_conf hot "${CFG_DIR}/governor.conf" || echo 85)"
critical="$(get_conf critical "${CFG_DIR}/governor.conf" || echo 95)"
brake_temp="$(get_conf brake_temp "${CFG_DIR}/governor.conf" || echo 85)"
brake_secs="$(get_conf brake_secs "${CFG_DIR}/governor.conf" || echo 60)"

power="$(read_power)"

# Build map (base + AC/BAT override)
base_block="$(get_levels_block "${CFG_DIR}/governor.conf" || true)"
ac_block=""; bat_block=""
if [[ "$power" == "AC" ]]; then
  ac_block="$(get_levels_block "${CFG_DIR}/governor.ac.conf" || true)"
elif [[ "$power" == "BAT" ]]; then
  bat_block="$(get_levels_block "${CFG_DIR}/governor.battery.conf" || true)"
fi
MAP_STR="${base_block}
${ac_block}
${bat_block}"

declare -a MAP
parse_map() {
  local IFS=$'\n'; MAP=()
  for line in $MAP_STR; do
    pline="$(parse_level_line "$line" || true)"
    [[ -z "$pline" ]] && continue
    MAP+=("$pline")
  done
}
parse_map

select_level() {
  local t="$1" lvl="auto"
  local entry
  for entry in "${MAP[@]}"; do
    read -r mn mx lv <<< "$entry"
    if (( $(printf "%.0f" "$t") >= mn && $(printf "%.0f" "$t") <= mx )); then
      lvl="$lv"; break
    fi
  done
  echo "$lvl"
}

hold_active=""; hold_until=0; hold_level=""
read_hold() {
  hold_active=""; hold_level=""; hold_until=0
  [[ -r "$HOLD_JSON" ]] || return 0
  local now epoch
  now="$(date +%s)"
  epoch="$(jq -r '.until // 0' "$HOLD_JSON" 2>/dev/null || echo 0)"
  lvl="$(jq -r '.level // empty' "$HOLD_JSON" 2>/dev/null || true)"
  if [[ -n "$lvl" && "$epoch" -gt "$now" ]]; then
    hold_active="1"; hold_level="$lvl"; hold_until="$epoch"
  fi
}

log "[governor] start (dwell=${dwell_secs}s, hyst=${hyst_deg}°C, power=${power})"

last_target=""; last_change_epoch=0; brake_until=0

while true; do
  if [[ ! -r "$STATUS_JSON" ]]; then
    log "[warn] missing $STATUS_JSON; sleeping"
    sleep 2; continue
  fi

  ts="$(date +%s)"
  t_eff="$(jq -r '.t_eff // empty' "$STATUS_JSON" 2>/dev/null || echo "")"
  state="$(jq -r '.state // empty' "$STATUS_JSON" 2>/dev/null || echo "")"

  if [[ -z "$t_eff" ]]; then
    log "[warn] no t_eff; setting auto"
    apply_level "auto" || true
    sleep 2; continue
  fi

  # Short "brake" window when crossing a high temp
  if (( ${t_eff%%.*} >= brake_temp  )); then
    brake_until=$(( ts + brake_secs ))
  fi

  if (( ts < brake_until )); then
    target="full-speed"
  else
    # dwell/hysteresis
    parse_map
    curr_target="$(select_level "$t_eff")"
    target="$curr_target"
    if [[ -n "$last_target" && "$last_target" != "$curr_target" ]]; then
      if (( ts - last_change_epoch < dwell_secs )); then
        target="$last_target"
      fi
    fi
  fi

  read_hold
  if [[ -n "$hold_active" && -n "$hold_level" ]]; then
    target="$hold_level"
  fi

  if [[ "$target" != "$last_target" ]]; then
    if apply_level "$target"; then
      log "[governor] t=${t_eff}°C state=${state} → ${target} (power=${power})"
      last_target="$target"; last_change_epoch="$ts"
    else
      log "[error] failed to apply level=${target}"
    fi
  else
    log "[governor] hb t=${t_eff}°C state=${state} hold=$([[ -n "$hold_active" ]] && echo yes || echo no) target=${target}"
  fi

  sleep 2
done
