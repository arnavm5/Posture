#!/bin/zsh
# Builds and runs the test suite (no Xcode or SwiftPM needed).
set -euo pipefail
cd "$(dirname "$0")"
source scripts/toolchain.sh
mkdir -p build/tests
swiftc -O -swift-version 5 -target "${ARCHS[1]}-apple-macosx$MACOS_MIN" \
  Sources/Shared/PostureEstimator.swift \
  Sources/Shared/PostureRules.swift \
  Sources/Shared/HunchDetector.swift \
  Sources/Shared/HunchModels.swift \
  Sources/Shared/MotionProcessing.swift \
  Sources/Shared/Notifier.swift \
  Sources/Shared/HeadphoneMotion.swift \
  Sources/Shared/HeadCalibration.swift \
  Sources/Shared/DeskMode.swift \
  Sources/Shared/SlouchTimer.swift \
  Sources/Shared/RelativePosition.swift \
  Sources/Shared/GLBLoader.swift \
  Sources/Shared/Hair.swift \
  Sources/Shared/HeadView.swift \
  Sources/Shared/HeadAnimator.swift \
  Sources/Shared/Chime.swift \
  Sources/Shared/Platform.swift \
  Tests/*.swift \
  -o build/tests/PostureTests
build/tests/PostureTests "$PWD/Resources/Models"

# Guard against expressions that are slow to type-check: older Swift compilers (e.g. 6.2 on macOS 26)
# give up on them with "unable to type-check this expression in reasonable time".
slow=$(swiftc -typecheck -parse-as-library -swift-version 5 -target "${ARCHS[1]}-apple-macosx$MACOS_MIN" \
  -Xfrontend -warn-long-expression-type-checking=50 \
  Sources/Shared/*.swift Sources/macOS/*.swift 2>&1 | grep -E "\.swift:[0-9]+:[0-9]+: warning: expression took" || true)
if [[ -n "$slow" ]]; then
  echo "\nSlow-to-type-check expressions (split them into simpler, explicitly typed steps):\n$slow"
  exit 1
fi
echo "Type-check speed: OK (no expression over 50 ms)"
