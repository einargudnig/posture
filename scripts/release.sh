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
ZIP="build/Posture.zip"

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

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo
  echo "No notary credentials stored under profile '$PROFILE'." >&2
  echo "The zip is signed but NOT notarized — on another Mac, Gatekeeper will" >&2
  echo "refuse to open it. Store credentials (see the header of this script)" >&2
  echo "and run again before publishing it." >&2
  exit 2
fi

echo "▸ Notarizing (this takes a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "▸ Stapling"
xcrun stapler staple "$APP"

# Re-zip: the staple lands on the .app, so the zip has to be rebuilt to carry it.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▸ Gatekeeper check"
spctl --assess --type execute --verbose=2 "$APP"

# Only a stapled build is worth putting on the site.
mkdir -p site/public
cp "$ZIP" site/public/Posture.zip
# `stat`, not `ls | awk` — ls is commonly aliased to eza, whose columns differ.
SIZE=$(echo "$(stat -f%z "$ZIP")" | awk '{printf "%.1f", $1/1048576}')
echo "$SIZE" > site/public/.download-size

echo
echo "✓ site/public/Posture.zip — ${SIZE} MB, notarized and stapled"
