#!/bin/bash
# Build a distributable YeelightBar .app and package it into a drag-to-install DMG.
# Usage: scripts/release.sh [version]   (default 0.1.0)
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
VER="${1:-0.1.0}"

bash "$PKG/scripts/bundle.sh"
APP="$PKG/build/YeelightBar.app"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/YeelightBar.app"

# Ad-hoc re-sign ONLY the distribution copy: the local self-signed dev cert isn't trusted on other
# Macs, so the DMG ships an ad-hoc signature (runnable everywhere; users right-click → Open once,
# since the app isn't notarized — no paid Apple Developer ID). --deep also signs the embedded
# Sparkle.framework and its XPC helpers. build/YeelightBar.app stays dev-signed, so the LOCAL install
# keeps a stable code-signing identity and macOS doesn't re-prompt for Screen Recording every rebuild.
codesign --force --deep --sign - "$STAGE/YeelightBar.app"

ln -s /Applications "$STAGE/Applications"
mkdir -p "$PKG/dist"
DMG="$PKG/dist/YeelightBar-$VER.dmg"
rm -f "$DMG"
hdiutil create -volname "YeelightBar $VER" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "DMG:  $DMG"
echo -n "SHA256: "; shasum -a 256 "$DMG" | awk '{print $1}'

# Refresh appcast.xml for in-app auto-update; skips gracefully if Sparkle's sign_update isn't around.
if bash "$PKG/scripts/appcast.sh" "$VER" 2>/dev/null; then
  echo "appcast: updated for $VER — commit appcast.xml after the release is published"
else
  echo "appcast: skipped (sign_update unavailable) — run scripts/appcast.sh $VER after installing Sparkle tools"
fi
