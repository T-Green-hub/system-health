
## Metrics exporter (textfile)
- Single-writer rule: only `system-health-governor-metrics.service` writes `/var/lib/node_exporter/textfile_collector/system_health.prom`.
- Disable legacy timers/services: `system-health-exporter.timer/service`, `system-health-governor-metrics.timer`.
- Script emits only numeric samples (skips missing) to avoid NaN/0 placeholders.

# System-Health Fan Governor (ThinkPad)

Minimal, hardened fan governor + sensors pipeline for ThinkPads on Linux.

## Components
- `sensors_reader.py` → writes `~/.local/state/system-health/status.json` (5s)
- `tempmon-governor.sh` → hysteresis + dwell, AC/BAT-aware
- `tempctl.py` → holds (`tempctl hold 5 --minutes 10`) and `release`
- `system-health-exporter.sh` → Prometheus textfile (`/var/lib/node_exporter/textfile_collector/system_health.prom`)
- Units/timers: `system-health-sensors.timer`, `tempmon-governor.service`, watchdog, exporter timer

## Quick start
```bash
systemctl --user enable --now system-health-sensors.timer
systemctl --user enable --now tempmon-governor.service
systemctl --user enable --now tempmon-watchdog.timer
sudo systemctl enable --now system-health-exporter.timer
