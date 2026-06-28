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
mkdir -p "$APP/Contents/Resources"
cp "$PKG/build-support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for lp in "$PKG"/build-support/localization/*.lproj; do
  [ -d "$lp" ] && cp -R "$lp" "$APP/Contents/Resources/"
done

# Embed Sparkle.framework (in-app auto-update). The executable links @rpath/Sparkle.framework, so
# copy the universal slice into Contents/Frameworks and point an rpath at it. --deep signing below
# covers the framework's nested XPC helpers.
mkdir -p "$APP/Contents/Frameworks"
SPARKLE_FW="$(find "$PKG/.build/artifacts" -path '*Sparkle.xcframework/macos-arm64*/Sparkle.framework' -type d 2>/dev/null | head -1)"
if [ -n "$SPARKLE_FW" ]; then
  cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
  otool -l "$APP/Contents/MacOS/YeelightBarApp" | grep -q "@executable_path/../Frameworks" \
    || install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/YeelightBarApp"
else
  echo "warn: Sparkle.framework not found in .build/artifacts — auto-update will be unavailable"
fi

security unlock-keychain -p ybsign yb-signing.keychain 2>/dev/null || true
if codesign --force --deep --keychain yb-signing.keychain --sign "YeelightBar Dev" --identifier com.vfi.yeelightbar "$APP" 2>/dev/null; then
  echo "signed: YeelightBar Dev (stable)"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  echo "warn: stable signing failed — fell back to ad-hoc"
fi

echo "built: $APP"
