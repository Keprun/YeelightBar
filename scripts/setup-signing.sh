#!/bin/bash
# Create a stable self-signed code-signing identity in a dedicated keychain,
# so the app's signature (and thus its TCC/Screen-Recording grant) stays
# constant across rebuilds. Idempotent.
set -euo pipefail

KCNAME="yb-signing.keychain"
KCPATH="$HOME/Library/Keychains/${KCNAME}-db"
KCPASS="ybsign"
IDENTITY="YeelightBar Dev"

if [ ! -f "$KCPATH" ]; then
  security create-keychain -p "$KCPASS" "$KCNAME"
fi
security set-keychain-settings "$KCNAME"             # no auto-lock
security unlock-keychain -p "$KCPASS" "$KCNAME"

# add to the user search list (idempotent, preserving existing entries)
if ! security list-keychains -d user | grep -q "$KCNAME"; then
  existing=$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')
  security list-keychains -d user -s $existing "$KCPATH"
fi

if ! security find-identity -v -p codesigning "$KCNAME" | grep -q "$IDENTITY"; then
  cat > /tmp/yb-codesign.conf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = YeelightBar Dev
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
  openssl req -x509 -newkey rsa:2048 -keyout /tmp/yb.key -out /tmp/yb.crt -days 3650 -nodes -config /tmp/yb-codesign.conf >/dev/null 2>&1
  openssl pkcs12 -export -inkey /tmp/yb.key -in /tmp/yb.crt -out /tmp/yb.p12 -passout pass:ybp12 >/dev/null 2>&1
  security import /tmp/yb.p12 -k "$KCNAME" -P ybp12 -A >/dev/null 2>&1
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KCNAME" >/dev/null 2>&1
  rm -f /tmp/yb.key /tmp/yb.crt /tmp/yb.p12
fi

echo "=== codesigning identities ==="
security find-identity -v -p codesigning "$KCNAME"
