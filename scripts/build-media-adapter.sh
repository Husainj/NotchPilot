#!/bin/bash
# Builds Vendor/mediaremote-adapter into a MediaRemoteAdapter.framework.
# The framework is loaded by /usr/bin/perl (which Apple allows to read
# now-playing info), never linked into the app itself.
# Usage: scripts/build-media-adapter.sh <output-dir>
set -euo pipefail
source "$(dirname "$0")/env.sh"

OUT="${1:?usage: build-media-adapter.sh <output-dir>}"
mkdir -p "$OUT" && OUT="$(cd "$OUT" && pwd)"
SRC="$ROOT/Vendor/mediaremote-adapter"
FW="$OUT/MediaRemoteAdapter.framework"
STAMP="$OUT/.MediaRemoteAdapter.stamp"

SOURCES=(src/adapter/env.m src/adapter/get.m src/adapter/globals.m src/adapter/keys.m
         src/adapter/now_playing.m src/adapter/repeat.m src/adapter/seek.m src/adapter/send.m
         src/adapter/shuffle.m src/adapter/speed.m src/adapter/stream.m src/adapter/test.m
         src/private/MediaRemote.m src/utility/Debounce.m src/utility/helpers.m)

# Skip rebuilding when sources haven't changed.
HASH="$(cd "$SRC" && cat "${SOURCES[@]}" include/*.h src/*/*.h | shasum | cut -d' ' -f1)"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$HASH" ]; then
    exit 0
fi

rm -rf "$FW"
mkdir -p "$FW/Versions/A/Resources"
(cd "$SRC" && xcrun clang -dynamiclib -fobjc-arc -fvisibility=default -O2 \
    -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -Iinclude -Isrc \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$FW/Versions/A/MediaRemoteAdapter" "${SOURCES[@]}")

cat > "$FW/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
  <key>CFBundleName</key><string>MediaRemoteAdapter</string>
  <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
</dict></plist>
PLIST
ln -s A "$FW/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$FW/Resources"
echo "$HASH" > "$STAMP"
echo "Built $FW"
