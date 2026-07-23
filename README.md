<p align="center">
  <img src="docs/assets/icon.png?v=1.4.0" width="128" alt="AgentBar icon">
</p>

# AgentBar

[![CI](https://github.com/michalstrnadel/AgentBar/actions/workflows/ci.yml/badge.svg)](https://github.com/michalstrnadel/AgentBar/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS 12+](https://img.shields.io/badge/macOS-12%2B-black)
![Swift](https://img.shields.io/badge/Swift-AppKit-orange)

**One menu bar item for all your AI coding agents.**

AgentBar is a lightweight, native macOS menu bar app that shows the live state of your
AI coding sessions — Claude Code today, with Codex, GitHub Copilot, and Google
Antigravity in the same bar. Each agent gets its own animated mascot; the bar always
surfaces the session that needs you most.

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

## Features

- **Live status per agent** — an animated mascot walks the bar while an agent works
  (Clawd the crab for Claude; each agent has its own mark).
- **Permission alerts** — an amber dot the moment an agent waits for your approval.
- **Multi-session** — every running session listed with project, git branch, and state;
  click a row to jump to its app or terminal.
- **Open anything** — launch Claude, Codex, Copilot, or Antigravity straight from the menu.
- **Two looks** — full-color mascots, or a monochrome System mode that matches the menu bar.
- **Remote Allow/Deny** — answer Claude Code permission prompts straight from the menu:
  see exactly what's requested, then Allow once, Always allow, Deny, or defer to terminal.
- **Nothing else** — no dock icon, no windows, no countdown timers, no sounds. One process, tiny footprint.

## Requirements

- macOS 12+ (Apple Silicon or Intel)
- Node.js (for the hook scripts; found via Homebrew paths or your login shell)
- Xcode Command Line Tools to build from source

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

> **What install touches:** hook scripts are copied to `~/.agentbar/hooks/`, hook
> entries are merged into `~/.claude/settings.json` (existing hooks are preserved),
> and a `notify` line is added to `~/.codex/config.toml` only if none exists.
> The Claude SessionStart hook also auto-launches AgentBar in the background when a
> session begins. Hooks are snapshotted per session — start a new agent session after
> installing.
> If you run Claude Code with a custom `CLAUDE_CONFIG_DIR`, see issue #4.

## Uninstall

```bash
osascript -e 'quit app "AgentBar"'
rm -rf ~/.agentbar
# remove the AgentBar hook entries (they all reference ~/.agentbar/hooks/):
#   ~/.claude/settings.json  — delete rules whose command contains "/.agentbar/hooks/"
#   ~/.codex/config.toml     — delete the notify line referencing "/.agentbar/hooks/"
```

## Agent support

| Agent | Live status | Open | Notes |
|---|---|---|---|
| Claude Code (CLI + desktop) | full | yes | hooks: prompt, tool, permission, stop, lifecycle |
| Codex CLI | turn-complete | yes | via Codex `notify`; no per-tool granularity upstream |
| GitHub Copilot | — | yes | no public event API yet; mascot ready |
| Google Antigravity | — | yes | no public event API yet; mascot ready |

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
