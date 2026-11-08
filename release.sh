#!/bin/bash
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"  # xcode-select may point at Command Line Tools
# Builds a Developer ID-signed, notarized Pulse-<version>.dmg.
#
#   ./release.sh                 sign with the first "Developer ID Application" identity, notarize, staple
#   ./release.sh --no-notarize   sign only (quick check)
#   IDENTITY=- ./release.sh --no-notarize   ad-hoc dry run (tests packaging without a certificate)
#
# One-time notarization setup (stores an app-specific password in your keychain):
#   xcrun notarytool store-credentials pulse-notary --apple-id <apple-id> --team-id <TEAMID>
#
# Updates (Sparkle): with UPDATE_URL set in release.conf, the notarized DMG is copied to updates/
# and updates/appcast.xml is regenerated (signed with the EdDSA key "pulse" from the keychain).
# Commit and push updates/ afterwards – that publishes the update.
set -euo pipefail
cd "$(dirname "$0")"
source ./sign_sparkle.sh
UPDATE_URL=""
[[ -f release.conf ]] && source ./release.conf

NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0
PROFILE="${NOTARY_PROFILE:-pulse-notary}"

IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 '"Developer ID Application' | awk '{print $2}' || true)}"
if [[ -z "$IDENTITY" ]]; then
  echo "Brak certyfikatu „Developer ID Application” w pęku kluczy." >&2
  echo "Xcode → Ustawienia → Konta → Manage Certificates… → + → Developer ID Application" >&2
  exit 1
fi
echo "Podpis: $IDENTITY"

./build.sh >/dev/null
BUILD_DIR="$HOME/Library/Caches/PulseBuild"
APP="$BUILD_DIR/Pulse.app"
WX="$APP/Contents/PlugIns/PulseWidget.appex"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

SIGN=(codesign --force --sign "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && SIGN+=(--options runtime --timestamp)

# Inside-out: Sparkle, the widget extension, then the app.
if [[ "$IDENTITY" == "-" ]]; then sign_sparkle "$APP" -; else sign_sparkle "$APP" "$IDENTITY" --options runtime --timestamp; fi
"${SIGN[@]}" --entitlements Widget/PulseWidget.entitlements "$WX"
"${SIGN[@]}" --entitlements Pulse.entitlements "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

# DMG with an /Applications shortcut
STAGE="$BUILD_DIR/dmg"
DMG="$BUILD_DIR/Pulse-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Pulse $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
[[ "$IDENTITY" != "-" ]] && codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [[ $NOTARIZE == 1 && "$IDENTITY" != "-" ]]; then
  echo "Notaryzacja (zwykle 1–5 min)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

OUT="$(pwd)/dist"
mkdir -p "$OUT"
cp "$DMG" "$OUT/"
echo "Gotowe: $OUT/Pulse-$VERSION.dmg"

if [[ -n "$UPDATE_URL" && $NOTARIZE == 1 && "$IDENTITY" != "-" ]]; then
  mkdir -p updates
  cp "$DMG" updates/
  ./Vendor/Sparkle/bin/generate_appcast --account pulse --maximum-deltas 0 \
    --download-url-prefix "${UPDATE_URL%/}/" -o updates/appcast.xml updates
  echo "Appcast: updates/appcast.xml – zrób commit i push folderu updates/, aby opublikować aktualizację."
fi
