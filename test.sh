#!/bin/zsh
# Builds and runs the test suite (no Xcode or SwiftPM needed).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/tests
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
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
