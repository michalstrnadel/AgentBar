#!/usr/bin/env bash
# Runs a copy of build/AgentBar.app next to the installed one, on a state directory
# of its own, so the island and the menu can be tried with made-up sessions without
# touching ~/.agentbar, the installed app, or any agent's settings.
#
#   ./Scripts/build.sh && Scripts/dev/sandbox.sh [--fresh] [DIR]
#
# DIR defaults to $TMPDIR/agentbar-sandbox. The copy gets its own bundle id, so its
# preferences are its own too, and no URL scheme, so agentbar:// links still go to
# the installed app. Under AGENTBAR_HOME the app wires no agent and never installs
# an update by itself (see AgentBarHome.swift). Feed it with the CLI:
#
#   export AGENTBAR_HOME=DIR/state
#   Scripts/cli/agentbar report --agent aider --name Aider --state tool --label Editing
#
# Quit it from its own menu, or: pkill -f "AgentBar Sandbox.app"
set -euo pipefail

fresh=0
if [[ "${1:-}" == "--fresh" ]]; then fresh=1; shift; fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
dir="${1:-${TMPDIR:-/tmp}/agentbar-sandbox}"
dir="${dir%/}"
case "$dir" in /*) ;; *) echo "sandbox: DIR must be absolute" >&2; exit 2 ;; esac
case "$dir" in "$HOME/.agentbar"|"$HOME/.agentbar/"*)
  echo "sandbox: refusing to use the real ~/.agentbar" >&2; exit 2 ;; esac

src="$root/build/AgentBar.app"
[[ -d "$src" ]] || { echo "sandbox: build first: ./Scripts/build.sh" >&2; exit 1; }

app="$dir/AgentBar Sandbox.app"
state="$dir/state"
pkill -f "$app/Contents/MacOS/AgentBar" 2>/dev/null || true
if [[ $fresh == 1 && -d "$state" ]]; then
  mv "$state" "$state.old-$(date +%s)"
fi
mkdir -p "$dir" "$state"
# Replaced whole every run: a copy left over from an older build is the bug report
# nobody can reproduce.
rm -rf "$app"
ditto "$src" "$app"

plist="$app/Contents/Info.plist"
id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id.sandbox" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName AgentBar Sandbox" "$plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$plist" 2>/dev/null || true
codesign --force --deep -s - "$app" >/dev/null 2>&1

# The binary, not `open`: LaunchServices would drop the variable, and launching it
# directly also skips the Documents-access prompt a fresh copy in a new place gets.
AGENTBAR_HOME="$state" nohup "$app/Contents/MacOS/AgentBar" >"$dir/sandbox.log" 2>&1 &
echo "sandbox: running (pid $!), log $dir/sandbox.log"
echo "export AGENTBAR_HOME=$state"
