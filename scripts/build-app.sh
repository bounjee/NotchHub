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
# Regenerate with: ./scripts/make-icon.sh
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# English is the development language (the keys); other languages live in <lang>.lproj.
for lproj in Resources/*.lproj; do cp -R "$lproj" "$APP/Contents/Resources/"; done

# The release version lives in VERSION; tag releases with it (v1.1.0).
SHORT_VERSION="$(tr -d '[:space:]' < VERSION)"
# Build number: the commit count, so every pushed commit builds a higher version.
VERSION="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>agency.ehli.notchhub</string>
    <key>CFBundleName</key><string>NotchHub</string>
    <key>CFBundleDisplayName</key><string>NotchHub</string>
    <key>CFBundleExecutable</key><string>NotchHub</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
    <key>NSAppleEventsUsageDescription</key><string>To bring the terminal tab of a Claude Code session to the front.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>To put finished downloads on the shelf.</string>
    <key>NSDesktopFolderUsageDescription</key><string>To show previews of new screenshots on the shelf.</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
echo "Built $APP"
