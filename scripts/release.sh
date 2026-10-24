#!/bin/bash
# Build a release DMG, publish it on GitHub Releases, and add it to the Sparkle
# appcast in docs/appcast.xml (served by GitHub Pages). Everything is free.
# Usage: scripts/release.sh 1.1.0
#
# Needs:
#   release-notes/<version>.md    release notes (created for you on first run); shown on GitHub and in the update window
#   the Sparkle private key       in your Keychain (make sparkle-keys), or SPARKLE_PRIVATE_KEY in CI
# Optional:
#   GITHUB_REPO=owner/name        defaults to the "origin" remote
#   PUBLISH=0                     only build the DMG and update docs/appcast.xml; no git push, no GitHub release
#   SIGN_IDENTITY / NOTARY_PROFILE Developer ID signing + notarization, once you have an Apple Developer account
set -euo pipefail
source "$(dirname "$0")/env.sh"

VERSION="${1:?usage: scripts/release.sh <version>}"
PUBLISH="${PUBLISH:-1}"
PLIST="$ROOT/Resources/Info.plist"
NOTES="$ROOT/release-notes/$VERSION.md"
APPCAST="$ROOT/docs/appcast.xml"
RELEASES="$ROOT/releases"

if [ -z "${GITHUB_REPO:-}" ]; then
    ORIGIN="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
    GITHUB_REPO="$(printf '%s' "$ORIGIN" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
fi
[ -n "$GITHUB_REPO" ] || { echo "Set GITHUB_REPO=owner/name or add a GitHub 'origin' remote."; exit 1; }

if [ ! -f "$NOTES" ]; then
    mkdir -p "$ROOT/release-notes"
    printf '## What'"'"'s new in %s\n\n- Describe what changed.\n' "$VERSION" > "$NOTES"
    echo "Created $NOTES. Edit it, then run this again."
    exit 1
fi
if grep -qE "REPLACE|USERNAME" "$PLIST"; then
    echo "Info.plist still has placeholders: set SUFeedURL to https://<user>.github.io/<repo>/appcast.xml and run 'make sparkle-keys'."
    exit 1
fi

# Bump the marketing version and the always-increasing build number.
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

"$ROOT/scripts/bundle.sh" release

# DMG with a drag-to-Applications layout.
mkdir -p "$RELEASES"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG="$RELEASES/$DMG_NAME"
STAGING="$(mktemp -d)"
ditto "$ROOT/build/$APP_NAME.app" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

if [ -n "${SIGN_IDENTITY:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

# Add only this version to the existing appcast, so earlier entries keep
# pointing at their own GitHub release.
WORK="$(mktemp -d)"
cp "$DMG" "$WORK/"
cp "$NOTES" "$WORK/$APP_NAME-$VERSION.md"
[ -f "$APPCAST" ] && cp "$APPCAST" "$WORK/appcast.xml"
APPCAST_ARGS=(--download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/"
              --versions "$BUILD" --maximum-deltas 0 --embed-release-notes)
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" --ed-key-file - "${APPCAST_ARGS[@]}" "$WORK"
else
    "$SPARKLE_BIN/generate_appcast" "${APPCAST_ARGS[@]}" "$WORK"
fi
mkdir -p "$(dirname "$APPCAST")"
cp "$WORK/appcast.xml" "$APPCAST"
rm -rf "$WORK"

SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo
echo "Built $DMG (build $BUILD) and updated docs/appcast.xml"

if [ "$PUBLISH" = "1" ]; then
    command -v gh >/dev/null || { echo "Install the GitHub CLI (brew install gh) or rerun with PUBLISH=0."; exit 1; }
    # 1. Tag the version bump and publish the DMG...
    git -C "$ROOT" add Resources/Info.plist "$NOTES"
    git -C "$ROOT" commit -m "Release $VERSION"
    git -C "$ROOT" tag "v$VERSION"
    git -C "$ROOT" push origin HEAD "v$VERSION"
    gh release create "v$VERSION" "$DMG" --repo "$GITHUB_REPO" --verify-tag \
        --title "$APP_NAME $VERSION" --notes-file "$NOTES"
    # 2. ...then point the appcast at it, so updaters never see a missing file.
    git -C "$ROOT" add "$APPCAST"
    git -C "$ROOT" commit -m "Appcast: $VERSION"
    git -C "$ROOT" push origin HEAD
    echo "Published https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
else
    echo "PUBLISH=0: nothing was pushed. Commit Info.plist, $NOTES and docs/appcast.xml when ready."
fi

echo
echo "Homebrew tap (Casks/$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]').rb): version \"$VERSION\", sha256 \"$SHA256\""
