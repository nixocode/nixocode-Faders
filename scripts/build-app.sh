#!/usr/bin/env bash
#
# Builds Faders.app and zips it.
#
#   ./scripts/build-app.sh          → build/Faders.app and build/Faders.zip
#
# Needs Apple's Command Line Tools (`xcode-select --install`, the same thing
# `git` needs) or Xcode, from 2025 or later. With Xcode the app is universal
# (Apple silicon + Intel), which is what the GitHub release ships. With just the
# Command Line Tools it's built for this Mac only: they no longer include
# everything an Intel build needs.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Faders"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

if xcrun --find xcodebuild >/dev/null 2>&1; then
  ARCHS=(--arch arm64 --arch x86_64)
  echo "▸ Compiling (release, universal)…"
else
  ARCHS=()
  echo "▸ Compiling (release, $(uname -m))…"
fi
# (The ${ARCHS[@]+…} form keeps bash 3.2, the one macOS ships, happy with an empty list.)
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$APP/Contents/Info.plist"

echo "▸ Stripping debug symbols…"
strip -x "$APP/Contents/MacOS/$APP_NAME"   # about half the binary; nothing at runtime needs them

echo "▸ Making the app icon…"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Support/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Support/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "▸ Zipping…"
rm -f "$BUILD_DIR/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/$APP_NAME.zip"

echo "✓ Done: ${APP} and ${BUILD_DIR}/${APP_NAME}.zip"
