#!/usr/bin/env bash
# Builds ClaudexBar with SwiftPM and assembles an ad-hoc signed .app bundle in build/.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/ClaudexBar.app"

swift build -c "$CONFIG" --product ClaudexBar
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClaudexBar" "$APP/Contents/MacOS/ClaudexBar"
cp Support/Info.plist "$APP/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | tail -1

echo "Built $APP"
