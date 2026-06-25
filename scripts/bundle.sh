#!/bin/bash
# Build YeelightBarApp and assemble a signed .app bundle (menu-bar agent).
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"

swift build -c release --package-path "$PKG" --product YeelightBarApp

APP="$PKG/build/YeelightBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$PKG/.build/release/YeelightBarApp" "$APP/Contents/MacOS/YeelightBarApp"
cp "$PKG/build-support/Info.plist" "$APP/Contents/Info.plist"
security unlock-keychain -p ybsign yb-signing.keychain 2>/dev/null || true
if codesign --force --keychain yb-signing.keychain --sign "YeelightBar Dev" --identifier com.vfi.yeelightbar "$APP" 2>/dev/null; then
  echo "signed: YeelightBar Dev (stable)"
else
  codesign --force --sign - "$APP" 2>/dev/null || true
  echo "warn: stable signing failed — fell back to ad-hoc"
fi

echo "built: $APP"
