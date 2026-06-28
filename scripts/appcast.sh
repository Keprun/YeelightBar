#!/bin/bash
# Sign a built DMG with Sparkle's EdDSA key and add/refresh its <item> in appcast.xml.
# Usage: scripts/appcast.sh <version> [build]
#   - expects dist/YeelightBar-<version>.dmg (build defaults to <version>'s last component)
#   - needs Sparkle's sign_update on PATH or $SPARKLE_BIN (e.g. SPARKLE_BIN=~/Sparkle/bin)
#   - private EdDSA key lives in the login keychain (created once via generate_keys)
# The appcast item points at the GitHub release asset for that tag.
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
VER="${1:?usage: appcast.sh <version> [build]}"
BUILD="${2:-${VER##*.}}"
DMG="$PKG/dist/YeelightBar-$VER.dmg"
APPCAST="$PKG/appcast.xml"
URL="https://github.com/Keprun/YeelightBar/releases/download/v$VER/YeelightBar-$VER.dmg"

[ -f "$DMG" ] || { echo "no DMG at $DMG — run release.sh $VER first"; exit 1; }
SIGN="${SPARKLE_BIN:+$SPARKLE_BIN/}sign_update"
command -v "$SIGN" >/dev/null 2>&1 || SIGN="$(command -v sign_update || true)"
[ -n "$SIGN" ] && command -v "$SIGN" >/dev/null 2>&1 || { echo "sign_update not found — set SPARKLE_BIN to Sparkle's bin/"; exit 1; }

SIGINFO="$("$SIGN" "$DMG")"   # e.g. sparkle:edSignature="…" length="12345"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

python3 - "$VER" "$BUILD" "$URL" "$APPCAST" "$SIGINFO" "$PUBDATE" <<'PY'
import sys, os, re
ver, build, url, appcast, siginfo, pubdate = sys.argv[1:7]
ed  = re.search(r'edSignature="([^"]+)"', siginfo).group(1)
length = re.search(r'length="([^"]+)"', siginfo).group(1)

item = f'''    <item>
      <title>YeelightBar {ver}</title>
      <pubDate>{pubdate}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{ver}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <link>https://github.com/Keprun/YeelightBar/releases/tag/v{ver}</link>
      <enclosure url="{url}" sparkle:edSignature="{ed}" length="{length}" type="application/octet-stream"/>
    </item>'''

if os.path.exists(appcast):
    xml = open(appcast, encoding="utf-8").read()
    # drop any existing item for this version, then prepend the fresh one
    xml = re.sub(r'\s*<item>(?:(?!</item>).)*?<sparkle:shortVersionString>'
                 + re.escape(ver) + r'</sparkle:shortVersionString>.*?</item>', '', xml, flags=re.S)
    xml = xml.replace('  </channel>', item + '\n  </channel>', 1) \
        if '<item>' in xml else xml.replace('</description>', '</description>\n' + item, 1)
else:
    xml = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>YeelightBar</title>
    <link>https://raw.githubusercontent.com/Keprun/YeelightBar/main/appcast.xml</link>
    <description>YeelightBar updates</description>
    <language>en</language>
{item}
  </channel>
</rss>
'''
open(appcast, "w", encoding="utf-8").write(xml)
print(f"appcast.xml: {ver} (build {build}) signed and inserted")
PY