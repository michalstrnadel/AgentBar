# Plan — presentation modes: menu bar, notch island, and a first-run chooser

Status: **delivered 2026-07-29** — Phases 0–2 shipped; of Phase 3 (content
parity) only item 3.1, elapsed time, has since shipped, and Phase 4 (polish) is
deliberately not started. See *As built* for where the
shipped app differs from this draft; everything below the fold is the original
2026-07-28 draft, kept because its survey of the codebase is what the work was
costed from.

## As built (2026-07-29)

Four decisions were taken before coding, and one was reversed while using it:

1. **Three modes** — `Menu bar` (default), `Dynamic Island`, `Both`.
   `Presentation.swift`, `UserDefaults` key `presentationMode`, live `onChange`
   so switching needs no relaunch.
2. **The island is always on screen.** The draft proposed hidden-at-rest,
   appearing on activity. That was built and then thrown out: an app that only
   appears when it has news gives you nothing to look at when you want to check,
   and a panel that unfolds by itself is in the way. The pill is now the app's
   presence, the way the menu bar mark is — mark only when idle, mark + text
   while something works, a count badge from two sessions up. **Only the pointer
   opens it**; even a pending approval stays a pill that names the wait.
3. **No protocol change.** The island renders only what `state.d` already
   carries, so the Linux CLI, the Windows port and every hook are untouched.
4. **Caffeine-shaped welcome window** — icon, one paragraph, the mode picker
   with a live preview, the "hooks wired up for…" line, a show-on-launch tick.

Two more things settled during the build:

- **The panel floats *below* the menu bar** (`IslandGeometry.topGap`), centred on
  the notch, rounded on all four corners — rather than hanging out of the notch
  as the draft assumed. Overlaying the bar meant fighting the notch for space and
  covering the user's own menu bar and clock, for no gain. Nothing has to dodge
  anything now.
- **No fullscreen exception.** The draft said hide the island while a window is
  fullscreen. Built, and immediately wrong in use: a fullscreen terminal is
  where the agents run, so hiding there removes the island from the only screen
  that matters. It stays visible everywhere. (The geometry test the draft
  implied — `visibleFrame` reaching the top of the screen — never fired at all
  on a notched Mac, where `visibleFrame` reads identically in both states.)
- **The panel is forced to dark appearance** (`NSAppearance(named: .darkAqua)`).
  The reused `ApprovalContextView` / mini-diff render for a light background
  otherwise and go nearly invisible on near-black.

Costs that turned out lower than the draft feared: `ApprovalButtonsRow` was not
needed at all — the island's approval card (`IslandApprovalView`) is purpose-built
to put Deny/Allow forward and keep "Always allow" / "Answer in terminal" quiet —
and `ApprovalContextView` needed only a `leading:` parameter. Pixel-art
interpolation turned out to be a non-issue: both island surfaces draw with
`imageScaling = .scaleNone` from the same `IconRenderer` cache baked at 17pt, so
no sprite is ever resized and `fit`'s `.high` interpolation never runs on them.

Shipped files: `Presentation.swift`, `MascotDriver.swift`, `AgentActions.swift`,
`WelcomeWindow.swift`, `IslandPanel.swift`, `IslandContentView.swift`,
`IslandController.swift`. `StatusItemController.swift` shrank to the status item
and the menu; `HookInstaller` reports which agents it wired.

Not done at 2026-07-29, and not regretted then: elapsed time, the task name and
the model chip that comparable panels show. All three need new `state.d` fields
written by every hook, which is a protocol change reaching the CLI and the
Windows port — Phase 3 below, on its own, once there is a real island to miss
them in. (Since shipped as three optional, additive fields: `started_at`,
`prompt`, `model` — see `docs/protocol.md` and Phase 3 item 1.)

---

## The ask

Two things, in one thread:

