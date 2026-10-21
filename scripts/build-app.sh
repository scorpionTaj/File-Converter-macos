#!/usr/bin/env bash
# Builds Kumquat.app (and a zip + dmg) into ./build.
#
#   scripts/build-app.sh                 # native architecture
#   UNIVERSAL=1 scripts/build-app.sh     # arm64 + x86_64
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build"
APP="$BUILD/Kumquat.app"
VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 0.1.0)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "▸ Building Kumquat $VERSION ($BUILD_NUMBER)"
swift build -c release --product Kumquat ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
swift build -c release --product kumquat-cli ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN_DIR/Kumquat" "$APP/Contents/MacOS/Kumquat"
cp "$BIN_DIR/kumquat-cli" "$APP/Contents/Resources/bin/kumquat-cli"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Generating icon"
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Optional: bundle a static ffmpeg/ffprobe so media conversions work out of the box.
if [[ -n "${FFMPEG_BIN:-}" && -x "$FFMPEG_BIN" ]]; then
  cp "$FFMPEG_BIN" "$APP/Contents/Resources/bin/ffmpeg"
  [[ -x "${FFPROBE_BIN:-}" ]] && cp "$FFPROBE_BIN" "$APP/Contents/Resources/bin/ffprobe"
fi

echo "▸ Signing ($SIGN_IDENTITY)"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
find "$APP/Contents/Resources/bin" -type f -perm +111 -exec codesign "${SIGN_ARGS[@]}" {} \;
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo "▸ Packaging"
rm -f "$BUILD/Kumquat.zip" "$BUILD/Kumquat.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD/Kumquat.zip"
DMG_STAGE="$BUILD/dmg"
rm -rf "$DMG_STAGE" && mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "Kumquat" -srcfolder "$DMG_STAGE" -ov -format UDZO "$BUILD/Kumquat.dmg" >/dev/null
rm -rf "$DMG_STAGE"

echo "✓ $APP"
echo "✓ $BUILD/Kumquat.zip"
echo "✓ $BUILD/Kumquat.dmg"
