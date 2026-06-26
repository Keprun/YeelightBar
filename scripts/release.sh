#!/bin/bash
# Build a distributable YeelightBar .app and package it into a drag-to-install DMG.
# Usage: scripts/release.sh [version]   (default 0.1.0)
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
VER="${1:-0.1.0}"

bash "$PKG/scripts/bundle.sh"
APP="$PKG/build/YeelightBar.app"

# Ad-hoc re-sign for distribution: the local self-signed dev cert isn't trusted on other
# Macs, so ship an ad-hoc signature (runnable everywhere; users right-click → Open once,
# since the app isn't notarized — no paid Apple Developer ID).
codesign --force --sign - "$APP"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/YeelightBar.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$PKG/dist"
DMG="$PKG/dist/YeelightBar-$VER.dmg"
rm -f "$DMG"
hdiutil create -volname "YeelightBar $VER" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "DMG:  $DMG"
echo -n "SHA256: "; shasum -a 256 "$DMG" | awk '{print $1}'
