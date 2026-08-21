#!/usr/bin/env bash
# Builds a distributable Posture.zip: Developer ID signed, notarized, stapled.
#
# One-time setup — store your notary credentials in the keychain:
#
#   xcrun notarytool store-credentials posture-notary \
#     --apple-id you@example.com --team-id 7AWFJS2W5C \
#     --password <app-specific-password>
#
# App-specific passwords come from appleid.apple.com, not your Apple ID password.
set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-posture-notary}"
APP="build/Posture.app"
DMG="build/Posture.dmg"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')}"

if [ -z "$IDENTITY" ]; then
  echo "No Developer ID Application identity found." >&2
  echo "Without one, macOS blocks the app on every Mac but this one." >&2
  exit 1
fi
echo "▸ Signing as: $IDENTITY"

SIGN_IDENTITY="$IDENTITY" ./build.sh

echo "▸ Verifying signature"
codesign --verify --deep --strict --verbose=1 "$APP"

./scripts/make-dmg.sh

# The DMG carries the app, so it is what gets signed, notarized and stapled.
# Stapling to the DMG means Gatekeeper can clear it offline, before the user
# has copied anything out of it.
echo "▸ Signing the disk image"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo
  echo "No notary credentials stored under profile '$PROFILE'." >&2
  echo "The disk image is signed but NOT notarized — on another Mac, Gatekeeper" >&2
  echo "will refuse to open it. Store credentials (see the header of this" >&2
  echo "script) and run again before publishing it." >&2
  exit 2
fi

echo "▸ Notarizing (this takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "▸ Stapling"
xcrun stapler staple "$DMG"

echo "▸ Gatekeeper check"
# DMGs are assessed as something you open, not as an executable.
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# Only a stapled build is worth putting on the site.
mkdir -p site/public
rm -f site/public/Posture.zip
/bin/cp -f "$DMG" site/public/Posture.dmg
# `stat`, not `ls | awk` — ls is commonly aliased to eza, whose columns differ.
SIZE=$(echo "$(stat -f%z "$DMG")" | awk '{printf "%.1f", $1/1048576}')
echo "$SIZE" > site/public/.download-size

echo
echo "✓ site/public/Posture.dmg — ${SIZE} MB, notarized and stapled"
