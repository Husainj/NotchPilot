#!/bin/bash
# Build <AppName>.app into ./build and sign it.
# Usage: scripts/bundle.sh [release|debug]
# Set SIGN_IDENTITY="Developer ID Application: …" once you have an Apple Developer account;
# the default "-" is an ad-hoc signature.
set -euo pipefail
source "$(dirname "$0")/env.sh"

CONFIG="${1:-release}"
IDENTITY="${SIGN_IDENTITY:--}"
# Debug builds: sign with a local "Apple Development" certificate when there
# is one. macOS keys permissions (Screen Recording, Accessibility…) to the
# signature; ad-hoc signatures change on every build, so permissions would
# reset each time. Override with DEV_SIGN_IDENTITY, or set it to "-" for ad-hoc.
DEV_SIGNING=0
if [ "$CONFIG" = "debug" ] && [ -z "${SIGN_IDENTITY:-}" ]; then
    IDENTITY="${DEV_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/"Apple Development/ {print $2; exit}')}"
    IDENTITY="${IDENTITY:--}"
    [ "$IDENTITY" != "-" ] && DEV_SIGNING=1
fi
APP="$ROOT/build/$APP_NAME.app"

swift build -c "$CONFIG" "${SWIFT_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${SWIFT_FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/NotchApp" "$APP/Contents/MacOS/$APP_EXECUTABLE"
# Drop build-machine rpaths (local .build and Xcode toolchain paths).
for rpath in $(otool -l "$APP/Contents/MacOS/$APP_EXECUTABLE" | awk '/LC_RPATH/{getline; getline; print $2}'); do
    case "$rpath" in
        "$ROOT"/*|/Applications/Xcode*|/Library/Developer/*) install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/$APP_EXECUTABLE" 2>/dev/null ;;
    esac
done
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# Now-playing helper for all apps (loaded by /usr/bin/perl, not linked).
"$ROOT/scripts/build-media-adapter.sh" "$ROOT/build"
ditto "$ROOT/build/MediaRemoteAdapter.framework" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
cp "$ROOT/Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp "$ROOT/Vendor/mediaremote-adapter/LICENSE" "$APP/Contents/Resources/mediaremote-adapter-LICENSE.txt"

# Sign inside-out: Sparkle's helpers, the framework, then the app.
SIGN_ARGS=(--force --sign "$IDENTITY")
# Hardened runtime only for distribution builds (it needs entitlements for the
# mic, camera and Apple Events, and notarization requires it).
if [ "$IDENTITY" != "-" ] && [ "$DEV_SIGNING" = "0" ]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/XPCServices/Downloader.xpc" \
            "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
    [ -e "$item" ] && codesign "${SIGN_ARGS[@]}" "$item"
done
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign "${SIGN_ARGS[@]}" "$APP"

codesign --verify --strict "$APP"
echo "Built $APP ($CONFIG, signed with: $IDENTITY)"
