# <img src="docs/assets/app-icon.png" width="42" alt="" align="top"> AgentBar

[![CI](https://github.com/michalstrnadel/AgentBar/actions/workflows/ci.yml/badge.svg)](https://github.com/michalstrnadel/AgentBar/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS 12+](https://img.shields.io/badge/macOS-12%2B-black)
![Linux CLI](https://img.shields.io/badge/Linux-CLI-yellow)
![Swift](https://img.shields.io/badge/Swift-AppKit-orange)

**One menu bar item for all your AI coding agents.**

<p align="center">
  <img src="docs/assets/demo-claude-codex.gif" width="640" alt="AgentBar demo: Claude session works, needs approval, one-click Allow, then a Codex session takes over the bar">
</p>

AgentBar is a lightweight, native macOS menu bar app that shows the live state of your
AI coding sessions — Claude Code, Codex, Cursor CLI, Gemini CLI, plus GitHub Copilot
and Google Antigravity in the same bar. Each agent gets its own mark built from its
real identity — Clawd the crab for Claude, the OpenAI knot with a braille dot-matrix
for Codex, the official pixel-art head for Copilot, the pixel rainbow arch for
Antigravity — and the bar always surfaces the session that needs you most.
On Linux, the same protocol drives the [`agentbar` CLI](#linux-cli).
On Windows, [AgentBar for Windows](https://github.com/michalstrnadel/AgentBar-Windows) is a
native system-tray counterpart that shares the same `~/.agentbar` hook protocol.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/michalstrnadel/AgentBar/main/Scripts/install.sh | bash
```

1. The app lands in `/Applications`, launches, and installs its Claude Code hooks.
2. Open a **new** Claude Code session (hooks load at session start) and give it any task.
3. Watch the menu bar: the mascot animates while the agent works, and the moment it
   asks for permission you get a yellow **needs approval** row — click **✓ Allow**,
   **✓ Always**, or **✕ Deny** right there. No terminal switch needed.

That's the whole loop. More install options below; troubleshooting at the bottom.

### What the installer changes (and how to undo it)

AgentBar is local-only — no network, no telemetry. The install touches exactly these,
all reversible (see [Uninstall](#uninstall)):

- Copies the hook scripts to `~/.agentbar/hooks/`.
- Merges AgentBar hook entries into your Claude Code settings — `~/.claude/settings.json`,
  and your `CLAUDE_CONFIG_DIR` if you set one. Existing hooks are preserved.
- Adds a `notify` line to `~/.codex/config.toml` **only if you use Codex and have none**;
  merges into `~/.cursor/hooks.json` / `~/.gemini/settings.json` **only if those exist**.
- The SessionStart hook launches AgentBar in the background when an agent session begins.

The installer prints this summary before doing anything, and never modifies a tool you
don't use. Hooks are snapshotted per session — start a new agent session afterward.

## Features

- **Live status per agent** — an animated mascot works the bar while an agent works:
  Clawd the crab (Claude), the knot + a braille dot-matrix that literally spells
  *codex* (Codex), the pixel mascot head + dots spelling *copilot* (Copilot), and the
  animated pixel rainbow arch (Antigravity).
- **Permission alerts** — an amber dot the moment an agent waits for your approval.
- **Multi-session** — every running session listed with project, git branch, and state;
  click a row to jump to its app or terminal.
- **Open anything** — launch Claude, Codex, Copilot, or Antigravity straight from the menu.
- **Two looks** — full-color mascots, or a monochrome System mode that matches the menu bar.
- **Remote Allow/Deny** — answer Claude Code permission prompts straight from the menu:
  see exactly what's requested, then Allow once, Always allow, Deny, or defer to terminal.
- **Built-in updates** — a quiet daily check of GitHub Releases plus **Check for
  Updates…** in the menu; one click installs the new version and relaunches.
- **Linux too** — the [`agentbar` CLI](#linux-cli) is a full peer of the menu bar app:
  live status, pending approvals, `a`/`d` remote Allow/Deny, waybar module.
- **Nothing else** — no dock icon, no windows, no countdown timers, no sounds. One process, tiny footprint.

## Requirements

- macOS 12+ (Apple Silicon or Intel) for the menu bar app — or Linux via the
  [`agentbar` CLI](#linux-cli)
- Node.js (for the hook scripts; found via Homebrew paths or your login shell)
- Xcode Command Line Tools to build the macOS app from source

## Install

**One-liner** — downloads the latest release (or builds from source when none exists):

```bash
curl -fsSL https://raw.githubusercontent.com/michalstrnadel/AgentBar/main/Scripts/install.sh | bash
```

**Homebrew:**

```bash
brew install --cask michalstrnadel/tap/agentbar
```

**Via your AI agent** — paste into Claude Code (or any coding agent):

> Install AgentBar: run
> `curl -fsSL https://raw.githubusercontent.com/michalstrnadel/AgentBar/main/Scripts/install.sh | bash`

**From source:**

```bash
git clone https://github.com/michalstrnadel/AgentBar.git && cd AgentBar
./Scripts/build.sh
open "build/AgentBar.app"
```

First launch installs the Claude Code hooks automatically (and the Codex notify hook if
`~/.codex` exists). New agent sessions appear in the bar from then on.

**Updating:** the app checks GitHub Releases daily and offers new versions in the menu
(**Check for Updates…** works any time). Homebrew users can keep using
`brew upgrade --cask agentbar` — both paths install the same bundle.

> **What install touches:** hook scripts are copied to `~/.agentbar/hooks/`, hook
> entries are merged into your Claude `settings.json` (`~/.claude` **and** a custom
> `CLAUDE_CONFIG_DIR`, both; existing hooks are preserved), a `notify` line is added
> to `~/.codex/config.toml` only if none exists, and — only for tools you already
> have — hook entries are merged into `~/.cursor/hooks.json` and
> `~/.gemini/settings.json`. A config that exists but isn't valid JSON is never
> touched. The Claude SessionStart hook also auto-launches AgentBar in the
> background when a session begins. Hooks are snapshotted per session — start a new
> agent session after installing.

## Linux (CLI)

The protocol is just files (`~/.agentbar`, see [docs/protocol.md](docs/protocol.md))
and the hooks are plain Node — so on Linux, the `agentbar` CLI is the frontend:

```bash
git clone https://github.com/michalstrnadel/AgentBar.git && cd AgentBar
./Scripts/cli/agentbar install-hooks   # wires Claude/Codex/Cursor/Gemini hooks
sudo ln -s "$PWD/Scripts/cli/agentbar" /usr/local/bin/agentbar   # optional

agentbar                 # session list (same rows as the macOS menu)
agentbar watch           # live view; a = allow, d = deny, q = quit
agentbar requests        # pending approvals with the mini-diff / full command
agentbar approve --always
```

Remote Allow/Deny works exactly like on macOS: while `agentbar watch` (or a
`waybar` poll) is running, a Claude Code permission prompt appears in the CLI and
your `a`/`d` answers it; with no watcher running, hooks stay silent and the normal
terminal prompt appears. Waybar module:

```jsonc
"custom/agentbar": {
  "exec": "agentbar waybar", "return-type": "json", "interval": 15
}
```

The CLI works on macOS too (same protocol, handy over SSH). A native tray app
(StatusNotifierItem) may come later if there's demand.

## Uninstall

```bash
osascript -e 'quit app "AgentBar"'
rm -rf ~/.agentbar
# remove the AgentBar hook entries (they all reference ~/.agentbar/hooks/):
#   ~/.claude/settings.json (and your CLAUDE_CONFIG_DIR) — delete rules whose command contains "/.agentbar/hooks/"
#   ~/.codex/config.toml       — delete the notify line referencing "/.agentbar/hooks/"
#   ~/.cursor/hooks.json       — delete entries whose command references "/.agentbar/hooks/cursor/"
#   ~/.gemini/settings.json    — delete hook groups whose command references "/.agentbar/hooks/gemini/"
```

## Agent support

| Agent | Live status | Open | Mascot | Notes |
|---|---|---|---|---|
| Claude Code (CLI + desktop) | full | yes | Clawd the crab | hooks: prompt, tool, permission, stop, lifecycle |
| Codex CLI | turn-complete | yes | knot + braille dot-matrix | via Codex `notify` (auto-installed); no per-tool granularity upstream |
| Cursor CLI | working / done | yes | pointer | hooks in `~/.cursor/hooks.json` (auto-wired if Cursor is installed) |
| Gemini CLI | working / done | yes | spark | hooks in `~/.gemini/settings.json` (auto-wired if Gemini is installed) |
| GitHub Copilot | — | yes | pixel head + dot-matrix | no public event API yet; everything else is wired and waiting |
| Google Antigravity | working / done | yes | pixel rainbow arch + dot-matrix | hooks in `~/.gemini/antigravity{,-cli}/hooks.json` (auto-wired); desktop 2.3.x only honors per-workspace `.agents/hooks.json`, and only `PostToolUse` fires — quiet sessions decay to done |

Hook readiness: Claude Code, Codex (`notify`), Cursor (`hooks.json`), Gemini
(`settings.json`), and Antigravity (`hooks.json`) hooks all install automatically at launch (idempotently — every
launch re-checks, nothing is duplicated) for the tools you have. Copilot ships with its mascot, menu entry, and
the keystroke-approval backend already in place — the moment it exposes session
events, support is one small hook script away.

## Remote Allow/Deny

When a Claude Code session asks for permission, the request appears right under the
yellow "needs approval" row: what's requested (e.g. `Bash: git push origin main`; full
input in the tooltip) plus an inline button strip — **✓ Allow**, **✓ Always** (only
when Claude Code suggests a rule; the rule is in the tooltip), **✕ Deny**, and
**⌨ Terminal** / **⧉ Claude app** to answer in the session's own UI instead. Clicking
the session row does the same hand-off. Decisions return through Claude Code's PermissionRequest hook,
so the terminal prompt never appears; if AgentBar isn't running, quits mid-wait, or
you ignore the request for 10 minutes, the prompt shows in the terminal exactly as
before. (Known cosmetic issue: the terminal dialog can flash briefly even when
approved from the menu — upstream [claude-code #12176](https://github.com/anthropics/claude-code/issues/12176).)

Codex and Copilot have no decision hooks, so their rows offer *Approve in terminal
(sends keystroke)* — AgentBar focuses the session's terminal and presses the approval
key. Best-effort by design, and it needs the Accessibility permission (the menu item
offers to open System Settings until it's granted).

## How it works

Tiny hook scripts (Node.js) write one JSON file per session to `~/.agentbar/state.d/`.
The app watches that folder and renders. No sockets, no daemons, no network.
Permission approvals use two more folders of the same protocol: the blocking hook
writes `requests.d/`, the app answers into `answers.d/`.

## Troubleshooting

- **No sessions appear** — hooks load when a session starts: open a *new* agent
  session after installing. If you use a custom `CLAUDE_CONFIG_DIR`, see
  [issue #4](https://github.com/michalstrnadel/AgentBar/issues/4).
- **Still nothing** — the installer needs `node`; if none is found the Claude hooks
  are skipped (logged to Console.app). Install Node.js and relaunch AgentBar.
- **Codex rows never show** — if `~/.codex/config.toml` already had a `notify`
  entry, AgentBar deliberately leaves it alone; wire `Scripts/hooks/codex/notify.js`
  into your existing notify chain manually.
- **Keystroke approval does nothing** — grant AgentBar the Accessibility permission
  (the menu item offers to open System Settings).
- **macOS says it "cannot verify AgentBar is free of malware"** — the app is ad-hoc
  signed, not notarized. Don't click *Move to Trash*; click *Done*, then either
  right-click the app ▸ Open, or run
  `xattr -dr com.apple.quarantine /Applications/AgentBar.app` and open it again.
  The install script and the Homebrew cask do this for you; the dialog mainly
  appears after downloading the zip manually from Releases.

## License

MIT — see [LICENSE](LICENSE). Third-party marks: see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
