#!/bin/bash
# Builds build/AgentBar.app (universal binary). Usage: ./Scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/AgentBar.app"
VERSION="1.11.0"
BUNDLE_ID="com.michalstrnadel.agentbar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Dev builds are artifacts, not installed apps — without this, Spotlight indexes
# build/AgentBar.app and Launchpad shows a second AgentBar next to /Applications.
touch build/.metadata_never_index

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
  <key>NSAppleEventsUsageDescription</key><string>AgentBar selects the exact terminal tab a session runs in when you jump to it.</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Michal Strnadel. MIT licensed.</string>
</dict>
</plist>
PLIST

cp -R Scripts/hooks "$APP/Contents/Resources/hooks"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# TCC keys permission grants to the signing identity, and an ad-hoc signature is
# a brand-new identity every build — macOS would re-ask for Documents access on
# each rebuild. Prefer the stable local cert (CONTRIBUTING shows how to make one).
SIGN_ID="${AGENTBAR_SIGN_ID:-AgentBar Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  codesign --force --deep -s "$SIGN_ID" "$APP"
  echo "Signed with \"$SIGN_ID\""
else
  codesign --force --deep -s - "$APP" 2>/dev/null || true
  echo "Signed ad-hoc — macOS will re-ask for folder permissions on every rebuild"
fi
echo "Built $APP"