1. **Let the user choose how AgentBar presents itself.** On first launch a window
   comes up — the way a normal Mac utility does it — and asks: live in the menu
   bar (what we do today), or as a Dynamic Island panel at the top of the
   MacBook screen. Changeable later in Settings.
2. **Make it look better**, in both modes.

The notch format is well established by now — a collapsed pill in/next to the
notch that widens into a panel with the session list, the pending approval and
its diff, and the buttons to answer it. On Macs with no notch, or on an external
display, the same panel is a floating bar centred at the top of the screen.
That's the shape to build toward; nothing about it is exotic.

## Where AgentBar stands today

Facts, so the plan below is costed honestly:

- The status item and the dropdown are one unit:
  `StatusItemController.swift` owns the `NSStatusItem`, the sprite animation and
  every action; `MenuBuilder.swift` turns `[Session]` + `[ApprovalRequest]` into
  `NSMenuItem`s. There is no presentation-agnostic layer between the stores and
  the menu — `MenuBuilder.populate` *is* the view.
- `SessionStore` / `RequestStore` are already clean: they watch
  `~/.agentbar/{state.d,requests.d}` and publish `onChange`. A second surface can
  subscribe to exactly the same data with no protocol work.
- Rich approval content already exists and is reusable as-is:
  `ApprovalRequest.context` carries a structured bash / diff / write payload and
  `ApprovalContextView` renders the mini-diff. The island can show the same view.
- Answering is already decoupled from the menu: `AnswerWriter` writes
  `answers.d`, `ApprovalButtonsRow` is a plain `NSView` button strip. Both work
  from any window.
- A global-hotkey path exists (`HotKeyCenter.swift`, Carbon, no Accessibility
  permission) and is already wired to Allow/Deny with rebindable combos stored in
  `UserDefaults` (`allowHotKey` / `denyHotKey`).
- There is one window today, `SettingsWindow.swift` (hotkey settings). The app is
  `.accessory` — no dock icon.
- Live refresh of the open menu is delicate: `MenuBuilder.updateInPlace`
  reconciles rows *without removal* because an open `NSMenu` window never
  shrinks. A custom-view surface has none of this constraint — the island is
  actually the easier place to render rich rows.

What we do **not** have, and the island needs:

- **No session start time.** `state.d` carries `ts` (last event) only, so
  "27m" elapsed is not derivable. Needs a `started_at` field — see Phase 3.
- **No activity history.** `label` is the *current* tool only; there is no
  rolling "Read … Edit … Bash …" feed.
