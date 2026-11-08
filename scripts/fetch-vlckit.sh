#!/usr/bin/env bash
# Downloads VideoLAN's prebuilt MobileVLCKit (what Streamora's CocoaPods setup used) into Vendor/.
# Runs in CI only (233 MB); the result is cached by actions/cache.
set -euo pipefail
VERSION="3.7.5-a213fd11-6de05adc"
URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-${VERSION}.tar.xz"
SHA256="a76f7a6cfcde4209b56f943e6e18400659d8a7a93ff482f8b1d059468d11e6be"
DEST="Vendor/MobileVLCKit.xcframework"

if [ -d "$DEST" ]; then
  echo "MobileVLCKit cached"
else
  tmp=$(mktemp -d)
  curl -fsSL "$URL" -o "$tmp/vlc.tar.xz"
  echo "$SHA256  $tmp/vlc.tar.xz" | shasum -a 256 -c -
  tar -xf "$tmp/vlc.tar.xz" -C "$tmp"
  src=$(find "$tmp" -type d -name "MobileVLCKit.xcframework" | head -1)
  [ -n "$src" ] || { echo "MobileVLCKit.xcframework not found in archive"; find "$tmp" -maxdepth 3; exit 1; }
  mkdir -p Vendor
  mv "$src" "$DEST"
  rm -rf "$tmp"
fi
ls "$DEST"
for bin in "$DEST"/*/MobileVLCKit.framework/MobileVLCKit; do
  echo "$bin: $(file -b "$bin" | head -c 160)"
done
