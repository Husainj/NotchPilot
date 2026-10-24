#!/bin/bash
# One-time: create the EdDSA key pair that signs updates, and put the public
# key into Resources/Info.plist. The private key is stored in your login
# Keychain — BACK IT UP (generate_keys -x exports it). If you lose it,
# existing users can never auto-update again. For GitHub Actions, store the
# exported key as the SPARKLE_PRIVATE_KEY repository secret.
set -euo pipefail
source "$(dirname "$0")/env.sh"

[ -x "$SPARKLE_BIN/generate_keys" ] || swift package "${SWIFT_FLAGS[@]}" resolve
"$SPARKLE_BIN/generate_keys" >/dev/null || true
PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_KEY" "$ROOT/Resources/Info.plist"
echo "Public key written to Resources/Info.plist: $PUBLIC_KEY"
echo "Back up the private key now:  $SPARKLE_BIN/generate_keys -x ~/sparkle-private-key.txt"
echo "Then add it as the SPARKLE_PRIVATE_KEY secret:  gh secret set SPARKLE_PRIVATE_KEY < ~/sparkle-private-key.txt"