- **No plan text.** ExitPlanMode is not hooked, so there is nothing to preview.
- **No way to answer a question.** `permission.js` deliberately exits
  immediately on `AskUserQuestion` (the agent's own UI renders regardless), so
  the state is visible but not answerable. Making it answerable means blocking
  that hook the way the permission hook blocks — a real change, not a UI one.

## Decision to make before any code

**How exclusive are the modes?**

The menu bar item is currently the only way to reach Settings, Quit and the
update row. If "Island" simply removes it, the app becomes unreachable when no
session is running. So:

- `Menu bar` — today's behaviour.
- `Island` — status item hidden; the island's expanded panel grows a `⋯` button
  carrying Settings / Check for Updates / Quit, and the island stays visible (as
  a small resting pill) even with no sessions, so there's always a way in.
- `Both` — island for glanceable state, menu bar for the full menu.

**Recommendation: ship all three, default to `Menu bar`, make `Island` opt-in
through the welcome window.** The extra work for `Both` is nil once the split in
Phase 0 exists, and `Island`-only is only safe once the `⋯` menu is done — so
`Island` should not be offered in the picker until Phase 2 is complete.

## Phase 0 — split presentation from state (no user-visible change)

The refactor that makes everything else cheap. Nothing ships in this phase.

- Introduce `Presentation` (enum + `UserDefaults` key `presentationMode`).
- Extract a `SessionsViewModel`: takes `[Session]` + `[ApprovalRequest]`,
  produces the display facts both surfaces need (title, subtitle, dot colour,
  agent mark, elapsed, pending approval, sort order). `MenuBuilder` and the
  island both consume it; neither re-derives.
- Move the *actions* out of `StatusItemController` into an `Actions` type (open
  agent, focus terminal, answer, defer, open settings). Both surfaces call it.
  `StatusItemController` keeps only the status item + menu lifecycle.
- Keep one file per responsibility (repo rule 1). Expected new files:
  `Presentation.swift`, `SessionsViewModel.swift`, `AgentActions.swift`.

Risk: low. This is a pure move; the existing tests (63 checks across four
suites) plus a manual menu pass cover it.

## Phase 1 — the welcome window and a real Settings window

- `WelcomeWindow` (or `SettingsWindow` in a first-run state — decide when
  building; a single window with tabs is less code and less chrome).
- Shown once, on first launch, keyed on a `UserDefaults` flag; reachable
  afterwards from the menu and from the island's `⋯`.
- Content:
  - **Presentation picker** with a *live* preview of each mode, not a
    screenshot — the same renderer as the real surface, fed a canned session, so
    it can never drift from reality.
  - **What got wired** — the hook installer already knows which agents it
    configured; showing it turns an invisible side effect into reassurance.
    (`HookInstaller.installIfNeeded` currently reports nothing to the UI.)
  - Existing settings folded in: Allow/Deny hotkeys, colour mode, preferred
    terminal.
- Visual pass on the window itself: proper margins, an app-icon header, one
  accent colour, no stock-AppKit-form look.

Note: an `.accessory` app must `NSApp.activate(ignoringOtherApps: true)` for its
window to come forward — `SettingsWindow` already does this; reuse it.

## Phase 2 — the island

The surface itself. This is the bulk of the work.

**Window.** A borderless `NSPanel`, `styleMask [.borderless, .nonactivatingPanel]`,
`level = .statusBar` (25 — above the menu bar's `.mainMenu`),
`isOpaque = false`, clear background,
`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`,
`hidesOnDeactivate = false`. `canBecomeKey` stays `false` so it never steals
focus from the editor; keyboard answering goes through the existing Carbon
hotkey path instead of window focus.

**Geometry.** Notch detection: `NSScreen.safeAreaInsets.top > 0`; the notch rect
is the gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` (macOS
12+). No notch, or an external display → floating bar centred at the top of the
active screen. Follow the screen with the mouse, or pin to the main display —
make it a setting only if it proves annoying.

**States.**
- *Resting* — nothing running: a small pill, just the mark. (Or hidden, if the
  user picks that; hidden + `Island` mode is the case that needs the `⋯` escape
  hatch to live somewhere else — likely: hidden means "hidden until something
  happens", and the pill returns on any event.)
- *Collapsed* — one line: agent mark, project, state, elapsed.
- *Expanded* — on hover (short delay) or click: session rows, and for the
  session that needs you, the approval block: tool line, `ApprovalContextView`
  mini-diff, `ApprovalButtonsRow`. Reuse both views verbatim.
- Spring expand/collapse. The notch shape means the panel should *grow out of*
  the notch, not appear over it.

**Fullscreen.** The notch region is unavailable in fullscreen. Default: hide the
island while the frontmost window is fullscreen on that screen; revisit if it
turns out `.fullScreenAuxiliary` behaves acceptably.

**Keyboard.** Allow/Deny already have global combos. Add numbered shortcuts for
question options *after* Phase 3 makes questions answerable — not before, or the
shortcut does nothing.

**Animation cost.** Only animate the mascot when a session is actually working;
the status item already follows this rule, the island must too.

## Phase 3 — content parity

Ordered by value per unit of work.

1. **Elapsed time.** — **done.** `started_at` is in the `state.d` schema
   (`docs/protocol.md`, optional and additive), stamped by
   `Scripts/hooks/claude/update.js` and `lifecycle.js` and preserved on merge,
   decoded in `Session.swift` (`elapsed`) and rendered on the island rows
   (`IslandContentView`). Absent field → no elapsed shown, so old sessions and
   third-party writers stay valid; covered by `Scripts/test/permission-hook-test.sh`.
2. **Activity feed.** A short ring of recent tool events per session. Cheapest
   honest version: the Claude `update.js` hook keeps the last N `label` values in
   the state file. Bounded size, no new files, no new protocol surface.
3. **Answerable questions.** Make `permission.js` block on `AskUserQuestion` the
   way it blocks on permission requests, emit the options into `requests.d`, and
   render them as a numbered list. This changes hook behaviour for every Claude
   user — it needs the same care and the same timeout-to-terminal fallback the
   permission path has (repo rule 3), plus tests in
   `Scripts/test/permission-hook-test.sh`.
4. **Plan preview.** Hook ExitPlanMode, carry the markdown into `requests.d`,
   render it. Nice, but the largest new surface for the least frequent event —
   last.

## Phase 4 — polish

- **Sounds.** Distinct cues for needs-approval / done / failed. Synthesised, no
  asset bloat, off by default, one toggle. Sound on *approval needed* is the one
  that actually earns its keep.
- **Precise terminal jump.** Today a row click focuses the terminal *app*.
  Landing on the exact tab/split is per-terminal work (iTerm2 has scripting;
  Warp, Ghostty and Kitty each differ). Scope to iTerm2 + Terminal.app first,
  behind the existing `term_program` field, and only if the plumbing stays small.
- **Menu-bar mode visual pass.** Custom `NSView` session rows (typography,
  elapsed, inline mark) instead of attributed strings. Caveat: this interacts
  with the never-shrink `updateInPlace` logic — budget time for it, or accept
  full repopulate for view rows.

## Explicitly not doing

- **Usage / quota display.** Already tried and thrown away: the
  `/api/oauth/usage` endpoint is chronically 429 rate-limited, and a local
  estimate was rejected. Do not re-open this.
- **SSH / remote agents.** Large, separate concern; the file protocol has no
  transport story yet.
- **Chasing an agent count.** Support follows real usage, not a number on a
  landing page. Cheap additions (agents that already write hook configs) can be
  taken opportunistically; nothing here depends on them.

## Repo rules this changes

`CLAUDE.md` rule 2 currently reads *"Menu bar only … The sole window is the small
Settings panel."* The island is a second always-on surface and the welcome
window is a second window. The rule was already amended once (when
`SettingsWindow` landed) — amend it again in the same commit as Phase 1, and keep
the part that still matters: no dock icon, no heavy dependencies.

## Open questions for the morning — answered 2026-07-29

1. Modes — **all three ship.** `Both` costs nothing once Phase 0 exists and is
   the honest answer for "I want to glance at the island but I know the menu."
2. Resting island — **always-visible pill.** Hidden-at-rest was built first and
   rejected in use; see *As built*.
3. Welcome window — **worth it on its own.** It is where the mode is picked, and
   the "hooks wired up for…" line turns an invisible side effect into
   reassurance. Ticked on by default, one click to never see it again.
4. External displays — **day one.** `IslandGeometry` follows the screen the
   pointer is on and falls back to a floating bar centred at the top when there
   is no notch; that is a handful of lines, not a phase.
5. GitHub issues — untouched by this work; none of #1, #3, #8, #9 are
   presentation bugs. (Since then #9, the stable code-signing identity, was fixed
   and closed by `827f92d`; open at the time of writing: #1, #3, #8 and #13.)

## Positioning note

The apps in this space are mostly free and open-source; the notable paid one is
$15–20 one-time. AgentBar is MIT and free, and it is the only one of the set that
also ships a Linux CLI frontend and a Windows port against the same file
protocol. That's the line worth leaning on — the island closes the last obvious
gap in presentation, not in substance.
