#!/bin/bash
# Builds build/AgentBar.app (universal binary). Usage: ./Scripts/build.sh [--native]
#
# --native builds for this Mac's architecture only. It exists because a machine
# with just the Command Line Tools may not be able to link the other one: recent
# CLT versions ship libswiftCompatibility*.a for arm64 only, so the x86_64 half
# dies on "Undefined symbols … __swift_FORCE_LOAD_$_swiftCompatibility56".
# Releases must stay universal, so this flag is for local runs only — never CI,
# which has a full Xcode and both slices.
set -euo pipefail
cd "$(dirname "$0")/.."

NATIVE=0
for arg in "$@"; do
  case "$arg" in
    --native) NATIVE=1 ;;
    *) echo "unknown option: $arg (usage: $0 [--native])" >&2; exit 2 ;;
  esac
done

APP="build/AgentBar.app"
VERSION="1.37.0"
BUNDLE_ID="com.michalstrnadel.agentbar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Dev builds are artifacts, not installed apps — without this, Spotlight indexes
# build/AgentBar.app and Launchpad shows a second AgentBar next to /Applications.
touch build/.metadata_never_index

# swiftc emits one arch per -target: two compiles joined by lipo (works with plain CLT,
# no full Xcode needed). Deployment target pinned so the binary matches Info.plist.
BIN="$APP/Contents/MacOS/AgentBar"
SWIFT_FILES=$(find Sources/AgentBar -name "*.swift")
if [ "$NATIVE" = 1 ]; then
  ARCH="$(uname -m)"
  echo "Compiling native binary ($ARCH only — dev build, not shippable)…"
  swiftc -O -target "$ARCH-apple-macos12.0" $SWIFT_FILES -o "$BIN" -framework Cocoa
else
  echo "Compiling universal binary (arm64 + x86_64)…"
  swiftc -O -target arm64-apple-macos12.0  $SWIFT_FILES -o "$BIN.arm64"  -framework Cocoa
  swiftc -O -target x86_64-apple-macos12.0 $SWIFT_FILES -o "$BIN.x86_64" -framework Cocoa
  lipo -create "$BIN.arm64" "$BIN.x86_64" -output "$BIN"
  rm -f "$BIN.arm64" "$BIN.x86_64"
fi

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
  <!-- Deliberately NO LSUIElement. main.swift sets .accessory before the app runs,
       which keeps the dock icon away just as well — and macOS refuses notification
       authorization outright to a bundle that declares LSUIElement, with no prompt
       and no entry in System Settings to turn on. Declaring it here bought nothing
       and cost the whole Notifications feature. -->
  <key>NSAppleEventsUsageDescription</key><string>AgentBar selects the exact terminal tab a session runs in when you jump to it.</string>
  <!-- The folder prompts: reading .git/HEAD and the working tree of a project an
       agent works in (the branch on a row, what a session changed) is what asks.
       Without these the system dialog explains nothing, and it is the first thing
       a new install shows. -->
  <key>NSDocumentsFolderUsageDescription</key><string>AgentBar reads the git branch and changes of the projects your agents work in, to show them next to each session. Nothing leaves this Mac.</string>
  <key>NSDesktopFolderUsageDescription</key><string>AgentBar reads the git branch and changes of the projects your agents work in, to show them next to each session. Nothing leaves this Mac.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>AgentBar reads the git branch and changes of the projects your agents work in, to show them next to each session. Nothing leaves this Mac.</string>
  <!-- agentbar:// for Shortcuts, Raycast and scripts (docs/url-scheme.md). Any web
       page can open one of these too, so every command shows something and none
       answers, writes or runs anything — see Sources/AgentBar/URLCommands.swift. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>${BUNDLE_ID}</string>
      <key>CFBundleURLSchemes</key><array><string>agentbar</string></array>
    </dict>
  </array>
  <key>NSHumanReadableCopyright</key><string>© 2026 Michal Strnadel. MIT licensed.</string>
</dict>
</plist>
PLIST

cp -R Scripts/hooks "$APP/Contents/Resources/hooks"
# The Claude Code mod (Scripts/mods/claude). Copied to ~/.agentbar/mods/ on every
# launch like the hooks, and loaded by Claude Code only once the person switches it
# on (Settings ▸ Agents ▸ Claude Code mod) — bundling it wires nothing.
[ -d Scripts/mods ] && cp -R Scripts/mods "$APP/Contents/Resources/mods"
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
