#!/bin/zsh
# Builds dist/NotchHub.app (release, ad-hoc signed).
set -euo pipefail

cd "${0:A:h}/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="dist/NotchHub.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NotchHub" "$BIN/notch-hook" "$APP/Contents/MacOS/"

VERSION="$(git describe --tags --always 2>/dev/null || echo 1.0)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>agency.ehli.notchhub</string>
    <key>CFBundleName</key><string>NotchHub</string>
    <key>CFBundleDisplayName</key><string>NotchHub</string>
    <key>CFBundleExecutable</key><string>NotchHub</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDevelopmentRegion</key><string>tr</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
echo "Built $APP"
