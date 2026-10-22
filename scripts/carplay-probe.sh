#!/usr/bin/env bash
set -x
OUT="$1"; mkdir -p "$OUT"
XC=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1); [ -n "$XC" ] && sudo xcode-select -s "$XC"
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys,re
d=json.load(sys.stdin)['devices']
c=[x for k,v in d.items() if 'iOS' in k for x in v if re.search(r'^iPhone \d+ Pro$',x['name'])]
c.sort(key=lambda x:x['name']); print(c[-1]['udid'])")
xcrun simctl boot "$UDID"; xcrun simctl bootstatus "$UDID" -b >/dev/null
open -a Simulator --args -CurrentDeviceUDID "$UDID"; sleep 15
screencapture -x "$OUT/desktop-0.png"
osascript -e 'tell application "System Events" to tell process "Simulator" to get name of every menu bar item of menu bar 1' > "$OUT/menus.txt" 2>&1
osascript -e 'tell application "System Events" to tell process "Simulator" to get name of every menu item of menu 1 of menu bar item "I/O" of menu bar 1' >> "$OUT/menus.txt" 2>&1
osascript -e 'tell application "System Events" to tell process "Simulator" to get name of every menu item of menu 1 of menu item "External Displays" of menu 1 of menu bar item "I/O" of menu bar 1' >> "$OUT/menus.txt" 2>&1
osascript -e 'tell application "Simulator" to activate' -e 'tell application "System Events" to tell process "Simulator" to click menu item "CarPlay" of menu 1 of menu item "External Displays" of menu 1 of menu bar item "I/O" of menu bar 1' >> "$OUT/menus.txt" 2>&1
sleep 20
screencapture -x "$OUT/desktop-1.png"
xcrun simctl io "$UDID" screenshot --display=external "$OUT/carplay-1.png" >> "$OUT/menus.txt" 2>&1
osascript -e 'tell application "System Events" to tell process "Simulator" to get {name, position, size} of every window' >> "$OUT/menus.txt" 2>&1
xcrun simctl io "$UDID" enumerate >> "$OUT/menus.txt" 2>&1
cat "$OUT/menus.txt"
# probe
