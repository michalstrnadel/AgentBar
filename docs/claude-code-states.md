# Claude Code → AgentBar state mapping

Claude Code exposes **no single machine-readable session-state field** — its TUI
spinner verbs ("Thinking…", "Actioning…", …) are cosmetic random gerunds. External
observers must synthesize state from the *sequence of hook events*. This table is
the authoritative map of what AgentBar consumes and why. Sources:
[hooks reference](https://code.claude.com/docs/en/hooks),
[user-input / AskUserQuestion](https://code.claude.com/docs/en/agent-sdk/user-input),
[issue #29212](https://github.com/anthropics/claude-code/issues/29212).

## Events AgentBar consumes

| Claude Code hook event | AgentBar state | Menu row | Notes |
|---|---|---|---|
| `SessionStart` | (seed, hidden) | — | `lifecycle.js start`; row hidden until real activity (`started: false`) |
| `UserPromptSubmit` | `thinking` | brand dot, "Thinking…" | |
| `PreToolUse` | `tool` | brand dot, per-tool label ("Running command", "Editing", …; a shell command that runs tests is "Running tests") | |
| `PostToolUse` | `thinking` | brand dot, "Thinking…" | also what clears `question` after the user answers. Drops a failure streak (`fails`), records a test run's verdict (`tests`), a red→green run or a `gh pr create` as `comeback`, and an edit's path in `edits` |
| `PostToolUseFailure` (wired only for Claude Code 2.1.119 and later) | `thinking` | brand dot, "Thinking…" — the turn goes on | The same `update.js post`, told apart by `hook_event_name`: counts `fails` (Clawd sweats at 3 in a row) and marks a failed test run red. An interrupt counts neither way. The changelog never announces the event; 2.1.119, where its input gained `duration_ms`, is the oldest version known to fire it, so an older or unknown version is not wired. |
| `PermissionRequest` (regular tool) | `permission` | **amber dot, "needs approval"** + inline ✓ Allow / ✓ Always / ✕ Deny / defer | `permission.js` blocks polling `answers.d/`; every failure path falls back to the terminal prompt |
| `PermissionRequest` (`tool_name == "AskUserQuestion"`) | `question` | **blue dot, "❓ \<question\>"** + inline options — answerable from the menu and island | The terminal wizard renders alongside the hook's wait, so blocking costs the terminal nothing; a remote answer returns deny-with-message, which the model reads as the user's answer and the wizard is dismissed (verified on 2.1.234, both race directions). Options that don't decode fall back to mark-state-and-exit. |
| `PermissionRequest` (`tool_name == "ExitPlanMode"`) | `permission` | **amber dot, "Plan ready for review"** + the plan as Markdown, **Keep planning** / **Approve plan** | The plan dialog renders alongside the hook's wait. `deny` returns a deny-with-message the model reads as "refine it" — a bare denial ends the turn instead. `allow` is **ignored** by Claude Code (approving a plan also picks the next permission mode, which a hook decision can't carry), so the hook swallows it and the frontend answers the dialog itself. Verified on 2.1.234. |
| `Stop` | `done` | dimmed dot | turn finished, waiting for the next prompt |
| `PreCompact` (`manual` or `auto`) | `thinking` | brand dot, **"Compacting…"**; the bar and the island pill hold the word "Compacting" instead of rotating verbs | Not a state of its own: a label on `thinking` (docs/protocol.md unchanged). `update.js compact` keeps what the row said in `resume`. |
| `SessionStart` (`source: "compact"`) | what it was before `PreCompact` | as before | Ends the compaction: `lifecycle.js` restores `state`, `label` and `recap` from `resume` and drops it, so a manual `/compact` after a finished turn lands on `done` again. `PostCompact` is deliberately not registered — this start follows every compaction, and an event name an older Claude Code does not know is a settings file it may refuse. |
| `PermissionDenied` (auto mode refused a call; wired only for Claude Code 2.1.89 and later) | `thinking` | the row says **"auto mode refused Bash · curl … \| sh"** in amber, the classifier's reason in its tooltip, until the next prompt | `update.js denied` writes `blocked` and prints nothing: `{retry: true}` would be an answer. Not wired when the installed version is older or unknown — an event an older build does not know is a settings file it may refuse. |
| `SessionEnd` | (row removed) | — | `lifecycle.js end` deletes the state file |

## Events deliberately not consumed

| Event | Why not |
|---|---|
| `Notification` (`permission_prompt`, `idle_prompt`, …) | Removed in 1.2.1: notifications can arrive *late* (after the upstream dialog-flash race, claude-code #12176) and overwrite newer state — sessions got stuck on "needs approval". `permission.js` is the sole owner of the permission signal. |
| `SubagentStart` / `SubagentStop` | Subagent activity is already reflected through the parent session's tool events. |
| `PostCompact` | The `SessionStart` with `source: "compact"` that follows every compaction already ends it (see above). |
| `ConfigChange`, `FileChanged`, … | No user-facing signal AgentBar needs. (Qwen Code, which reuses these scripts, registers its `StopFailure`, where the turn itself ended badly: the `error` state.) |

## Known upstream quirks the design accounts for

- **PermissionRequest fires for some non-blocking checks** (issue #29212). Harmless
  here: if Claude proceeds without our decision, the very next `PreToolUse`
  overwrites the state, and the orphaned request file is pruned via `hookPid`.
- **Dialog flash after hook allow** (issue #12176) — cosmetic, documented in README.
- **Hooks snapshot at session start** — any hook change requires a new session.
