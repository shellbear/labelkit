#!/usr/bin/env bash
# Recompile the app icon from its Icon Composer source. Run this after editing
# Resources/AppIcon.icon (in Icon Composer or by hand) and commit the outputs:
#
#   Resources/Assets.car    Liquid Glass icon for macOS 26+, with bitmap fallbacks
#   Resources/AppIcon.icns  legacy icon file for macOS 14–15
#   docs/icon.png           the render shown at the top of the README
#
# The outputs are committed so that package-app.sh — and the release CI — only
# copy files and never depend on an Xcode new enough to read .icon documents.
# This script does: it needs Xcode 26 or later.
set -euo pipefail
cd "$(dirname "$0")/.."

# Absolute on purpose: actool hands the work to a long-lived daemon that resolves
# relative paths against its own working directory, and ictool needs them too.
ICON="$PWD/Resources/AppIcon.icon"
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The deployment target matches Package.swift's .macOS(.v14); it is what makes
# actool emit the pre-Liquid-Glass fallbacks alongside the layered icon.
xcrun actool "$ICON" --compile "$TMP" --app-icon AppIcon --platform macosx \
    --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$TMP/partial.plist" >/dev/null
cp "$TMP/Assets.car" "$TMP/AppIcon.icns" Resources/

"$ICTOOL" "$ICON" --export-image --output-file "$PWD/docs/icon.png" --platform macOS \
    --rendition Default --width 256 --height 256 --scale 2 >/dev/null

echo "compiled Resources/Assets.car, Resources/AppIcon.icns, docs/icon.png"
