#!/bin/bash
# Regenerates ../AppIcon.icns from MakeIcon.swift.
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos26.0 MakeIcon.swift -o "$TMP/MakeIcon"
"$TMP/MakeIcon" "$TMP/icon_1024.png"
SET="$TMP/AppIcon.iconset"; mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o ../AppIcon.icns
cp "$TMP/icon_1024.png" ./icon_preview.png
rm -rf "$TMP"
echo "AppIcon.icns gotowy"
