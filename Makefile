PREFIX := $(HOME)
USR_BIN := $(PREFIX)/.local/bin
USR_UNITS := $(PREFIX)/.config/systemd/user

install-metrics:
	mkdir -p $(USR_BIN) $(USR_UNITS)
	install -m 0755 scripts/system-health-metrics.sh $(USR_BIN)/system-health-metrics.sh
	install -m 0644 units/system-health-sensors.service $(USR_UNITS)/
	install -m 0644 units/system-health-governor-metrics.service $(USR_UNITS)/
	systemctl --user daemon-reload
	systemctl --user enable --now system-health-sensors.service
	systemctl --user enable --now system-health-governor-metrics.service
	@echo "Waiting for metrics…"; sleep 2
	@sed -n '1,40p' /var/lib/node_exporter/textfile_collector/system_health.prom || true

.PHONY: install-metrics
