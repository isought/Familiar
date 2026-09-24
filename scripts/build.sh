#!/bin/bash
# Builds Familiar with SwiftPM and assembles build/Familiar.app (ad-hoc signed unless a "Familiar Dev" identity exists).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
if ! OUT=$(swift build -c "$CONFIG" 2>&1); then
  echo "$OUT" | grep -E 'error' | head -20
  echo "build failed"; exit 1
fi
echo "$OUT" | grep -E 'warning' | head -5 || true
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
IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [ -z "$IDENTITY" ]; then
  DEVID="$(echo "$IDS" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
  if [ -n "$DEVID" ]; then IDENTITY="$DEVID"
  elif echo "$IDS" | grep -q "Familiar Dev"; then IDENTITY="Familiar Dev"
  elif echo "$IDS" | grep -q "Sidekick Dev"; then IDENTITY="Sidekick Dev"
  fi
fi
if [[ "$IDENTITY" == Developer\ ID* ]]; then
  # Notarizable: hardened runtime + secure timestamp, nested executables signed first.
  [ -x "$RES/bin/uv" ] && codesign --force --options runtime --timestamp --sign "$IDENTITY" "$RES/bin/uv"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign "${IDENTITY:--}" "$APP"
fi
echo "built $APP (signed: ${IDENTITY:-ad-hoc}, uv: ${UV:-none})"
