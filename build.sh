#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP="build/Posture.app"

# Prefer a Developer ID identity, falling back to ad-hoc only if there isn't one.
#
# This is not just about distribution. macOS keys permission grants (Motion &
# Fitness, notifications) to the code's designated requirement. Ad-hoc signing
# makes that requirement a bare `cdhash`, which changes on *every* rebuild — so
# every rebuild looks like a different app and re-prompts for everything. A
# Developer ID requirement is identifier + team, which is stable forever.
#
# Force ad-hoc with SIGN_IDENTITY=- if you ever need it.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "▸ No Developer ID identity — signing ad-hoc." >&2
  echo "  macOS will re-ask for permissions after each rebuild." >&2
fi

swift build -c release --arch arm64

mkdir -p build
if [ ! -f build/Posture.icns ]; then
  ICONSET=$(swift scripts/make-icon.swift build)
  iconutil -c icns "$ICONSET" -o build/Posture.icns
  rm -rf "$ICONSET"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/Posture "$APP/Contents/MacOS/Posture"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/Posture.icns "$APP/Contents/Resources/Posture.icns"

# Ad-hoc signature by default. CoreMotion and UNUserNotificationCenter both
# refuse to work for an unsigned bundle, and the identifier must be stable
# across rebuilds or macOS re-prompts for motion access every time.
#
# Ad-hoc is local-only: on any other Mac Gatekeeper rejects it. Distributing
# needs a Developer ID identity above, then notarization:
#   ditto -c -k --keepParent build/Posture.app build/Posture.zip
#   xcrun notarytool submit build/Posture.zip --keychain-profile AC --wait
#   xcrun stapler staple build/Posture.app
if [ "$SIGN_IDENTITY" = "-" ]; then
  # A secure timestamp needs a real identity; requesting one ad-hoc just adds
  # a network round trip that fails.
  TIMESTAMP="--timestamp=none"
else
  TIMESTAMP="--timestamp"
fi

codesign --force --sign "$SIGN_IDENTITY" \
  --identifier is.einargudni.posture \
  --options runtime \
  $TIMESTAMP \
  "$APP"

echo "Built $APP"
