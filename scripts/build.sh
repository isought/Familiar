#!/bin/bash
# Builds Noteling with SwiftPM and assembles build/Noteling.app (ad-hoc signed unless a "Noteling Dev" or older "Familiar Dev" identity exists).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
if ! OUT=$(swift build -c "$CONFIG" 2>&1); then
  echo "$OUT" | grep -E 'error' | head -20
  echo "build failed"; exit 1
fi
echo "$OUT" | grep -E 'warning' | head -5 || true
BIN=".build/$CONFIG/Familiar"   # the SwiftPM product keeps its internal name
[ -x "$BIN" ] || { echo "build failed: $BIN missing"; exit 1; }

APP="build/Noteling.app"
RES="$APP/Contents/Resources"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES/bin"
cp "$BIN" "$APP/Contents/MacOS/Noteling"
cp Resources/Info.plist "$APP/Contents/"

# Copy only files git does not ignore, so git-ignored tokens and caches never reach the app.
# Outside a git checkout everything is copied and the check below catches what must not ship.
copy_shippable() {
  local src="$1" dest="$2" f rel
  mkdir -p "$dest"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      [ -f "$f" ] || continue
      rel="${f#"$src"/}"
      mkdir -p "$dest/$(dirname "$rel")"
      cp "$f" "$dest/$rel"
    done < <(git ls-files -z --cached --others --exclude-standard -- "$src")
  else
    cp -R "$src/." "$dest/"
  fi
}
copy_shippable Resources/py "$RES/py"
copy_shippable tools "$RES/tools"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$RES/"

# Licenses and notices ship inside every build.
mkdir -p "$RES/Legal"
cp LICENSE NOTICE THIRD_PARTY_NOTICES.md PRIVACY.md TRADEMARKS.md "$RES/Legal/"
cp -R licenses "$RES/Legal/licenses"

# Bundle uv so scripts (and their inline dependencies) run on machines without Python.
UV="${FAMILIAR_UV:-$(command -v uv || true)}"
if [ -n "$UV" ] && [ -x "$UV" ]; then
  cp "$UV" "$RES/bin/uv"
else
  echo "note: uv not found; scripts will use system python3 without dependency support"
fi

# Refuse to produce an app that carries caches, Finder files or credentials.
JUNK="$(find "$APP" \( -name '__pycache__' -o -name '*.pyc' -o -name '.DS_Store' -o -name 'token' \
  -o -name '.env' -o -name '.env.*' -o -name 'secrets.json' \) -print)"
if [ -n "$JUNK" ]; then
  echo "build refused: these files must not ship in the app:"; echo "$JUNK"; exit 1
fi

IDENTITY="${FAMILIAR_SIGN_IDENTITY:-}"
IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [ -z "$IDENTITY" ]; then
  DEVID="$(echo "$IDS" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
  if [ -n "$DEVID" ]; then IDENTITY="$DEVID"
  elif echo "$IDS" | grep -q "Noteling Dev"; then IDENTITY="Noteling Dev"
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
