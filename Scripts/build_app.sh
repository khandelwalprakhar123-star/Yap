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

# Bundle the menu-bar logo (loaded at runtime via Bundle.main).
mkdir -p "$APP/Contents/Resources"
cp Resources/logo.png "$APP/Contents/Resources/logo.png"

# Generate the app bundle icon (Finder/Spotlight/Dock) from the 1024×1024 logo.
echo "▸ Generating AppIcon.icns..."
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/logo.png \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size*2))" "$((size*2))" Resources/logo.png \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>LocalFlow</string>
    <key>CFBundleDisplayName</key>       <string>LocalFlow</string>
    <key>CFBundleIdentifier</key>        <string>com.localflow.app</string>
    <key>CFBundleExecutable</key>        <string>LocalFlow</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
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

# Strip download/Finder xattrs (quarantine, resource forks) that make codesign
# reject the bundle with "resource fork ... or similar detritus not allowed".
xattr -cr "$APP"

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
