#!/bin/bash
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"  # xcode-select may point at Command Line Tools
# Builds Pulse.app into ~/Library/Caches/PulseBuild. Usage: ./build.sh [--install]  (--install copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")"
BUILD_DIR="$HOME/Library/Caches/PulseBuild"   # outside iCloud: iCloud xattrs break codesign
APP="$BUILD_DIR/Pulse.app"
SPARKLE="Vendor/Sparkle"
source ./sign_sparkle.sh
UPDATE_URL=""
[[ -f release.conf ]] && source ./release.conf
LOC="$BUILD_DIR/loc"
rm -rf "$APP" "$LOC"
mkdir -p "$LOC/app" "$LOC/widget" "$LOC/out"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Universal binaries (Apple Silicon + Intel). Only the arm64 pass collects strings: they are the same in both.
MIN_MACOS=15.0
BIN="$BUILD_DIR/bin"
rm -rf "$BIN"; mkdir -p "$BIN"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for ARCH in arm64 x86_64; do
  STRINGS=(); [[ $ARCH == arm64 ]] && STRINGS=(-emit-localized-strings -emit-localized-strings-path "$LOC/app")
  xcrun swiftc -O -swift-version 5 -parse-as-library \
    -target "$ARCH-apple-macos$MIN_MACOS" -sdk "$SDK" \
    -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    ${STRINGS[@]+"${STRINGS[@]}"} \
    Sources/*.swift -o "$BIN/Pulse-$ARCH"
done
lipo -create "$BIN"/Pulse-* -output "$APP/Contents/MacOS/Pulse"
# Desktop widget extension (sandboxed; reads the JSON snapshot the app writes)
WX="$APP/Contents/PlugIns/PulseWidget.appex"
mkdir -p "$WX/Contents/MacOS"
for ARCH in arm64 x86_64; do
  STRINGS=(); [[ $ARCH == arm64 ]] && STRINGS=(-emit-localized-strings -emit-localized-strings-path "$LOC/widget")
  xcrun swiftc -O -swift-version 5 -parse-as-library -application-extension \
    ${STRINGS[@]+"${STRINGS[@]}"} \
    -target "$ARCH-apple-macos$MIN_MACOS" -sdk "$SDK" \
    Widget/PulseWidget.swift Sources/WidgetData.swift -o "$BIN/PulseWidget-$ARCH"
done
lipo -create "$BIN"/PulseWidget-* -output "$WX/Contents/MacOS/PulseWidget"
cp Widget/Info.plist "$WX/Contents/"
# The widget's version must match the app's.
for k in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set :$k $(/usr/libexec/PlistBuddy -c "Print :$k" Info.plist)" "$WX/Contents/Info.plist"
done
cp Info.plist "$APP/Contents/"
# Update feed (release.conf → UPDATE_URL); without it the updater stays off.
if [[ -n "$UPDATE_URL" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string ${UPDATE_URL%/}/appcast.xml" "$APP/Contents/Info.plist"
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp AppIcon.icns "$APP/Contents/Resources/"
# Localization: add new strings from the code to the catalog, then compile pl/en/de .lproj folders.
rm -f "$LOC"/*/Snapshot.stringsdata
xcrun xcstringstool sync Localization/Localizable.xcstrings --stringsdata "$LOC"/app/*.stringsdata "$LOC"/widget/*.stringsdata
xcrun xcstringstool compile Localization/Localizable.xcstrings --output-directory "$LOC/out" >/dev/null
shopt -s nullglob
for lproj in "$LOC"/out/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
  mkdir -p "$WX/Contents/Resources" && cp -R "$lproj" "$WX/Contents/Resources/"
done
xattr -cr "$APP"
sign_sparkle "$APP" -
codesign --force --sign - --entitlements Widget/PulseWidget.entitlements "$WX" >/dev/null
codesign --force --sign - "$APP" >/dev/null
echo "Zbudowano: $APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Pulse 2>/dev/null || true
  rm -rf /Applications/Pulse.app
  cp -R "$APP" /Applications/
  open /Applications/Pulse.app
  echo "Zainstalowano w /Applications"
fi
