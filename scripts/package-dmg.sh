#!/bin/bash
set -euo pipefail

APP="${1:?Usage: package-dmg.sh SoundIn.app output.dmg}"
DMG="${2:?Usage: package-dmg.sh SoundIn.app output.dmg}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: TAO LIU (UAT3Y8UXCQ)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-nightcat-notary}"

codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"

WORK=$(mktemp -d)
MOUNT="$WORK/mount"
cleanup() {
  if [ -d "$MOUNT/SoundIn.app" ]; then
    hdiutil detach "$MOUNT" || return
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir "$WORK/image" "$MOUNT"
ditto "$APP" "$WORK/image/SoundIn.app"
ln -s /Applications "$WORK/image/Applications"

IMAGE="$WORK/SoundIn.dmg"
hdiutil create -volname SoundIn -srcfolder "$WORK/image" -format UDZO "$IMAGE"
codesign --sign "$IDENTITY" --timestamp "$IMAGE"
xcrun notarytool submit "$IMAGE" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$IMAGE"
xcrun stapler validate "$IMAGE"
codesign --verify --strict "$IMAGE"
spctl -a -t open --context context:primary-signature -vv "$IMAGE"

hdiutil attach "$IMAGE" -readonly -nobrowse -mountpoint "$MOUNT"
test "$(readlink "$MOUNT/Applications")" = /Applications
codesign --verify --deep --strict "$MOUNT/SoundIn.app"
xcrun stapler validate "$MOUNT/SoundIn.app"
spctl -a -t exec -vv "$MOUNT/SoundIn.app"
hdiutil detach "$MOUNT"
mv "$IMAGE" "$DMG"
