#!/bin/bash
# Build, then (re)launch the app.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh "${1:-release}"
pkill -x Familiar 2>/dev/null || true
sleep 0.3
open build/Familiar.app
echo "launched. log: tail -f ~/.familiar/familiar.log"
