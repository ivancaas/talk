#!/bin/bash
# Build Talk.app and install it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="/Applications/Talk.app"
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
codesign --force --sign - --identifier com.ivancarracedo.talk "$APP"
echo "installed $APP"
