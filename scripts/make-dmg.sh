#!/usr/bin/env bash
# Builds build/Posture.dmg from an already-signed build/Posture.app.
#
# Called by release.sh; usable on its own for checking the window layout
# without going through notarization.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Posture.app"
DMG="build/Posture.dmg"
VOLUME="Posture"
STAGE="build/dmg-stage"

[ -d "$APP" ] || { echo "No $APP — run ./build.sh first." >&2; exit 1; }

rm -rf "$STAGE" "$DMG" build/Posture-rw.dmg
mkdir -p "$STAGE/.background"

ditto "$APP" "$STAGE/Posture.app"
ln -s /Applications "$STAGE/Applications"

# The mounted volume gets the app's icon instead of the generic white disk.
# This lives inside the image, so unlike a custom icon on the .dmg file itself
# it survives being downloaded over HTTP.
[ -f build/Posture.icns ] && /bin/cp -f build/Posture.icns "$STAGE/.VolumeIcon.icns"

# A multi-resolution TIFF so the background stays sharp on Retina; a plain PNG
# renders soft at 2x.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APP/Contents/Info.plist" 2>/dev/null || echo "")
swift scripts/make-dmg-background.swift build "$VERSION" >/dev/null
tiffutil -cathidpicheck build/background-1x.png build/background-2x.png \
  -out "$STAGE/.background/background.tiff" >/dev/null
rm -f build/background-1x.png build/background-2x.png

# Read-write first: the icon layout is stored in the volume's .DS_Store, which
# only Finder can write, and only on a mounted writable volume.
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ \
  -format UDRW -ov build/Posture-rw.dmg >/dev/null

MOUNT=$(hdiutil attach build/Posture-rw.dmg -readwrite -noverify -noautoopen \
  | grep -o '/Volumes/.*' | head -1)
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true' EXIT

# Finder scripting is the fragile part — if it fails the DMG is still perfectly
# usable, just with a default icon arrangement, so it must not abort the build.
osascript <<EOF 2>/dev/null || echo "▸ Finder layout skipped (DMG still valid)" >&2
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set background picture of opts to file ".background:background.tiff"
    set position of item "Posture.app" of container window to {160, 170}
    set position of item "Applications" of container window to {480, 170}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF

# Give the mounted volume the app's icon. `.VolumeIcon.icns` plus SetFile is the
# documented route but proved unreliable on a fresh image, so set it directly.
if [ -f build/Posture.icns ]; then
  swiftc -O -o build/set-icon scripts/set-icon.swift 2>/dev/null
  build/set-icon build/Posture.icns "$MOUNT" \
    || echo "▸ Volume icon skipped (DMG still valid)" >&2
  SetFile -a C "$MOUNT" 2>/dev/null || true
fi

sync
hdiutil detach "$MOUNT" -quiet
trap - EXIT

# Compressed, read-only, for shipping.
hdiutil convert build/Posture-rw.dmg -format UDZO -imagekey zlib-level=9 \
  -o "$DMG" >/dev/null
rm -f build/Posture-rw.dmg
rm -rf "$STAGE"

echo "Built $DMG"
