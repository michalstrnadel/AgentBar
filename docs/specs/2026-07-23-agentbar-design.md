# AgentBar

> Extended by: [Remote Allow/Deny design](2026-07-23-remote-approval-design.md) — design

## Goal
A from-scratch, best-practices rewrite of AI Status Notifier as a multi-agent macOS
menu bar app. Simpler than its predecessor: no timer, no completion sound, no
animation-style picker, no toggles. One mascot per agent, one menu, two color modes.

## Architecture

Data flow: `agent hooks (Node) → ~/.agentbar/state.d/<session>.json → SessionStore
(folder watch) → StatusItemController (icon + words) / MenuBuilder (dropdown)`.

Units, one file each, single responsibility:

- **Agents.swift** — the `Agent` registry: id, display name, brand color, sprite,
  open action. Adding an agent = adding one entry + one sprite + (optionally) hooks.
- **Session.swift** — session model; decodes a state.d JSON file.
- **SessionStore.swift** — watches state.d (DispatchSource + timer fallback), prunes
  dead sessions (pid liveness), publishes a sorted snapshot.
- **IconRenderer.swift** — decodes sprite frames once; tints monochrome logos with
  the agent brand color (Color mode) or renders adaptive templates (System mode);
  synthesizes a bob animation for single-frame logo mascots.
- **StatusItemController.swift** — owns NSStatusItem; picks the top-priority session
  (permission > working > idle), drives the animation timer and thinking verbs.
- **MenuBuilder.swift** — builds the dropdown from a snapshot. Stateless.
- **HookInstaller.swift** — first-launch, idempotent: copies hook scripts to
  `~/.agentbar/hooks/`, merges Claude hooks into `~/.claude/settings.json`, appends
  Codex `notify` to `~/.codex/config.toml` when `~/.codex` exists.

## State protocol
One JSON per session: `{agent, state, label, project, cwd, sessionId, entrypoint,
term_program, pid, started, ts}`. `state ∈ idle|thinking|tool|permission|done`.
Files are the unit of liveness: written atomically, removed on SessionEnd, pruned
when their pid dies.

## Menu
Sessions rows (project · branch, state dot, agent tag) → Open ▸ (Claude, Codex,
Copilot, Antigravity, Terminal) → Color ▸ (Color, System) → Version 1.0.0, Quit.

## Non-goals
Timers, sounds, per-style animation settings, update checker (v1), dock presence.

## Agent event support (honest)
Claude: full hooks. Codex: `notify` fires on turn completion only — session appears
after its first completed turn, no live "working" state upstream. Copilot,
Antigravity: no public event APIs; Open + mascots ship ready, live status waits on
upstream.
