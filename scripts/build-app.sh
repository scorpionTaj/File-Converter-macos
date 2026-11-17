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
swift build -c release --product KumquatExtension ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN_DIR/Kumquat" "$APP/Contents/MacOS/Kumquat"
cp "$BIN_DIR/kumquat-cli" "$APP/Contents/Resources/bin/kumquat-cli"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Translations"
# Untranslated strings show in English; CI fails on them (scripts/strings.py check), local builds just warn.
python3 scripts/strings.py check >/dev/null || echo "  ⚠︎ Some strings aren't translated yet: run scripts/strings.py check"
python3 scripts/strings.py compile "$APP/Contents/Resources"

# Finder Quick Action and Share extension: one binary, two bundles, each with its own Info.plist.
EXTENSIONS=(QuickAction Share)
for EXT in "${EXTENSIONS[@]}"; do
  APPEX="$APP/Contents/PlugIns/$EXT.appex"
  mkdir -p "$APPEX/Contents/MacOS"
  cp "$BIN_DIR/KumquatExtension" "$APPEX/Contents/MacOS/KumquatExtension"
  sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" "Resources/Extensions/$EXT-Info.plist" > "$APPEX/Contents/Info.plist"
done

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
# Inside out: extensions before the app. macOS only loads sandboxed extensions.
for EXT in "${EXTENSIONS[@]}"; do
  codesign "${SIGN_ARGS[@]}" --entitlements Resources/Extensions/Extension.entitlements "$APP/Contents/PlugIns/$EXT.appex"
done
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo "▸ Packaging"
rm -f "$BUILD/Kumquat.zip" "$BUILD/Kumquat.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD/Kumquat.zip"
# Styled installer window (background, arrow, icon layout) via dmgbuild, which writes Finder's .DS_Store
# directly and so works headless in CI. Falls back to a plain image when Python/pip isn't available.
make_styled_dmg() {
  local art="$BUILD/dmg-background" venv="$BUILD/.venv"
  swift scripts/make-dmg-background.swift "$art" || return 1
  tiffutil -cathidpicheck "$art/background.png" "$art/background@2x.png" -out "$art/background.tiff" >/dev/null || return 1
  if [[ ! -x "$venv/bin/dmgbuild" ]]; then
    python3 -m venv "$venv" && "$venv/bin/pip" install --quiet --disable-pip-version-check dmgbuild || return 1
  fi
  "$venv/bin/dmgbuild" -s scripts/dmg-settings.py \
    -D app="$APP" -D background="$art/background.tiff" -D icon="$APP/Contents/Resources/AppIcon.icns" \
    "Kumquat" "$BUILD/Kumquat.dmg" >/dev/null
}

make_plain_dmg() {
  local stage="$BUILD/dmg"
  rm -rf "$stage" && mkdir -p "$stage"
  cp -R "$APP" "$stage/"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname "Kumquat" -srcfolder "$stage" -ov -format UDZO "$BUILD/Kumquat.dmg" >/dev/null
  rm -rf "$stage"
}

if [[ "${PLAIN_DMG:-0}" != "1" ]] && make_styled_dmg; then
  echo "  styled installer window"
else
  echo "  (styled DMG unavailable; building a plain one)"
  rm -f "$BUILD/Kumquat.dmg"
  make_plain_dmg
fi

echo "✓ $APP"
echo "✓ $BUILD/Kumquat.zip"
echo "✓ $BUILD/Kumquat.dmg"
