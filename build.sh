#!/bin/zsh
# Builds build/Posture.app with plain swiftc (Command Line Tools are enough; no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Posture.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  Sources/Shared/*.swift Sources/macOS/*.swift \
  -o "$APP/Contents/MacOS/Posture"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Models/* "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP  →  open $APP   (or copy it to /Applications)"
