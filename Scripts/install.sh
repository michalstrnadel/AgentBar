#!/bin/bash
# AgentBar installer — https://github.com/michalstrnadel/AgentBar
# Usage: curl -fsSL https://raw.githubusercontent.com/michalstrnadel/AgentBar/main/Scripts/install.sh | bash
# Env: AGENTBAR_INSTALL_DIR to install somewhere other than /Applications.
set -euo pipefail

# TMP is global: the EXIT trap fires after main() returns, past any local scope.
TMP=""

# Everything inside main() so a truncated download can never execute half a script.
main() {
  local REPO="michalstrnadel/AgentBar"
  local DEST
  if [ -n "${AGENTBAR_INSTALL_DIR:-}" ]; then
    DEST="$AGENTBAR_INSTALL_DIR"
    mkdir -p "$DEST"
  else
    DEST="/Applications"
    # Non-admin users can't write /Applications; fall back to ~/Applications.
    if [ ! -w "$DEST" ]; then
      DEST="$HOME/Applications"
      mkdir -p "$DEST"
    fi
  fi
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  echo "AgentBar installer — $REPO"

  # Prefer the prebuilt universal app from the latest release; else build from source.
  # No python/CLT dependency here — the prebuilt path must work on a bare Mac, and
  # API failures (no releases yet, rate limit) must fall through to the source build.
  local ZIP_URL
  ZIP_URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null |
    grep -o '"browser_download_url": *"[^"]*AgentBar\.app\.zip"' | head -1 | cut -d'"' -f4)" || ZIP_URL=""

  local APP
  if [ -n "$ZIP_URL" ]; then
    echo "Downloading prebuilt app: $ZIP_URL"
    curl -fsSL -o "$TMP/AgentBar.app.zip" "$ZIP_URL"
    ditto -x -k "$TMP/AgentBar.app.zip" "$TMP/unpacked"
    APP="$TMP/unpacked/AgentBar.app"
  else
    echo "No prebuilt release reachable — building from source (needs Xcode CLT)…"
    git clone --quiet --depth 1 "https://github.com/$REPO.git" "$TMP/src"
    (cd "$TMP/src" && ./Scripts/build.sh)
    APP="$TMP/src/build/AgentBar.app"
  fi

  [ -d "$APP" ] || { echo "install failed: no app bundle produced" >&2; exit 1; }

  # pkill needs no automation permission (unlike osascript quit).
  pkill -x AgentBar 2>/dev/null || true
  sleep 1
  rm -rf "$DEST/AgentBar.app"
  ditto "$APP" "$DEST/AgentBar.app"
  # Ad-hoc signed app: clear quarantine so the launch you just asked for isn't blocked.
  xattr -dr com.apple.quarantine "$DEST/AgentBar.app" 2>/dev/null || true

  # Bridge a custom CLAUDE_CONFIG_DIR to the app (launched via `open`, it can't see the
  # shell env). The app reads this hint and wires hooks into that config too (issue #4).
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    mkdir -p "$HOME/.agentbar"
    printf '%s\n' "$CLAUDE_CONFIG_DIR" > "$HOME/.agentbar/claude-config-dir"
  fi

  open "$DEST/AgentBar.app"

  echo
  echo "✓ AgentBar installed to $DEST/AgentBar.app and launched."
  echo "  Hooks install automatically. Start a NEW agent session to see it in the bar."
}

main "$@"
