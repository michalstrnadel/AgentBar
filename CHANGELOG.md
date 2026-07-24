# Changelog

All notable changes to AgentBar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## Unreleased

### Fixed
- The CLI test suite no longer inherits `CLAUDE_CONFIG_DIR` from the runner's
  shell — it used to wire the runner's real Claude config to the suite's
  throwaway temp dir, breaking hooks after the temp dir was cleaned up. The env
  is sanitized and a contained `CLAUDE_CONFIG_DIR` regression test was added.

## 1.8.0 - 2026-07-24

### Added
- Linux support via the `agentbar` CLI (`Scripts/cli/agentbar`, plain Node, no
  dependencies): `status`, `requests` (with the inline mini-diff / full command),
  `approve [--always]` / `deny`, `watch` (live view with a/d/q keys), `waybar`
  (JSON for waybar/polybar modules), and `install-hooks` — the Linux counterpart
  of the macOS hook installer, with the same safety rules (never touches an
  unparseable config, writes only on change, pins the Cursor shebang to an
  absolute node).
- Remote Allow/Deny without the macOS app: hooks now also block when a CLI
  watcher heartbeat (`~/.agentbar/watcher.json`, refreshed by `watch`/`waybar`,
  60 s TTL) is fresh — so `agentbar watch` on Linux answers Claude Code
  permission prompts exactly like the menu bar does on macOS.
- `docs/protocol.md`: the `~/.agentbar` file protocol as a normative, OS-neutral
  contract (schemas, atomicity, pruning rules, presence) — any frontend or agent
  bridge can be written against it.
- Test suite for the CLI (`Scripts/test/cli-test.sh`, 17 checks) covering
  listing, pruning, answers, the heartbeat→blocking-hook flow end-to-end, and
  installer safety.

### Changed
- Hook bridge scripts are platform-clean: macOS-only bits (`open`,
  `pgrep -x AgentBar`) are guarded by platform checks; everything else already
  ran on Linux unchanged.

## 1.7.1 - 2026-07-24

### Fixed
- Hook installer: a config file that exists but is not parseable JSON (comments,
  trailing comma, torn write) is now left untouched and logged, instead of being
  silently replaced with only AgentBar's hooks. Applies to Claude `settings.json`,
  `~/.cursor/hooks.json`, and `~/.gemini/settings.json`.
- Cursor hook: the bridge script's shebang is pinned to the resolved absolute
  `node` path at install time. A GUI-launched Cursor inherits the launchd PATH
  (often without `/opt/homebrew/bin`), so `#!/usr/bin/env node` could silently
  never fire.
- Installer consent: `curl … | bash` now really asks "Continue? [Y/n]" by reading
  from the controlling terminal (stdin is the script itself in that mode). With no
  terminal at all (CI), it proceeds as before; `AGENTBAR_YES=1` still skips.
- Gemini: `BeforeAgent` is now registered, so a turn that uses no tools shows
  "thinking" instead of jumping straight to done.
- Re-running the installer without `CLAUDE_CONFIG_DIR` set clears a previously
  recorded custom dir, so hooks stop being wired into a stale location.
- A branch checkout now refreshes the session row while the menu is open (the
  change-detection snapshot ignored project/branch).

### Changed
- Agent configs are only rewritten when their content actually changes — no more
  mtime churn on every launch for tools that watch their config files.
- `node` is resolved once per launch instead of once per agent (up to 4 login-shell
  probes on nvm/fnm setups).
- Cursor now also registers `afterAgentResponse`, so "done" shows right after a
  response, not only at the end of the agent loop. The bridge's event map matches
  exactly what gets registered; permission-gating `before*` hooks stay untouched.

## 1.7.0 - 2026-07-23

### Added
- Live-updating menu: the open dropdown now reflects state as it changes — a
  finished command clears its spinner, a new permission request makes the
  Allow/Deny strip appear, answered requests disappear — without reopening.
- Richer approval context: Claude Code permission rows show what you're approving
  inline — a −old/+new mini-diff for Edit/MultiEdit, the full command for Bash, a
  preview for Write — instead of only a hover tooltip.
- Global Allow/Deny shortcut (opt-in): ⌥⌘A allows and ⌥⌘D denies the newest pending
  request without opening the menu. Off by default; toggle in the menu. No
  Accessibility permission required.
- Cursor CLI and Gemini CLI support: live working/done status via their hook
  systems (`~/.cursor/hooks.json`, `~/.gemini/settings.json`), auto-wired at
  launch (idempotently) for the tools you have. Each gets its own menu mark
  (pointer, spark).
- Mascot micro-animations: idle is calm, working walks, and a task finishing gives
  a brief celebratory hop.

