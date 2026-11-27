#!/bin/zsh
# Builds build/Posture.app with plain swiftc (the Command Line Tools are enough; no Xcode project).
#
#   ./build.sh              build for this Mac (Apple silicon or Intel)
#   UNIVERSAL=1 ./build.sh  build one app that runs on both
set -euo pipefail
cd "$(dirname "$0")"
source scripts/toolchain.sh

APP=build/Posture.app
OBJ=build/obj
rm -rf "$APP" "$OBJ"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ"

slices=()
for arch in $ARCHS; do
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$arch-apple-macosx$MACOS_MIN" \
    Sources/Core/**/*.swift Sources/App/**/*.swift \
    -o "$OBJ/Posture-$arch"
  slices+=("$OBJ/Posture-$arch")
done
if (( ${#slices} > 1 )); then
  lipo -create $slices -output "$APP/Contents/MacOS/Posture"
else
  cp "${slices[1]}" "$APP/Contents/MacOS/Posture"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Posture"))  →  open $APP   (or copy it to /Applications)"
