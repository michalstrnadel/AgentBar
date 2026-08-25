#!/bin/bash
# Installs (or removes) the agentbar-cloud launchd agent for the current user.
# Usage: ./Scripts/cloud/install.sh [uninstall]
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.michalstrnadel.agentbar.cloud"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
NODE="$(command -v node)"
INDEX="$PWD/index.js"
LOG="$HOME/Library/Logs/agentbar-cloud.log"

if [ "${1:-}" = "uninstall" ]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL"
  exit 0
fi

[ -n "$NODE" ] || { echo "node not found on PATH" >&2; exit 1; }

CONFIG="$HOME/.agentbar/cloud.json"
if [ ! -f "$CONFIG" ]; then
  mkdir -p "$HOME/.agentbar"
  cat > "$CONFIG" <<'JSON'
{
  "cursor": { "enabled": false, "apiKey": "" },
  "devin":  { "enabled": false, "apiKey": "" },
  "codex":  { "enabled": true }
}
JSON
  chmod 600 "$CONFIG"
  echo "Wrote starter $CONFIG (chmod 600) — add API keys and set enabled: true per vendor."
fi

mkdir -p "$(dirname "$PLIST")"
# launchd has a bare PATH: node is addressed absolutely and PATH is widened so
# the codex adapter can find its CLI (Homebrew) without guessing.
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>$INDEX</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(dirname "$NODE"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL (logs: $LOG)"
