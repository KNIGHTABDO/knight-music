#!/usr/bin/env bash
# Usage: carplay-screens.sh <path/to/KnightMusic.app (ad-hoc signed, carplay entitlement)> <outdir>
# Opens the Simulator's CarPlay display, starts Knight Music in demo mode and screenshots each CarPlay screen
# (launch args: -KMDemo YES -KMCarPlayScreen <name>; the coordinator pushes that screen once CarPlay connects).
set -uo pipefail
APP="$1"; OUT="$2"; mkdir -p "$OUT"
BUNDLE=com.knightabdo.knightmusic
SCREENS=(listen library playlists downloads albums artists album artist playlist nowplaying upnext)
# CarPlay home grid cell (0-based, row-major, 4 columns) holding Knight Music; override with KM_CP_ICON.
ICON=${KM_CP_ICON:-4}

UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys,re
d=json.load(sys.stdin)['devices']
c=[x for k,v in d.items() if 'iOS' in k for x in v if re.search(r'^iPhone \d+ Pro$',x['name'])]
c.sort(key=lambda x:x['name']); print(c[-1]['udid'])")
xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance dark
xcrun simctl install "$UDID" "$APP"
open -a Simulator --args -CurrentDeviceUDID "$UDID"; sleep 12
osascript -e 'tell application "Simulator" to activate' \
  -e 'tell application "System Events" to tell process "Simulator" to click menu item "CarPlay" of menu 1 of menu item "External Displays" of menu 1 of menu bar item "I/O" of menu bar 1'
sleep 15

shot() { xcrun simctl io "$UDID" screenshot --display=external "$OUT/carplay-$1.png" >/dev/null 2>&1 && echo "shot carplay-$1"; }

# Click a point given in CarPlay display pixels (800x480) inside the Simulator's CarPlay window.
tap() {
  osascript - "$1" "$2" <<'OSA'
on run argv
  set px to (item 1 of argv) as number
  set py to (item 2 of argv) as number
  tell application "Simulator" to activate
  tell application "System Events" to tell process "Simulator"
    set w to first window whose name contains "CarPlay"
    set {wx, wy} to position of w
    set {ww, wh} to size of w
    set s to ww / 800
    set bar to wh - 480 * s
    click at {wx + px * s, wy + bar + py * s}
  end tell
end run
OSA
}

openApp() {
  local col=$((ICON % 4)) row=$((ICON / 4))
  local x=$((203 + col * 167)) y=$((100 + row * 190))
  tap 40 428; sleep 3          # dock home button
  tap "$x" "$y"
}

xcrun simctl launch "$UDID" $BUNDLE -KMDemo YES -KMScreen home >/dev/null; sleep 40   # demo login + sync
shot home
openApp; sleep 10; shot first
for s in "${SCREENS[@]}"; do
  xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null; sleep 2
  xcrun simctl launch "$UDID" $BUNDLE -KMDemo YES -KMScreen home -KMCarPlayScreen "$s" >/dev/null; sleep 8
  openApp; sleep 10
  shot "$s"
done
xcrun simctl spawn "$UDID" log show --last 10m --predicate 'subsystem == "com.knightabdo.knightmusic"' --style compact > "$OUT/carplay-log.txt" 2>/dev/null || true
ls "$OUT"
