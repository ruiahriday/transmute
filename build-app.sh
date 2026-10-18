#!/bin/bash
# Builds Transmute.app into ./build.
#   ./build-app.sh             build for this Mac
#   ./build-app.sh --install   also copy it to /Applications and open it
# Environment:
#   UNIVERSAL=1        build one app that runs on both Apple Silicon and Intel Macs
#   FFMPEG_BIN=path    bundle this (static) ffmpeg binary inside the app
set -euo pipefail
cd "$(dirname "$0")"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> Compiling (release)…"
# The ${a[@]+...} form keeps macOS's bash 3.2 happy with an empty array under `set -u`.
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/Transmute.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Transmute" "$APP/Contents/MacOS/Transmute"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon from a 1024x1024 PNG.
if [[ -f Resources/icon.png ]]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Optional bundled ffmpeg, found by the app at Contents/MacOS/ffmpeg.
if [[ -n "${FFMPEG_BIN:-}" ]]; then
  cp "$FFMPEG_BIN" "$APP/Contents/MacOS/ffmpeg"
  chmod +x "$APP/Contents/MacOS/ffmpeg"
  codesign --force --sign - "$APP/Contents/MacOS/ffmpeg"
  echo "==> Bundled ffmpeg"
fi

# Ad-hoc signature so macOS will launch it.
codesign --force --sign - "$APP"
echo "==> Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Transmute.app
  cp -R "$APP" /Applications/
  echo "==> Installed to /Applications/Transmute.app"
  open /Applications/Transmute.app
else
  echo "Run it with:  open $APP"
fi
