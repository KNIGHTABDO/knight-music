#!/usr/bin/env bash
# Usage: screens.sh <path/to/KnightMusic.app> <outdir>
# Boots one iPhone and one iPad simulator, launches the app in demo mode on each screen
# (launch args: -KMDemo YES -KMScreen <name>) and saves PNG screenshots.
# Add a screen: append its name to SCREENS and handle it in DebugLaunch.swift.
set -uo pipefail
APP="$1"; OUT="$2"; mkdir -p "$OUT"
BUNDLE=com.knightabdo.knightmusic
SCREENS=(home search artists albums songs playlists album artist player lyrics queue settings server downloads onboarding knight)


pick() { xcrun simctl list devices available -j | python3 -c "
import json,sys,re
d=json.load(sys.stdin)['devices']
c=[x for k,v in d.items() if 'iOS' in k for x in v if re.search(sys.argv[1],x['name'])]
c.sort(key=lambda x:x['name']); print(c[-1]['udid'] if c else '')" "$1"; }

run_device() {
  local label="$1" udid="$2"
  [ -z "$udid" ] && { echo "no simulator for $label"; return; }
  xcrun simctl boot "$udid" 2>/dev/null; xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl ui "$udid" appearance dark
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 2>/dev/null
  xcrun simctl install "$udid" "$APP"
  # first launch: let the demo login + library sync finish
  xcrun simctl launch "$udid" $BUNDLE -KMDemo YES -KMScreen home >/dev/null; sleep 40
  for s in "${SCREENS[@]}"; do
    xcrun simctl terminate "$udid" $BUNDLE 2>/dev/null
    xcrun simctl launch "$udid" $BUNDLE -KMDemo YES -KMScreen "$s" >/dev/null
    sleep 9
    xcrun simctl io "$udid" screenshot "$OUT/${label}-${s}.png" >/dev/null 2>&1 && echo "shot $label-$s"
  done
  xcrun simctl spawn "$udid" log show --last 6m --predicate 'subsystem == "com.knightabdo.knightmusic"' --style compact > "$OUT/${label}-log.txt" 2>/dev/null || true
  xcrun simctl shutdown "$udid"
}

run_device iphone "$(pick '^iPhone \d+ Pro$')"
run_device ipad "$(pick '^iPad Pro 13')"
ls "$OUT"
