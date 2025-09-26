# Alerts/AM Snapshot
- Alertmanager: systemd-managed, single-node (cluster.listen-address disabled)
- Default receiver: ntfy (webhook)
- Prom → AM: validated (AlwaysFiring / synthetic POST)
- Next actions: thresholds tune; templates; multi-receiver; Grafana wiring
