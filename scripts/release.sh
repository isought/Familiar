#!/bin/bash
# Signs with the Developer ID, notarizes, staples, and produces dist/Familiar-<version>.dmg and .pkg.
# One-time setup: install a "Developer ID Application" certificate, and
#   xcrun notarytool store-credentials familiar-notary --apple-id EMAIL --team-id TEAMID --password APP_SPECIFIC_PASSWORD
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${FAMILIAR_NOTARY_PROFILE:-familiar-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

security find-identity -v -p codesigning | grep -q "Developer ID Application" || { echo "no Developer ID Application certificate in the keychain"; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || { echo "notarytool profile '$PROFILE' not found; run store-credentials first"; exit 1; }

./scripts/build.sh
APP="build/Familiar.app"
codesign --verify --deep --strict --verbose=2 "$APP"
grep -q "Developer ID" <(codesign -dvv "$APP" 2>&1) || { echo "app is not Developer ID signed"; exit 1; }

DIST=dist; rm -rf "$DIST"; mkdir -p "$DIST"

echo "== notarizing the app"
ditto -c -k --keepParent "$APP" "$DIST/Familiar.zip"
xcrun notarytool submit "$DIST/Familiar.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$DIST/Familiar.zip"

echo "== dmg"
STAGE="$(mktemp -d)"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Familiar-$VERSION.dmg"
hdiutil create -volname "Familiar" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "== pkg (for MDM)"
PKG="$DIST/Familiar-$VERSION.pkg"
IDENTITY_INSTALLER="$(security find-identity -v -p basic | grep -o '"Developer ID Installer: [^"]*"' | head -1 | tr -d '"' || true)"
if [ -n "$IDENTITY_INSTALLER" ]; then
  pkgbuild --component "$APP" --install-location /Applications --identifier com.isought.familiar --version "$VERSION" --sign "$IDENTITY_INSTALLER" "$PKG"
  xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$PKG"
else
  pkgbuild --component "$APP" --install-location /Applications --identifier com.isought.familiar --version "$VERSION" "$PKG"
  echo "note: no 'Developer ID Installer' certificate, so the .pkg is unsigned (fine for MDM push, not for direct download). Create one on the developer portal to sign it."
fi

spctl -a -vv "$APP" 2>&1 | tail -1
ls -la "$DIST"
