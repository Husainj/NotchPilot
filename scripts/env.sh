# Shared setup for build scripts: prefer full Xcode when installed.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
SWIFT_FLAGS=(--disable-keychain --package-path "$ROOT")
# The app's name and executable come from Info.plist, so renaming happens there.
APP_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$ROOT/Resources/Info.plist")"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$ROOT/Resources/Info.plist")"
