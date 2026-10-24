#!/usr/bin/env bash
# Keeps the Navidrome host reachable: no Wi-Fi power saving, no sleep, and a watchdog that repairs the
# Wi-Fi link, Tailscale Funnel and the music services on its own. Run once with: sudo bash install.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"

# Wi-Fi power save drops the ath10k link under load and after idle periods (2 = disabled).
printf '[connection]\nwifi.powersave = 2\n' > /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf

# Never suspend: closing the lid or idling must not take the server down.
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\nIdleAction=ignore\n' \
  > /etc/systemd/logind.conf.d/knight-always-on.conf
systemctl mask --quiet sleep.target suspend.target hibernate.target hybrid-sleep.target

# Services come back whatever way they die.
for unit in navidrome knight-automix tailscaled; do
  mkdir -p "/etc/systemd/system/$unit.service.d"
  printf '[Unit]\nStartLimitIntervalSec=0\n[Service]\nRestart=always\nRestartSec=5\n' \
    > "/etc/systemd/system/$unit.service.d/always-on.conf"
done

install -m 755 "$here/knight-watchdog.sh" /usr/local/bin/knight-watchdog
install -m 644 "$here/knight-watchdog.service" "$here/knight-watchdog.timer" /etc/systemd/system/

systemctl daemon-reload
systemctl reload NetworkManager
systemctl kill -s HUP systemd-logind || true
systemctl enable --now knight-watchdog.timer
echo "always-on installed; watchdog log: journalctl -t knight-watchdog"
