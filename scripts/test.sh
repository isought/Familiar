#!/bin/bash
# Swift Testing is bundled with current Command Line Tools as well as Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_ARGS=(--disable-xctest)
TEST_DEVELOPER="$(xcode-select -p)/Library/Developer"
TEST_FRAMEWORKS="$TEST_DEVELOPER/Frameworks"
if [ -d "$TEST_FRAMEWORKS/Testing.framework" ]; then
  TEST_ARGS+=(-Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS"
             -Xlinker -rpath -Xlinker "$TEST_DEVELOPER/usr/lib")
fi
exec swift test "${TEST_ARGS[@]}" "$@"
