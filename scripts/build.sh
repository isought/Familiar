#!/bin/bash
# Builds Familiar with SwiftPM and assembles build/Familiar.app (ad-hoc signed unless a "Familiar Dev" identity exists).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" 2>&1 | grep -E 'error|warning' || true
BIN=".build/$CONFIG/Familiar"
[ -x "$BIN" ] || { echo "build failed: $BIN missing"; exit 1; }

APP="build/Familiar.app"
RES="$APP/Contents/Resources"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES/bin"
cp "$BIN" "$APP/Contents/MacOS/Familiar"
cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/py "$RES/py"
cp -R tools "$RES/tools"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$RES/"

# Bundle uv so scripts (and their inline dependencies) run on machines without Python.
UV="${FAMILIAR_UV:-$(command -v uv || true)}"
if [ -n "$UV" ] && [ -x "$UV" ]; then
  cp "$UV" "$RES/bin/uv"
else
  echo "note: uv not found; scripts will use system python3 without dependency support"
fi

IDENTITY="${FAMILIAR_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Familiar Dev"; then
  IDENTITY="Familiar Dev"
elif [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Sidekick Dev"; then
  IDENTITY="Sidekick Dev"   # identity created before the rename still works
fi
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "built $APP (signed: ${IDENTITY:-ad-hoc}, uv: ${UV:-none})"
