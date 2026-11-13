#!/bin/bash
# Build Talk.app and install it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="/Applications/Talk.app"
BUNDLE_ID="com.ivancarracedo.talk"
SIGN_NAME="Talk Local Signing"

# Sign with a stable self-signed certificate, not ad hoc. Ad-hoc signatures are tied to the exact binary
# (cdhash), so after every rebuild macOS keeps a ticked Accessibility entry that no longer matches and
# pasting silently fails. A certificate keeps the same identity across rebuilds, so the grant sticks.
if ! security find-identity -p codesigning | grep -q "\"$SIGN_NAME\""; then
    echo "creating code-signing certificate \"$SIGN_NAME\" in your login keychain (once)"
    TMP=$(mktemp -d)
    cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGN_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -name "$SIGN_NAME" -passout pass:talk -out "$TMP/id.p12" 2>/dev/null
    security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P talk -T /usr/bin/codesign >/dev/null
    rm -rf "$TMP"
fi

# An older ad-hoc build left an Accessibility entry that can never match again: clear it once.
if [ -d "$APP" ] && codesign -dr - "$APP" 2>&1 | grep -q 'designated => cdhash'; then
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "removed the stale Accessibility entry from the old ad-hoc build: re-tick Talk once when asked"
fi

pkill -x Talk 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Talk "$APP/Contents/MacOS/Talk"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.ivancarracedo.talk</string>
    <key>CFBundleName</key><string>Talk</string>
    <key>CFBundleExecutable</key><string>Talk</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Talk records your voice only while dictation is on, and transcribes it on this Mac.</string>
</dict>
</plist>
PLIST
codesign --force --sign "$SIGN_NAME" --identifier "$BUNDLE_ID" "$APP"
echo "installed $APP"
