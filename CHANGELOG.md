# Changelog

All notable changes to AgentBar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

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
