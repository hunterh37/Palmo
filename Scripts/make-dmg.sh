#!/bin/bash
# Builds Palmo (Release) and packages a distributable Palmo.dmg into dist/.
#
# Signing/notarization: set SIGN_ID to your "Developer ID Application: ..."
# identity to codesign; without it the app is ad-hoc signed (users will need
# to right-click > Open on first launch). For a friction-free download you
# must also notarize: xcrun notarytool submit dist/Palmo.dmg --keychain-profile <profile> --wait
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Palmo"
DIST="dist"
STAGING="$DIST/dmg-staging"

echo "==> Building Release..."
xcodebuild -project HandOrbMenu.xcodeproj -scheme HandOrbMenu \
  -configuration Release -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  -derivedDataPath build build | tail -2

APP="build/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "Build product not found: $APP"; exit 1; }

if [ -n "${SIGN_ID:-}" ]; then
  echo "==> Codesigning with $SIGN_ID..."
  codesign --force --deep --options runtime --sign "$SIGN_ID" "$APP"
else
  echo "==> No SIGN_ID set; ad-hoc signing (set SIGN_ID='Developer ID Application: ...' for distribution)"
  codesign --force --deep --sign - "$APP"
fi

echo "==> Staging DMG..."
rm -rf "$STAGING" "$DIST/$APP_NAME.dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating DMG..."
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO \
  "$DIST/$APP_NAME.dmg" >/dev/null
rm -rf "$STAGING"

echo "==> Done: $DIST/$APP_NAME.dmg"
du -h "$DIST/$APP_NAME.dmg"
