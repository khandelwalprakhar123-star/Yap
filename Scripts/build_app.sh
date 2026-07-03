#!/bin/bash
# Builds LocalFlow.app from the SwiftPM executable.
# No Xcode required — Command Line Tools are enough.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Building release binary..."
swift build -c release --product LocalFlowApp

APP=dist/LocalFlow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/LocalFlowApp "$APP/Contents/MacOS/LocalFlow"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>LocalFlow</string>
    <key>CFBundleDisplayName</key>       <string>LocalFlow</string>
    <key>CFBundleIdentifier</key>        <string>com.localflow.app</string>
    <key>CFBundleExecutable</key>        <string>LocalFlow</string>
    <key>CFBundleVersion</key>           <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>LocalFlow records your voice while the push-to-talk hotkey is held, and transcribes it entirely on this Mac.</string>
</dict>
</plist>
PLIST

# A stable identity keeps the same TCC (permissions) grant across rebuilds.
# Created once by Scripts/make_signing_cert.sh; ad-hoc is the fallback, but
# then Accessibility must be re-granted after every rebuild.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "LocalFlow Dev"; then
    echo "▸ Codesigning with stable identity 'LocalFlow Dev'..."
    codesign --force --sign "LocalFlow Dev" --identifier com.localflow.app "$APP"
else
    echo "▸ Codesigning (ad-hoc — permissions will need re-granting after rebuilds)..."
    codesign --force --sign - --identifier com.localflow.app "$APP"
fi

echo "✓ Built $APP"
echo
echo "Run it with:   open $PWD/$APP"
