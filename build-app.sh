#!/bin/bash
# Builds Transmute.app into ./build.
#   ./build-app.sh             build for this Mac
#   ./build-app.sh --install   also copy it to /Applications and open it
# Environment:
#   UNIVERSAL=1        build one app that runs on both Apple Silicon and Intel Macs
#   FFMPEG_BIN=path    bundle this (static) ffmpeg binary inside the app
#   APPSTORE=1         build the Mac App Store variant instead (see below) into build/appstore
#   FFMPEG_LICENSES=f  (App Store) licence texts to append to ThirdPartyNotices.txt
set -euo pipefail
cd "$(dirname "$0")"

# ---- Mac App Store variant -------------------------------------------------------------
# APPSTORE=1 compiles with the Swift condition APPSTORE (bundled ffmpeg only, sandbox-safe
# output folders, bookmarks, third-party notices) and signs with the App Sandbox
# entitlements in Resources/AppStore*.entitlements. FFMPEG_BIN must then be an LGPL-only
# ffmpeg (scripts/build-ffmpeg-lgpl.sh). The normal build is unchanged when APPSTORE is unset.
APPSTORE="${APPSTORE:-0}"
# TODO(rename): the product name and bundle id aren't chosen yet. Pass them in:
#   APPSTORE_BUNDLE_ID=com.yourcompany.yourapp APPSTORE_NAME="Your App" APPSTORE=1 bash build-app.sh
APPSTORE_BUNDLE_ID="${APPSTORE_BUNDLE_ID:-com.example.transmute}"   # TODO: real bundle id
APPSTORE_NAME="${APPSTORE_NAME:-Transmute}"                         # TODO: real display name
APPSTORE_VERSION="${APPSTORE_VERSION:-1.0}"                         # App Store needs a plain x.y[.z]
APPSTORE_CATEGORY="${APPSTORE_CATEGORY:-public.app-category.utilities}"
# Signing identity. "-" is an ad-hoc signature (runs on this Mac only). For the App Store,
# set it to the "Apple Distribution: …" (or "3rd Party Mac Developer Application: …")
# certificate's name and add the provisioning profile (APPSTORE_PROFILE=path/to.provisionprofile).
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APPSTORE_PROFILE="${APPSTORE_PROFILE:-}"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
SWIFT_FLAGS=()
APP="build/Transmute.app"
if [[ "$APPSTORE" == "1" ]]; then
  # Its own build folder, so the two variants never share compiled objects.
  SWIFT_FLAGS=(-Xswiftc -DAPPSTORE --build-path .build-appstore)
  APP="build/appstore/$APPSTORE_NAME.app"
fi

echo "==> Compiling (release$([[ "$APPSTORE" == "1" ]] && echo ", App Store variant"))…"
# The ${a[@]+...} form keeps macOS's bash 3.2 happy with an empty array under `set -u`.
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Transmute" "$APP/Contents/MacOS/Transmute"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ "$APPSTORE" == "1" ]]; then
  PLIST="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APPSTORE_BUNDLE_ID" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $APPSTORE_NAME" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APPSTORE_NAME" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APPSTORE_VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string $APPSTORE_CATEGORY" "$PLIST"
  # Only Apple's built-in (exempt) encryption is used: PDF and zip passwords.
  /usr/libexec/PlistBuddy -c "Add :ITSAppUsesNonExemptEncryption bool false" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :NSAppleEventsUsageDescription $APPSTORE_NAME asks Pages, Keynote or Numbers to export documents when you convert iWork, Word, PowerPoint or Excel files." "$PLIST"
  cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
  cp Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/ThirdPartyNotices.txt"
  # FFMPEG_LICENSES: the licence texts gathered by scripts/build-ffmpeg-lgpl.sh.
  if [[ -n "${FFMPEG_LICENSES:-}" && -f "$FFMPEG_LICENSES" ]]; then
    cat "$FFMPEG_LICENSES" >> "$APP/Contents/Resources/ThirdPartyNotices.txt"
  else
    echo "warning: FFMPEG_LICENSES not set; ThirdPartyNotices.txt lacks the full licence texts" >&2
  fi
  if [[ -n "$APPSTORE_PROFILE" ]]; then
    cp "$APPSTORE_PROFILE" "$APP/Contents/embedded.provisionprofile"
  fi
fi
# CI passes its run number so each download has its own build number (shown in Settings
# and in feedback).
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

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
  if [[ "$APPSTORE" == "1" ]]; then
    # Sandboxed helper: must carry app-sandbox + inherit, signed before the app.
    codesign --force --sign "$SIGN_IDENTITY" --entitlements Resources/AppStore-ffmpeg.entitlements \
      "$APP/Contents/MacOS/ffmpeg"
  else
    codesign --force --sign - "$APP/Contents/MacOS/ffmpeg"
  fi
  echo "==> Bundled ffmpeg"
elif [[ "$APPSTORE" == "1" ]]; then
  echo "warning: App Store build without FFMPEG_BIN; media formats that need ffmpeg won't work" >&2
fi

if [[ "$APPSTORE" == "1" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --entitlements Resources/AppStore.entitlements "$APP"
  echo "==> Built $APP (App Store variant, bundle id $APPSTORE_BUNDLE_ID, signed with identity '$SIGN_IDENTITY')"
  # Installing over the download build would mix the two; stop here.
  exit 0
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
