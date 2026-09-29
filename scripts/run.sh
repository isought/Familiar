#!/bin/bash
# Build, then (re)launch the app.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh "${1:-release}"
pkill -x Noteling 2>/dev/null || true
pkill -x Familiar 2>/dev/null || true   # a copy from before the rename
sleep 0.3
open build/Noteling.app
echo "launched. log: tail -f ~/.noteling/noteling.log"
