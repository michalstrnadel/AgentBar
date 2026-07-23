#!/bin/bash
# AgentBar installer — https://github.com/michalstrnadel/AgentBar
# Usage: curl -fsSL https://raw.githubusercontent.com/michalstrnadel/AgentBar/main/Scripts/install.sh | bash
# Env: AGENTBAR_INSTALL_DIR to install somewhere other than /Applications.
set -euo pipefail

REPO="michalstrnadel/AgentBar"
DEST="${AGENTBAR_INSTALL_DIR:-/Applications}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "AgentBar installer — $REPO"

# Prefer the prebuilt universal app from the latest release; else build from source.
ZIP_URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
  /usr/bin/python3 -c 'import json,sys
assets = json.load(sys.stdin).get("assets", [])
print(next((a["browser_download_url"] for a in assets if a["name"] == "AgentBar.app.zip"), ""))')"

if [ -n "$ZIP_URL" ]; then
  echo "Downloading prebuilt app: $ZIP_URL"
  curl -fsSL -o "$TMP/AgentBar.app.zip" "$ZIP_URL"
  ditto -x -k "$TMP/AgentBar.app.zip" "$TMP/unpacked"
  APP="$TMP/unpacked/AgentBar.app"
else
  echo "No prebuilt release asset found — building from source (needs Xcode CLT)…"
  git clone --quiet --depth 1 "https://github.com/$REPO.git" "$TMP/src"
  (cd "$TMP/src" && ./Scripts/build.sh)
  APP="$TMP/src/build/AgentBar.app"
fi

[ -d "$APP" ] || { echo "install failed: no app bundle produced" >&2; exit 1; }

osascript -e 'quit app "AgentBar"' 2>/dev/null || true
rm -rf "$DEST/AgentBar.app"
ditto "$APP" "$DEST/AgentBar.app"
# Ad-hoc signed app: clear quarantine so the launch you just asked for isn't blocked.
xattr -dr com.apple.quarantine "$DEST/AgentBar.app" 2>/dev/null || true
open "$DEST/AgentBar.app"

echo
echo "✓ AgentBar installed to $DEST/AgentBar.app and launched."
echo "  Hooks install automatically. Start a NEW agent session to see it in the bar."
