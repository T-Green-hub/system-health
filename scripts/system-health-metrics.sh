#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="${HOME}/.local/state/system-health"
STATUS_JSON="${STATE_DIR}/status.json"
OUT_DIR="/var/lib/node_exporter/textfile_collector"
OUT_FILE="${OUT_DIR}/system_health.prom"

jqr(){ jq -r "$1 // empty" 2>/dev/null || true; }
emit(){ local n="$1" v="$2" h="$3" t="$4"; [[ -n "${h:-}" ]]&&printf "# HELP %s %s\n" "$n" "$h"; [[ -n "${t:-}" ]]&&printf "# TYPE %s %s\n" "$n" "$t"; printf "%s %s\n" "$n" "$v"; }

read_load(){ read -r L1 L5 L15 _ < /proc/loadavg; echo "$L1" "$L5" "$L15"; }
read_mem_used_pct(){ local M=$(awk '/^MemTotal:/{print $2}' /proc/meminfo); local A=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo); [[ -n "$M" && -n "$A" ]] && awk -v M="$M" -v A="$A" 'BEGIN{printf("%.0f",(100.0*(M-A)/M))}' || free | awk '/Mem:/{printf("%.0f",100.0*$3/$2)}'; }
read_cpu_freq_avg_mhz(){ local sum=0 n=0 v; for p in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do [[ -r "$p" ]]||continue; v=$(<"$p"); [[ -n "$v" ]]||continue; sum=$((sum+v)); n=$((n+1)); done; ((n>0)) && awk -v s="$sum" -v n="$n" 'BEGIN{printf("%.0f",(s/n)/1000.0)}'; }
read_power(){ for b in /sys/class/power_supply/AC /sys/class/power_supply/ACAD /sys/class/power_supply/AC0 /sys/class/power_supply/AC1; do [[ -r "$b/online" ]] && { [[ "$(cat "$b/online")" == "1" ]] && echo 1 || echo 0; return; }; done; }
read_batt_state(){ for b in /sys/class/power_supply/BAT*; do [[ -r "$b/status" ]] && { cat "$b/status"; return; }; done; }
read_batt_capacity(){ for b in /sys/class/power_supply/BAT*; do [[ -r "$b/capacity" ]] && { cat "$b/capacity"; return; }; done; }
read_fan_rpm(){ [[ -r /proc/acpi/ibm/fan ]] && { awk '/speed:/{print $2}' /proc/acpi/ibm/fan; return; }; for s in /sys/class/hwmon/hwmon*/fan*_input; do [[ -r "$s" ]] && { cat "$s"; return; }; done; }

write_metrics_once(){
  umask 022; mkdir -p "$OUT_DIR"
  local epoch cpu nvme gpu t_eff state fan_level fan_mode l1 l5 l15 mem freq ac bst bpct rpm
  epoch="$(date +%s)"
  if [[ -r "$STATUS_JSON" ]]; then
    cpu="$(jqr '.temps.cpu' <"$STATUS_JSON")"
    nvme="$(jqr '.temps.nvme' <"$STATUS_JSON")"
    gpu="$(jqr '.temps.gpu' <"$STATUS_JSON")"
    t_eff="$(jqr '.t_eff' <"$STATUS_JSON")"
    state="$(jqr '.state' <"$STATUS_JSON")"
    fan_level="$(jqr '.fan.level' <"$STATUS_JSON")"
    fan_mode="$(jqr '.fan.mode' <"$STATUS_JSON")"
  fi
  read -r l1 l5 l15 < <(read_load)
  mem="$(read_mem_used_pct)"; freq="$(read_cpu_freq_avg_mhz)"; ac="$(read_power)"
  bst="$(read_batt_state)"; bpct="$(read_batt_capacity)"; rpm="$(read_fan_rpm)"

  {
    emit system_health_up 1 "1 if metrics script ran" gauge
    emit system_health_metrics_generated_seconds "$epoch" "Unix time the metrics were generated" gauge
    [[ -n "$t_eff" ]] && emit system_health_effective_hottest_temp_c "$t_eff" "Effective hottest temperature across sensors" gauge
    [[ -n "$cpu"   ]] && emit system_health_cpu_package_temp_c "$cpu" "CPU package temperature in Celsius (best-effort)" gauge
    [[ -n "$nvme"  ]] && emit system_health_nvme_temp_c "$nvme" "NVMe temperature in Celsius (best-effort)" gauge
    [[ -n "$gpu"   ]] && emit system_health_gpu_temp_c "$gpu" "GPU temperature in Celsius (best-effort)" gauge
    [[ -n "$rpm"   ]] && emit system_health_fan_rpm "$rpm" "Fan speed in RPM" gauge
    printf "# HELP system_health_fan_info Fan level/state labels\n# TYPE system_health_fan_info gauge\n"
    printf 'system_health_fan_info{mode="%s",state="%s"} 1\n' "${fan_mode:- }" "${state:-unknown}"
    [[ -n "$freq"  ]] && emit system_health_cpu_freq_avg_mhz "$freq" "Average CPU frequency across online cores (MHz)" gauge
    [[ -n "$l1"    ]] && emit system_health_load1 "$l1" "System load average over 1 minute" gauge
    [[ -n "$l5"    ]] && emit system_health_load5 "$l5" "System load average over 5 minutes" gauge
    [[ -n "$l15"   ]] && emit system_health_load15 "$l15" "System load average over 15 minutes" gauge
    [[ -n "$mem"   ]] && emit system_health_memory_used_percent "$mem" "Memory used percentage" gauge
    [[ -n "$ac"    ]] && emit system_health_power_ac_online "$ac" "1 if AC power is online, else 0" gauge
    if [[ -n "$bst" ]]; then
      printf "# HELP system_health_power_info Battery state label\n# TYPE system_health_power_info gauge\n"
      printf 'system_health_power_info{battery_state="%s"} 1\n' "$bst"
    fi
    [[ -n "$bpct"  ]] && emit system_health_battery_capacity_percent "$bpct" "Battery capacity percentage" gauge
  } > "${OUT_FILE}.tmp"
  mv "${OUT_FILE}.tmp" "$OUT_FILE"
}

if [[ "${1:-}" == "--loop" ]]; then
  interval="${2:-5}"
  while true; do write_metrics_once || true; sleep "$interval"; done
else
  write_metrics_once
fi
