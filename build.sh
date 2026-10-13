#!/bin/bash
# Builds DropShelf.app next to this script.
#   ./build.sh            build and launch from this folder
#   ./build.sh --install  build, copy to /Applications, launch
# Needs the Xcode Command Line Tools:  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="DropShelf.app"
ARCH="$(uname -m)"          # arm64 on Apple silicon, x86_64 on Intel

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Run:  xcode-select --install   (then re-run this script)"
  exit 1
fi

echo "Compiling DropShelf for $ARCH..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -target "${ARCH}-apple-macosx12.0" \
  Sources/main.swift Sources/Shake.swift Sources/AppDelegate.swift \
  Sources/Views.swift Sources/ShelfPanel.swift \
  -o "$APP/Contents/MacOS/DropShelf"

echo "Signing (ad-hoc, local use)..."
codesign --force --deep --sign - "$APP"

pkill -x DropShelf 2>/dev/null || true

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  open "/Applications/$APP"
  echo "Installed to /Applications and launched."
else
  open "$APP"
  echo "Built and launched $APP"
fi
echo "Look for the tray icon in your menu bar, then drag a file in Finder and shake it."
