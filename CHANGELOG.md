# Changelog

All notable changes to AgentBar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## Unreleased

### Changed
- Every island row carries its agent's mark now, not just the hero — the mark
  says *who*, the coloured dot keeps saying *what state*, and all row text sits
  on the hero's column.

## 1.10.2 - 2026-07-29

### Fixed
- **The island opens on arrival, not on presence.** Opening now requires the
  pointer to actually *travel* into the notch zone — a pointer that was already
  parked there (reading a tab title, left behind by a Space switch) opens
  nothing. Push up → 0.3 s dwell → open; leave → 0.35 s grace → close. The pill
  itself is a hover target again too, which is what makes the floating pill on
  notch-less displays openable at all.
- **The pill tucks fully inside the physical island.** Drawn a hair narrower
  than the notch (its width − 10 pt), so its corners no longer poke out past
  the notch's curved bottom edge. Every size still comes from the screen's own
  reported geometry at runtime — each MacBook's notch, any scaling mode, gets
  its own numbers, and displays without a notch keep the centred floating pill.
- **Rows never wrap.** A long task name used to wrap to a second line inside
  the fixed row height, shoving the mascot half out of view and tearing the
  panel apart. Every row label is a single truncating line now.

### Changed
- **Builds sign with a stable identity, so macOS finally remembers.** TCC keys
  permission grants to the code-signing identity, and an ad-hoc signature is a
  brand-new identity every build — that is why the "Documents access" dialog
  kept coming back. `build.sh` now signs with a local `AgentBar Local Signing`
  certificate when one exists (ad-hoc fallback without it), release builds
  share that certificate, and grants survive rebuilds and cask upgrades alike
  (#9). CONTRIBUTING shows the one-time cert setup.

## 1.10.1 - 2026-07-29

### Added
- The README shows both surfaces now: a second demo GIF walks the Dynamic Island
  flow — the pill under the notch says *approve?*, the panel inflates out of the
  notch with the mini-diff, one click on Allow, and the pill flashes ✓ Allowed.
  Generator checked in as `Scripts/demo/demo-island-gif.swift`, reading mascot
  frames from the shipped sprite sources like the menu-bar one.

### Fixed
- **The pill has one width — the notch's own — and never resizes.** Sizing it
  to its content made it reshape with every rotating verb and every
  working↔done flip, an animated wobble in the corner of the eye that read as
  the island opening and closing all day. Text now swaps in place inside the
  fixed shape and truncates when long.
- **The island opens from the notch now, and the pill is click-through.** The
  pill floats exactly where a maximized window keeps its tab strip, so opening
  on pill-hover flapped the panel open and shut the whole time the pointer
  worked a browser's tabs — and the pill ate clicks meant for them. Opening now
  means pushing the pointer up into the notch strip itself (the menu-bar band,
  where no app content ever lives; the screen edge makes it the easiest target
  there is), and the collapsed pill passes clicks straight through to whatever
  is under it. Hover truth comes from a lightweight pointer poll, which also
  cures two staleness bugs: state-file ticks bypassing the open-dwell and
  close-grace timers, and a Space switch landing the panel on the new desktop
  fully open because no enter/exit event ever fired.

## 1.10.0 - 2026-07-29

### Added
- **The protocol now carries the task, its age, and the model.** Three new
  optional `state.d` fields — `started_at` (unix seconds, set once and preserved
  on every merge), `prompt` (the latest user prompt, one line, ≤ 120 chars) and
  `model` — written by the Claude, Codex, Cursor and Gemini hooks and both
  watchers where each can know them. Optional means optional: old state files,
  the Linux CLI, the Windows port and third-party writers stay valid unchanged.
  On the island this turns into what the reference panels show: the hero row
  gains a "You: fix the auth bug in middleware" line, compact rows are named by
  their task instead of just the repo (repo stays in the tooltip), and the chips
  gain the model and a quiet elapsed "28m". System-injected turns and slash
  commands never become the task name — only real prompts do. Running sessions
  pick the fields up on their next event.
- **AgentBar can live as a Dynamic Island.** A small pill under the notch showing
  the working agent's mark and what it is doing, with a count once two or more
  sessions are live. Point at it and it opens into the full session list, with any
  waiting approval answerable in place — same mini-diff as the menu, Allow and Deny
  in front. It never opens on its own, follows the screen your pointer is on,
  falls back to a floating bar on displays without a notch, steps aside for
  fullscreen windows, and never takes focus from your editor. In Island-only mode
  the panel's `⋯` button carries Appearance, the Allow/Deny shortcut, updates and
  Quit, so the app is always reachable.
- **The island panel reads like a proper agent panel now.** Whatever needs you
  leads as a boxed hero row — mark, bold project name, a coloured status line
  ("needs approval", "Claude asks", "Done — click to jump") — with the other
  sessions as quiet one-liners below, attention-first. A waiting approval is a
  full *Permission Request* card: tool and target line, the mini-diff with
  +N −N counts, Deny / Allow in front. An AskUserQuestion gets a *Claude asks*
  card naming the question. Answering flashes the choice back in the pill —
  "✓ Allowed" — as the panel folds away, and every open, close and resize is one
  slow spring instead of a snap: the shape inflates from the notch's centre and
  reveals the rows as it grows, with the drop shadow recut by the window. Opening
  takes a short hover dwell, so a cursor merely crossing the pill — a Cmd-Tab
  flick, a click on a window title bar — doesn't unfold it. The panel is solid
  black: translucency read as the window behind showing through the notch.
- **A welcome window on first launch**, with the surface picker — Menu bar,
  Dynamic Island, or Both — over a live preview drawn by the real mascot renderer,
  and a line naming the agents whose hooks were just wired. Reachable afterwards as
  **Appearance…**; switching modes takes effect immediately, no relaunch.
- Real screenshot of the remote approval menu in the README (#6).
- The README demo GIF generator is checked in as `Scripts/demo/demo-gif.swift`
  (#10); it reads mascot frames from the shipped sprite sources, so the GIF can
  be regenerated after any sprite change.
- **Claude Cowork sessions now show up.** Cowork (the agent mode in the Claude
  desktop app) is watched directly instead of through hooks: `CoworkWatcher`
  reads the audit log the app writes for every session and reports working,
  "needs approval" (with the tool being asked about), AskUserQuestion and done.
  Rows are anchored to the Claude app's pid, so quitting Claude clears them, and
  a click focuses the app where the prompt lives. **Caveat, found after the fact:
  newer desktop builds run Cowork inside a VM whose session files never touch the
  host, and those sessions cannot be shown** — this covers the older host-side
  "local mode" only. Documented in the README; nothing to fix on AgentBar's side
  until the app exposes session state to the host again.
- Integration test for the Antigravity liveness watcher
  (`Scripts/test/antigravity-watcher-test.sh`): synthetic turn transcript walks
  thinking → permission → done against the running app, now for both the
  desktop and the CLI brain root.
- Integration test for the Cowork watcher
  (`Scripts/test/cowork-watcher-test.sh`): a staged session walks thinking →
  permission → thinking → question → done against the running app, including a
  multi-megabyte audit line.
- README troubleshooting entry for the Homebrew version drift: updating through
  the in-app updater leaves brew's install record on the old version until
  `brew upgrade --cask agentbar` re-syncs it. The tap's own README now documents
  install, upgrade, the quarantine postflight, and how the cask tracks releases;
  the CONTRIBUTING release checklist spells out the cask bump (sha256 +
  `brew audit`).

### Fixed
- The island is visible over fullscreen apps. It was originally meant to step
  aside there; that was the wrong call — a fullscreen terminal or editor is where
  the agents actually run, so it is the last place the island should vanish from.
- An approval row for an agent that writes no request file used to say "Can't
  show the request" and offer "Open in terminal" even when the session lives in
  an app. It now names the tool being asked about and offers "Answer in
  Claude" / "Answer in Antigravity" for app-hosted sessions.
- Antigravity CLI (`agy`) sessions never appeared in the menu. The liveness
  watcher only scanned the desktop app's `~/.gemini/antigravity/brain`, while
  the CLI keeps its own tree under `~/.gemini/antigravity-cli/brain` — and the
  CLI loads `hooks.json` but never runs the handlers, so there was no second
  source of state either. Both roots are scanned now. CLI rows resolve their
  project from the CLI's `history.jsonl`, and their terminal and pid from the
  live `agy` process, so a row click focuses the hosting terminal instead of
  the desktop app and the row disappears when `agy` exits.

## 1.9.0 - 2026-07-24

### Added
- Antigravity approval flow (#2): a session waiting on Antigravity's own
  permission dialog flips to "needs approval" (amber dot) within ~6 s — the
  turn transcript's last entry is an unexecuted tool request while the dialog
  is up. The session row carries the same inline button strip as Claude:
  Allow brings the app forward and submits the dialog's preselected option
  (Return); Codex/Copilot permission rows get the identical strip instead of
  the old keystroke submenu. Requires the Accessibility permission.
- Instant end-of-turn detection for Antigravity: the final model response in
  the turn transcript flips the session to done immediately; the 90 s decay
  stays as a fallback for cancelled turns.
- Antigravity liveness watcher: the desktop engine fires no hook at all for
  chat-only turns, so the app also watches conversation-database mtimes under
  `~/.gemini/antigravity/conversations/` and upserts the same state files the
  hooks write (hooks stay authoritative; quiet sessions decay to done).
- Google Antigravity live status (#7, #2): an observe-only hook bridge
  (`Scripts/hooks/antigravity/antigravity.js`) auto-wired into
  `~/.gemini/antigravity/hooks.json` and `~/.gemini/antigravity-cli/hooks.json`
  under a dedicated `"agentbar"` rule group. Verified against desktop 2.3.1:
  the payload carries no event name (passed as an argument instead), only
  per-workspace `.agents/hooks.json` is honored, and only `PostToolUse` fires —
  so working sessions with no events for 90 s decay to done.
- Multi-agent menu bar: when two or more agents have live sessions, the bar
  shows their marks side by side (no status words) — working agents animate,
  a waiting one carries the amber/blue dot. Single-agent behavior unchanged.
- Antigravity mascot now matches the Codex layout language: the official pixel
  arch plus a twinkling braille-style dot cluster in Google blue.
- Settings window (the app's only window) for the global Allow/Deny shortcut:
  enable it and record custom key combos for Allow and Deny (defaults stay
  ⌥⌘A / ⌥⌘D). The menu row now opens Settings instead of blind-toggling; its
  tooltip shows the active combos. Recording temporarily suspends the live
  hotkeys so the current combo can be re-recorded, Esc cancels, and a combo
  must include ⌘/⌥/⌃; Allow and Deny can't share one combo.

### Fixed
- Antigravity liveness reads the per-turn transcript, not the conversation
  databases — background housekeeping kept idle sessions animating forever.
- Open dropdown no longer grows a blank band at the bottom when a session ends
  or an approval resolves while the menu is showing. Root cause: an open
  NSMenu window never shrinks, and the live refresh rebuilt the menu from
  scratch on every change. The refresh now reconciles rows in place — surviving
  rows update, vanished sessions dim to an "ended" row, resolved approval
  strips fade with their buttons disarmed — and a full rebuild happens only
  for growth (new session / request), which an open menu renders fine. Rebuilds
  are also skipped while any submenu is showing (replacing items would orphan
  it) and when nothing visible changed, so the menu never flickers for a no-op.

### Changed
- Rotating thinking verbs (Pondering…, Cooking…) appear only next to Clawd —
  the other agents' dot clusters carry the working signal on their own.
- Antigravity desktop session rows (and their approval strip) focus the
  Antigravity app instead of a terminal.
- Cursor and Gemini menu bar marks replaced with the current official app icons
  (Cursor's cube from cursor.com, Gemini CLI's gradient "&gt;" from
  geminicli.com), shown full-color with the bob animation instead of a
  flat-tinted glyph. In System (template) mode the Cursor icon renders as a
  knockout — ink plate with the cube cut out — via a new `appIconMark` artwork
  style. Menu dot colors follow: Gemini uses the icon's blue (#1A80FD), Cursor
  adapts to the menu appearance.
- Menu polish: `Open` and `Color` rows carry icons so the section shares one
  icon gutter, and the Open submenu's agent marks are drawn centered on one
  shared canvas at full resolution — identical bounds, no per-row jitter, and
  the Cursor/Gemini marks now match the mascots' solid weight.

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
