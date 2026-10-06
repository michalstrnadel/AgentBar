# Full audit — 2026-10-06

This audit looked at four areas: security, engineering, UX and UI, and paths that fail silently. It was a read of the code at 1.43.0, followed by fixes, each with a test where one fits. The user-facing summary is in `CHANGELOG.md` under *Unreleased*. This page records what was found, what changed, and what was left on purpose.

## Fixed

### Security

| Finding | Fix |
|---|---|
| A rule's answer was written before its ledger row, and the row's write was fire-and-forget. A full disk or a read-only home allowed an approval with no row. | The row is written first, synchronously, and a rule whose row fails gives no answer (F22). `RuleEngine.handle`, `DecisionLedger.recordNow`. |
| The hook cuts a command at 2,000 characters. The refusal table read the cut text, so a tail after the cut went unseen. | A command at or over the cap is refused (F21). |
| `git grep -O <pager>`, `--ext-diff`, `--textconv` and `git -c`/`--config-env` run a program, yet the shape is named after a read-only subcommand. | These are added to `refusedArguments["git"]`. Any option before a subcommand is refused. |
| Paths were compared as text, so a symlink inside the repository could lead out of it. | The path is checked again after `resolvingSymlinksInPath`. |
| A deny rule on `tool:AskUserQuestion` hid the card and wrote a false "deny" row. | `verdict` returns nil for questions, and the Rules sheet no longer offers that shape. |
| An `agentbar://new-task` prompt starting with `-` reached the agent's CLI as an option. | Links refuse it. A typed prompt gets a leading space. |
| Cloud row URLs used a denylist. | Now an allowlist: https, http, ssh, cursor, devin, codex, vscode. |
| `pgrep -x AgentBar` matched other users' processes. | `pgrep -x -U <uid>` in every hook. |
| `requests.d` and `answers.d` were created world-readable. | Mode 0700, and tightened on launch. |
| `install.sh` installed the download with TLS as the only check. | It now runs `codesign --verify -R` against the release certificate. CONTRIBUTING notes that this must be widened when the signer changes. |

### Engineering and silent failures

- **Re-install hooks and the Agents switch.**
  - Re-install hooks returned success before its pass ran.
  - The Agents switch discarded the pass's outcome.
  - The pass now collects its problems (an unparseable config, no node, a step that threw).
  - The repair waits for the pass and shows the problems. The switch reports them and reverts.
- **Rules page.** Off and Remove saved the view's stale list over the file, and ignored a failed write. They now use `RulesStore.edit`, which works on the file as it is and shows an alert when it fails.
- **Ledger and history pruning.**
  - Ledger prune deleted lines it could not parse. They are now kept verbatim.
  - Prune and append raced. They now share a lock.
  - Pruning ran only at launch. It now also runs every six hours.
  - History prune compared deduplicated counts against nothing, so it never compacted repeated lines. It now counts lines (app and CLI).
- **`config-changes.json`.** A corrupt file was overwritten by one row. It is now moved aside first.
- **Watchers.**
  - Antigravity and Cowork rows left in `permission` past their watcher's window are now retired with one `done`.
  - The Cowork scan moved off the main thread.
- **Blocking processes.** `zsh -lc 'command -v node'` (installer, Diagnostics) and `lsof`/`ps` (Antigravity) had no deadline. They now go through `WorkDiff.run` with a timeout.
- **WorkDiff.** It took several racing baselines per session. A slot is now claimed before git runs.
- **Notifications.**
  - A successor request under the same file name was never announced. It now replaces the old banner.
- **Hooks.**
  - A payload with no session id wrote `unknown.json`. The hook now exits without writing.
  - The stale sweep deleted another hook's in-flight `.tmp` file and rows with no pid. It now skips both.
- **Rules file and Diagnostics.**
  - A broken `rules.json` was visible only after a relaunch. Diagnostics now re-runs on change.
  - Unreadable session rows are now named (`state.unreadable`).
- **Updates.**
  - A relaunch-script failure after the swap was reported as a failed install. The new copy is now opened directly.
  - Restore and quarantine failures are logged.

### UX and UI

- **Text editing.** There was no main menu, so ⌘C/⌘V/⌘X/⌘A/⌘Z did nothing in any text field. `KeyEquivalentsMenu` adds them, plus ⌘W. It deliberately has no ⌘Q.
- **Welcome window.**
  - It opened, and took focus, on every launch, which broke rule 2. It now opens only on a fresh install, or when the user ticks the box.
  - From the menu it now shows as the **Appearance** window, and Esc closes it.
  - It no longer says "Setting up hooks…" forever when there is nothing to wire.
- **Launcher.**
  - It beeped when there was no agent to start. It now explains why.
  - ↑↓ moves through projects and ⇥ through agents.
  - Long project names are truncated.
  - The hint wording is consistent.
- **Island menu.** **New Task…** is now in the island's ⋯ menu, so Island-only users can reach the Launcher.
- **Accessibility.**
  - VoiceOver now reads the Settings sidebar items and island session rows as buttons, and can press them.
  - Approval buttons are read without their glyphs, and ⋯ has a label.
  - The finish hop now honours Reduce Motion.
- **Contrast.** Island secondary text was 30–38 % white, about 3:1. It is now 55 % (about 6:1), and 75 % when Increase Contrast is on.
- **Copy.**
  - "Icon Color ▸ Colorful / Monochrome" replaces "Color ▸ Color / System".
  - Menu items are now consistently in title case.
  - The island captions no longer assume a notch.
  - The Take a break tooltip and README describe both games.
  - A failed update check now says what to do, and names a rate limit.

## Left on purpose

- **No "Open at login".** The SessionStart hook already launches AgentBar with the first agent session, and that is the moment it is needed. A login item would duplicate it. Revisit if someone asks for the menu bar mark before any session exists.
- **`git -C <dir> status` is no longer approvable by a rule.** This is collateral from refusing every option before a subcommand. It falls through to the human, which is the safe direction. Widen it only with a check of the `-C` path against the rule's directory.
- **Diagnostics' "wired" check is still a substring match** on the agent's config (`Diagnostics.integrations`). Parsing each config's event list would need the installer's tables shared with Diagnostics and the Linux `doctor`. That is a larger change than this pass.
- **Cross-process locking.** The new ledger and history lock covers the app. The Linux CLI on a shared home still appends with `O_APPEND` and prunes with an atomic replace, so a CLI append that lands during the app's prune can still be lost. An `flock` shared by both halves would close this.
- **Two README screenshots are dated** (`approval-menu.png` from 1.9.0, `welcome-appearance.png` from before the Today row). Recapturing them means opening real windows on the screen, which an unattended run must not do. Use `Scripts/demo` or the sandbox when someone is at the machine.