### Changed
- The installer now honors a custom `CLAUDE_CONFIG_DIR` (previously it only wired
  `~/.claude`, so custom-config users silently got no hooks — issue #4).
- The installer prints exactly what it will change before doing anything, and the
  README leads with that footprint. Nothing is touched for tools you don't use.

## 1.6.1 - 2026-07-23

### Fixed
- Open menu: the Codex and Copilot launcher icons now show the clean mascot glyph
  (the knot; the pixel head) without the trailing braille dot-matrix. The animated
  dots belong only in the menu bar; the picker stays crisp.

## 1.6.0 - 2026-07-23

### Added
- Built-in updates: a quiet daily check against GitHub Releases plus a
  "Check for Updates…" row in the menu (current version shown as its badge —
  the separate Version line is gone). One click on "Update to X — Install &
  Relaunch" downloads the release, verifies the bundle version, swaps the app
  in place (with automatic rollback on failure), and relaunches. No Sparkle,
  no windows, no extra processes.

### Fixed
- Menu: the bottom section no longer shows ragged indentation on macOS 26 —
  the update row carries an icon so the section keeps one consistent gutter.

## 1.5.0 - 2026-07-23

### Added
- Animated mascots for the other agents, built from each tool's real visual
  identity: Codex = OpenAI knot + a braille dot-matrix that spells "codex"
  (echo of the Codex CLI thinking indicator); Copilot = GitHub's official
  pixel-art mascot head (traced pixel-by-pixel) + a purple dot-matrix spelling
  "copilot"; Antigravity = the official pixel rainbow arch with a traveling
  color wave. All three animate through the same sprite pipeline as Clawd and
  work in both Color and System (monochrome) modes.
- `Scripts/mascots/`: self-contained generators for the mascot frame sets.
- `docs/archive/2026-07-23-mascot-concepts/`: the original character concepts
  (walking terminal robot, paper plane, astronaut) kept as ready alternatives —
  the paper plane especially is on deck as a reserve Copilot look.

## 1.4.0 - 2026-07-23

### Changed
- New app icon: light ivory squircle with the charcoal prompt chevron and a
  menu-bar-item pill holding the four agent status dots — one lit, three dimmed
  (the session that needs you). Replaces the dark terminal-style icon.

## 1.3.0 - 2026-07-23

### Added
- New "question" state: when Claude asks you something (AskUserQuestion — option
  pickers, plan questions), the session shows a blue dot with the question text
  instead of a false "needs approval"; clicking the row jumps to the session to
  answer. Clears automatically once you reply.
- docs/claude-code-states.md: authoritative mapping of Claude Code hook events to
  AgentBar states, including what's deliberately not consumed and why.

## 1.2.1 - 2026-07-23

### Fixed
- Sessions no longer get stuck on "needs approval": the legacy Notification hook
  could land late (including after the upstream dialog-flash race) and overwrite
  newer state with a stale permission flag. Permission state is now written solely
  by permission.js; the Notification hook is no longer installed and old
  registrations are cleaned up on next launch.
- The permission-dot icon now adapts to the menu bar appearance in System mode
  instead of rendering a hard-black glyph.

## 1.2.0 - 2026-07-23

### Changed
- Approval UI: inline ✓ Allow / ✓ Always / ✕ Deny button strip directly under the
  session row replaces the second-level submenu; the fourth button adapts to the
  session surface (⌨ Terminal for CLI, ⧉ Claude app for desktop). Clicking the
  session row hands the prompt back to that surface.
- "Always allow" now shows the rule as readable text (e.g. `Bash(git push:*)`)
  instead of raw JSON.

### Added
- One-line installer (`Scripts/install.sh`) that fetches the prebuilt universal
  app from the latest GitHub release, plus a Homebrew tap
  (`brew install --cask michalstrnadel/tap/agentbar`).
- README: requirements, uninstall, troubleshooting; SECURITY.md; CI hardening.

## 1.1.0 - 2026-07-23

### Added
- Remote Allow/Deny: answer Claude Code permission prompts from the menu bar —
  see the exact command, then allow once, always-allow with the Claude-suggested
  rule, deny, or defer to the terminal prompt. Every failure mode (app not
  running, timeout, kill) falls back to the normal terminal prompt.
- Best-effort keystroke approval for Codex and Copilot sessions (requires the
  Accessibility permission; clearly labeled in the menu).
- Preferred terminal picker: Open ▸ Terminal lists installed terminals; the
  checkmarked one is remembered and used for Open actions.

## 1.0.0 - 2026-07-23

First release. A clean-room rewrite of the AI Status Notifier concept as a
multi-agent menu bar app.

### Added
- Menu bar mascot animation per agent while it works: Clawd the crab (Claude),
  OpenAI mark (Codex), Copilot goggles, Antigravity mark.
- Amber permission dot the moment any agent waits for approval; permission
  outranks working, working outranks idle when picking what the bar shows.
- Sessions menu: one row per live session with project name, git branch, live
  state and agent tag; click to focus that app or terminal.
- Open submenu: Claude app, Codex, Copilot, Antigravity, or a terminal.
- Color modes: Color (each agent in its brand color) and System (adaptive
  monochrome that matches the menu bar).
- Rotating thinking verbs next to the mascot while an agent works.
- Claude Code hooks (full fidelity: prompt, tool use, permission, stop,
  session lifecycle) and a Codex `notify` adapter; hook install is automatic
  and idempotent on first launch.
