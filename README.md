# System-Health (fan governor + sensors)

A lightweight, user-space thermal and fan-governor setup for Linux laptops (tested on ThinkPad), with:
- Sensors reader → `status.json` + `history.csv`
- Fan governor with hysteresis/dwell and AC/Battery maps
- Watchdog timer to restart governor if status is stale
- Optional Argos topbar badge (GNOME)

## Quick start (user mode)

```bash
# Install prerequisites (Ubuntu/Debian)
sudo apt-get update
sudo apt-get install -y jq lm-sensors nvme-cli smartmontools

# Enable thinkpad_acpi fan control (ThinkPad)
sudo modprobe thinkpad_acpi fan_control=1
echo 'options thinkpad_acpi fan_control=1' | sudo tee /etc/modprobe.d/thinkpad_acpi.conf

# Install suite
./install.sh

# Status + control
tempctl status
tempctl hold 5 --minutes 10
tempctl release
