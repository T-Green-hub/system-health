# Makefile — System Health (user services)
# Updated: 2025-09-25 PT

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

PREFIX          := $(HOME)
USR_BIN         := $(PREFIX)/.local/bin
USR_UNITS       := $(PREFIX)/.config/systemd/user
ENV_DIR         := $(PREFIX)/.config/environment.d
ENV_FILE        := $(ENV_DIR)/system-health.env

TEXTFILE_DIR    := /var/lib/node_exporter/textfile_collector
PROM_FILE       := $(TEXTFILE_DIR)/system_health.prom

SAFE_GREP := grep -E '^(system_health_(up|metrics_generated_seconds|effective_hottest_temp_c|cpu_(temp_c|package_temp_c|freq_avg_mhz)|nvme_temp_c|gpu_temp_c|fan_rpm|load1|load5|load15|memory_used_percent|power_ac_online|power_info|battery_capacity_percent))(\{|$$| )'

.PHONY: help
help:
	@echo "install-metrics   — Install script + user units; enable & start; print .prom"
	@echo "dropins-install   — Install hardening drop-ins from repo → user dir"
	@echo "env-install       — Create ~/.config/environment.d/system-health.env if missing"
	@echo "alerts-install    — Install Prometheus rules (uses sudo via script)"
	@echo "verify            — Single-writer + atomic write checks"
	@echo "metrics-grep      — Show key system_health_* samples from node_exporter"
	@echo "print-prom        — Show first 60 lines of $(PROM_FILE)"
	@echo "status            — systemctl --user status (writer + sensors)"
	@echo "restart           — Restart writer + sensors, then print .prom"
	@echo "uninstall-metrics — Stop/disable & remove installed copies (keeps repo)"

.PHONY: install-metrics
install-metrics:
	@echo "[install] create user dirs"
	mkdir -p $(USR_BIN) $(USR_UNITS)
	@echo "[install] exporter → $(USR_BIN)"
	install -m 0755 scripts/system-health-metrics.sh $(USR_BIN)/system-health-metrics.sh
	@echo "[install] units → $(USR_UNITS)"
	install -m 0644 units/system-health-sensors.service $(USR_UNITS)/
	install -m 0644 units/system-health-governor-metrics.service $(USR_UNITS)/
	@echo "[install] daemon-reload + enable + start"
	systemctl --user daemon-reload
	systemctl --user enable --now system-health-sensors.service
	systemctl --user enable --now system-health-governor-metrics.service
	@echo "[install] waiting for metrics…"; sleep 2
	$(MAKE) --no-print-directory print-prom

.PHONY: dropins-install
dropins-install:
	@echo "[dropins] installing service.d/* from repo"
	mkdir -p $(USR_UNITS)/system-health-governor-metrics.service.d
	install -m 0644 units/system-health-governor-metrics.service.d/20-hardening.conf \
		$(USR_UNITS)/system-health-governor-metrics.service.d/20-hardening.conf
	systemctl --user daemon-reload
	systemctl --user restart system-health-governor-metrics.service
	@echo "[dropins] applied."

.PHONY: env-install
env-install:
	@echo "[env] ensuring $(ENV_FILE) exists"
	mkdir -p $(ENV_DIR)
	@if [ ! -f "$(ENV_FILE)" ]; then \
	  printf '%s\n' \
	    '# System-Health metrics env (created by make env-install)' \
	    'NODE_EXPORTER_TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector' \
	    'PROM_FILE=/var/lib/node_exporter/textfile_collector/system_health.prom' \
	    'STATE_DIR=$(HOME)/.local/state/system-health' \
	    'EXPORTER_TIMEOUT=20' > "$(ENV_FILE)"; \
	  echo "[env] wrote $(ENV_FILE)"; \
	else echo "[env] $(ENV_FILE) already exists (left unchanged)"; fi
	systemctl --user daemon-reload
	systemctl --user restart system-health-governor-metrics.service || true

.PHONY: alerts-install
alerts-install:
	@echo "[alerts] installing Prometheus rules (sudo inside script)"
	@bash ./scripts/alerts-install.sh

.PHONY: verify
verify:
	@echo "[verify] single-writer + atomic"
	@if [ -x "./scripts/check-single-writer.sh" ]; then ./scripts/check-single-writer.sh ; else echo "scripts/check-single-writer.sh missing"; exit 1; fi

.PHONY: metrics-grep
metrics-grep:
	@curl -fsS http://localhost:9100/metrics | $(SAFE_GREP) | sed -n '1,80p' || true

.PHONY: print-prom
print-prom:
	@sed -n '1,60p' $(PROM_FILE) || (echo "No $(PROM_FILE) yet"; exit 0)

.PHONY: status
status:
	systemctl --user status --no-pager system-health-governor-metrics.service || true
	systemctl --user status --no-pager system-health-sensors.service || true

.PHONY: restart
restart:
	systemctl --user restart system-health-sensors.service
	systemctl --user restart system-health-governor-metrics.service
	sleep 2
	$(MAKE) --no-print-directory print-prom

.PHONY: uninstall-metrics
uninstall-metrics:
	-systemctl --user disable --now system-health-governor-metrics.service || true
	-systemctl --user disable --now system-health-sensors.service || true
	-rm -f $(USR_BIN)/system-health-metrics.sh
	-rm -f $(USR_UNITS)/system-health-governor-metrics.service
	-rm -f $(USR_UNITS)/system-health-sensors.service
	systemctl --user daemon-reload
	@echo "[uninstall] complete"
