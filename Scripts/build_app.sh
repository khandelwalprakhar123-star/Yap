#!/bin/bash
# Builds LocalFlow.app from the SwiftPM executable.
# No Xcode required — Command Line Tools are enough.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Building release binary..."
swift build -c release --product LocalFlowApp

# The repo lives under ~/Desktop, which is an iCloud Drive file-provider domain
# ("Desktop & Documents Folders" sync). iCloud stamps com.apple.FinderInfo onto
# any .app there — at arbitrary times, LONG after signing — which makes
# `codesign --verify` fail with "resource fork ... not allowed". A broken seal
# no longer matches the recorded TCC grant, so Accessibility silently goes away:
# the hotkey stops firing and injected Cmd+V events are dropped with no error.
# So: stage the bundle in /tmp (never synced), sign it there, then install it to
# ~/Applications (also outside any file-provider domain). Never ship from dist/.
STAGE="$(mktemp -d)"
APP="$STAGE/LocalFlow.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED="$INSTALL_DIR/LocalFlow.app"
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

# Install outside the iCloud-synced tree. --noextattr/--norsrc/--noqtn keep the
# copy free of the xattrs that would invalidate the seal.
echo "▸ Installing to $INSTALLED..."
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED"
ditto --noextattr --norsrc --noqtn "$APP" "$INSTALLED"
xattr -cr "$INSTALLED" 2>/dev/null || true
rm -rf "$STAGE"

# Guard: a bundle whose seal does not validate loses its Accessibility grant at
# runtime, and the only symptom is that dictation silently does nothing. Fail
# here rather than let that reach the menu bar.
if ! codesign --verify --strict "$INSTALLED" 2>/dev/null; then
    echo "✗ Signature does not validate — Accessibility would silently fail:" >&2
    codesign --verify --strict --verbose=2 "$INSTALLED" >&2 || true
    exit 1
fi

echo "✓ Built and verified $INSTALLED"
echo
echo "Run it with:   open $INSTALLED"
echo "(Quit any older copy first — a stale dist/LocalFlow.app may still be running.)"
