#!/bin/zsh
# Builds and runs the test suite (no Xcode or SwiftPM needed). Tests compile all of Sources/Core,
# never Sources/App (it has the @main and the AppKit-only monitor).
set -euo pipefail
cd "$(dirname "$0")"
source scripts/toolchain.sh
mkdir -p build/tests
swiftc -O -swift-version 5 -target "${ARCHS[1]}-apple-macosx$MACOS_MIN" \
  Sources/Core/**/*.swift \
  Tests/*.swift \
  -o build/tests/PostureTests
build/tests/PostureTests

# Guard against expressions that are slow to type-check: older Swift compilers (e.g. 6.2 on macOS 26)
# give up on them with "unable to type-check this expression in reasonable time".
limit=(-Xfrontend -warn-long-expression-type-checking=50)
target="${ARCHS[1]}-apple-macosx$MACOS_MIN"
slow=$( { swiftc -typecheck -parse-as-library -swift-version 5 -target "$target" $limit Sources/Core/**/*.swift Sources/App/**/*.swift
          swiftc -typecheck -swift-version 5 -target "$target" $limit Sources/Core/**/*.swift Tests/*.swift; } 2>&1 \
        | grep -E "\.swift:[0-9]+:[0-9]+: warning: expression took" | sort -u || true)
if [[ -n "$slow" ]]; then
  echo "\nSlow-to-type-check expressions (split them into simpler, explicitly typed steps):\n$slow"
  exit 1
fi
echo "Type-check speed: OK (no expression over 50 ms)"
