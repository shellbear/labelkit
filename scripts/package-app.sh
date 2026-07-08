#!/usr/bin/env bash
# Assemble labelkit.app next to the release binary. A real bundle gives the
# app first-class LaunchServices activation (focus on launch from a terminal
# via the CLI shim), a proper Dock name, and a stable TCC identity.
set -euo pipefail
cd "$(dirname "$0")/.."

# --universal builds an arm64+x86_64 fat binary (used by the release CI).
if [[ "${1:-}" == "--universal" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=.build/apple/Products/Release/labelkit
    mkdir -p .build/release
    cp "$BIN" .build/release/labelkit   # canonical output location either way
else
    swift build -c release
fi
BIN=.build/release/labelkit
APP=.build/release/labelkit.app
VERSION=$(grep -o '"[0-9.]*"' Sources/LabelKit/Version.swift | tr -d '"')

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/labelkit"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>labelkit</string>
    <key>CFBundleIdentifier</key><string>dev.shellbear.labelkit</string>
    <key>CFBundleName</key><string>LabelKit</string>
    <key>CFBundleDisplayName</key><string>LabelKit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- Accept image/folder drops on the Dock icon and via "Open With", which
         AppController routes to importImages(_:). Without this the Dock rejects
         the drop and application(_:open:) never fires. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Image</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null || true
echo "built $APP (v${VERSION})"
