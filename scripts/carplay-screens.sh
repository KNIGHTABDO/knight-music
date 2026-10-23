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
# Real mouse events (CGEvent); System Events "click at" does not reach the CarPlay display as a touch.
CLICK="$OUT/.click"
cat > "$OUT/.click.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let a = CommandLine.arguments, p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(120_000)
}
SWIFT
swiftc -O "$OUT/.click.swift" -o "$CLICK" && rm "$OUT/.click.swift"

# Maps a point on the 800x480 CarPlay display to desktop coordinates. The window draws the display at half
# size inside a 27pt bezel, below a title bar (measured from carplay-desktop-before.png).
tap() {
  local geo; geo=$(osascript -e 'tell application "Simulator" to activate' \
    -e 'tell application "System Events" to tell process "Simulator"' \
    -e 'set w to first window whose name contains "CarPlay"' \
    -e 'perform action "AXRaise" of w' \
    -e 'get {position, size} of w' -e 'end tell')
  local wx wy ww; IFS=', ' read -r wx wy ww _ <<<"$geo"
  # A click on a window that isn't key only focuses it; click the title bar first so the real tap lands.
  "$CLICK" "$(echo "$wx + $ww / 2" | bc -l)" "$((wy + 12))"; sleep 0.5
  local s cx cy
  s=$(echo "($ww - 54) / 800" | bc -l)
  cx=$(echo "$wx + 27 + $1 * $s" | bc -l); cy=$(echo "$wy + 60 + $2 * $s" | bc -l)
  echo "tap $1,$2 to $cx,$cy win $geo" >> "$OUT/carplay-taps.txt"
  "$CLICK" "$cx" "$cy"
}

openApp() {
  local col=$((ICON % 4)) row=$((ICON / 4))
  local x=$((200 + col * 167)) y=$((98 + row * 186))
  tap 52 428; sleep 3          # dock home button
  tap "$x" "$y"
}

xcrun simctl launch "$UDID" $BUNDLE -KMDemo YES -KMScreen home >/dev/null; sleep 40   # demo login + sync
shot home
# Calibration evidence: window geometry + the whole desktop, before and after the icon tap.
osascript -e 'tell application "System Events" to tell process "Simulator" to get {name, position, size} of every window' > "$OUT/carplay-windows.txt" 2>&1
screencapture -x "$OUT/carplay-desktop-before.png" 2>/dev/null
openApp; sleep 10; shot first
screencapture -x "$OUT/carplay-desktop-after.png" 2>/dev/null
for s in "${SCREENS[@]}"; do
  xcrun simctl terminate "$UDID" $BUNDLE 2>/dev/null; sleep 2
  xcrun simctl launch "$UDID" $BUNDLE -KMDemo YES -KMScreen home -KMCarPlayScreen "$s" >/dev/null; sleep 8
  openApp; sleep 10
  shot "$s"
  if [ "$s" = nowplaying ]; then
    sleep 20; shot nowplaying-late
    tap 52 428; sleep 3; tap 367 98; sleep 6; shot system-nowplaying   # CarPlay's own Now Playing app
  fi
done
xcrun simctl spawn "$UDID" log show --last 10m --predicate 'subsystem == "com.knightabdo.knightmusic"' --style compact > "$OUT/carplay-log.txt" 2>/dev/null || true
xcrun simctl spawn "$UDID" log show --last 10m --predicate 'process == "SpringBoard" AND (messageType == error OR messageType == fault OR eventMessage CONTAINS[c] "carplay" OR eventMessage CONTAINS[c] "KnightMusic")' --style compact 2>/dev/null | tail -400 > "$OUT/carplay-springboard-log.txt" || true
mkdir -p "$OUT/crashes"
find ~/Library/Logs/DiagnosticReports -mmin -30 \( -name 'SpringBoard*' -o -name 'KnightMusic*' -o -name 'CarPlay*' \) -exec cp {} "$OUT/crashes/" \; 2>/dev/null || true
ls "$OUT"
