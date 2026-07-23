# AgentBar

**One menu bar item for all your AI coding agents.**

AgentBar is a lightweight, native macOS menu bar app that shows the live state of your
AI coding sessions — Claude Code today, with Codex, GitHub Copilot, and Google
Antigravity in the same bar. Each agent gets its own animated mascot; the bar always
surfaces the session that needs you most.

Created by **Michal Strnadel**.

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
- **Nothing else** — no dock icon, no windows, no timers, no sounds. One process, tiny footprint.

## Install

```bash
./Scripts/build.sh
open "build/AgentBar.app"
```

First launch installs the Claude Code hooks automatically (and the Codex notify hook if
`~/.codex` exists). New agent sessions appear in the bar from then on.

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
approved from the menu — upstream claude-code #12176.)

Codex and Copilot have no decision hooks, so their rows offer *Approve in terminal
(sends keystroke)* — AgentBar focuses the session's terminal and presses the approval
key. Best-effort by design, and it needs the Accessibility permission (the menu item
offers to open System Settings until it's granted).

## How it works

Tiny hook scripts (Node.js) write one JSON file per session to `~/.agentbar/state.d/`.
The app watches that folder and renders. No sockets, no daemons, no network.
Permission approvals use two more folders of the same protocol: the blocking hook
writes `requests.d/`, the app answers into `answers.d/`.

## License

MIT — see [LICENSE](LICENSE). Third-party marks: see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
