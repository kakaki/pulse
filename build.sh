#!/bin/bash
# Builds Pulse.app into ~/Library/Caches/PulseBuild. Usage: ./build.sh [--install]  (--install copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")"
BUILD_DIR="$HOME/Library/Caches/PulseBuild"   # outside iCloud: iCloud xattrs break codesign
APP="$BUILD_DIR/Pulse.app"
SPARKLE="Vendor/Sparkle"
source ./sign_sparkle.sh
UPDATE_URL=""
[[ -f release.conf ]] && source ./release.conf
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  Sources/*.swift -o "$APP/Contents/MacOS/Pulse"
# Desktop widget extension (sandboxed; reads the JSON snapshot the app writes)
WX="$APP/Contents/PlugIns/PulseWidget.appex"
mkdir -p "$WX/Contents/MacOS"
xcrun swiftc -O -swift-version 5 -parse-as-library -application-extension \
  -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  Widget/PulseWidget.swift Sources/WidgetData.swift -o "$WX/Contents/MacOS/PulseWidget"
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
