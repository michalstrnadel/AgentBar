#!/bin/bash
# Builds build/AgentBar.app (universal binary). Usage: ./Scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/AgentBar.app"
VERSION="1.2.1"
BUNDLE_ID="com.michalstrnadel.agentbar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling universal binary (arm64 + x86_64)…"
# swiftc emits one arch per -target: two compiles joined by lipo (works with plain CLT,
# no full Xcode needed). Deployment target pinned so the binary matches Info.plist.
BIN="$APP/Contents/MacOS/AgentBar"
SWIFT_FILES=$(find Sources/AgentBar -name "*.swift")
swiftc -O -target arm64-apple-macos12.0  $SWIFT_FILES -o "$BIN.arm64"  -framework Cocoa
swiftc -O -target x86_64-apple-macos12.0 $SWIFT_FILES -o "$BIN.x86_64" -framework Cocoa
lipo -create "$BIN.arm64" "$BIN.x86_64" -output "$BIN"
rm -f "$BIN.arm64" "$BIN.x86_64"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AgentBar</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>AgentBar</string>
  <key>CFBundleDisplayName</key><string>AgentBar</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Michal Strnadel. MIT licensed.</string>
</dict>
</plist>
PLIST

cp -R Scripts/hooks "$APP/Contents/Resources/hooks"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep -s - "$APP" 2>/dev/null || true
echo "Built $APP"
