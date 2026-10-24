#!/usr/bin/env bash
# Runs every minute (knight-watchdog.timer). Escalates only after consecutive failures so a short blip
# doesn't bounce anything.
set -u
FUNNEL_URL="https://desktop-1rsqaqq.tail7d75d9.ts.net/ping"
WIFI_DEV="wlp3s0"
state=/run/knight-watchdog
mkdir -p "$state"

log() { logger -t knight-watchdog "$*"; }
count() { cat "$state/$1" 2>/dev/null || echo 0; }
bump() { echo $(( $(count "$1") + 1 )) > "$state/$1"; count "$1"; }
reset() { rm -f "$state/$1"; }

# Local services first: they don't depend on the network.
for pair in navidrome:4533/ping knight-automix:4534/; do
  unit=${pair%%:*}
  if ! curl -s -o /dev/null --max-time 8 "http://127.0.0.1:${pair#*:}"; then
    if (( $(bump "$unit") >= 2 )); then
      log "$unit not answering, restarting"
      systemctl restart "$unit"; reset "$unit"
    fi
  else
    reset "$unit"
  fi
done

online() { ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; }

if ! online; then
  n=$(bump internet)
  gateway=$(ip route show default dev "$WIFI_DEV" 2>/dev/null | awk '{print $3; exit}')
  if [[ -n $gateway ]] && ping -c1 -W3 "$gateway" >/dev/null 2>&1; then
    # Router reachable but no internet: the ISP is down, nothing on this machine can fix that.
    (( n == 1 || n % 10 == 0 )) && log "internet down upstream (router $gateway answers), waiting"
    exit 0
  fi
  if (( n == 2 )); then
    log "Wi-Fi link lost, reconnecting"
    nmcli device connect "$WIFI_DEV" >/dev/null 2>&1
  elif (( n >= 4 && n % 4 == 0 )); then
    log "Wi-Fi still down, cycling the radio"
    nmcli radio wifi off; sleep 3; nmcli radio wifi on
    sleep 10; nmcli device connect "$WIFI_DEV" >/dev/null 2>&1
  fi
  exit 0
fi
[[ $(count internet) -gt 0 ]] && log "internet back after $(count internet) min"
reset internet

if curl -s -o /dev/null -f --max-time 15 "$FUNNEL_URL"; then
  reset funnel
  exit 0
fi
n=$(bump funnel)
if (( n == 3 || (n > 3 && n % 10 == 0) )); then
  log "Funnel unreachable with internet up (attempt $n), restarting tailscaled"
  systemctl restart tailscaled
fi
