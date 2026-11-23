# Sourced by build.sh and test.sh. Picks a working Swift toolchain and the CPU architecture(s) to build.
#
#   MACOS_MIN    lowest macOS the app runs on (matches LSMinimumSystemVersion in Resources/Info.plist)
#   ARCHS        architectures to build: defaults to this Mac's own (arm64 or x86_64);
#                UNIVERSAL=1 builds both (Apple silicon + Intel)

MACOS_MIN=14.0

# A usable swiftc: Xcode if it works, otherwise the Command Line Tools. Xcode refuses to run tools
# until its license is accepted, so fall back instead of failing.
if ! swiftc --version >/dev/null 2>&1; then
  if [[ -x /Library/Developer/CommandLineTools/usr/bin/swiftc ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    echo "note: Xcode isn't usable (license not accepted?), using the Command Line Tools instead"
  fi
fi
if ! swiftc --version >/dev/null 2>&1; then
  echo "error: no working Swift compiler. Install the Command Line Tools with:  xcode-select --install" >&2
  exit 1
fi

if [[ -n "${ARCHS:-}" ]]; then
  ARCHS=(${=ARCHS})
elif [[ "${UNIVERSAL:-0}" == 1 ]]; then
  ARCHS=(arm64 x86_64)
else
  ARCHS=($(uname -m))
fi
for a in $ARCHS; do
  [[ "$a" == arm64 || "$a" == x86_64 ]] || { echo "error: unsupported architecture '$a' (use arm64 or x86_64)" >&2; exit 1; }
done

echo "Swift: $(swiftc --version 2>&1 | head -1 | sed 's/.*Apple Swift version/Swift/')  ·  macOS $(sw_vers -productVersion)  ·  building for: $ARCHS (runs on macOS $MACOS_MIN+)"
