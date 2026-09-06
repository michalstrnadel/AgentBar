# Remote Allow/Deny from the Menu Bar — Design

Date: 2026-07-23
Status: approved for planning

> **Historical record — do not read as current design.** This is the design as
> approved on 2026-07-23; what shipped has since moved on. In particular:
> AgentBar covers eight agents now, not four (`Agents.swift`); Antigravity
> gained a real approval flow in 1.9.0 (`approveKeys` sends Return to its
> preselected dialog — the "IDE without a scriptable prompt" line below is
> obsolete); the disabled-note submenu for keystroke agents became the inline
> button strip; and requests/answers grew `kind:"question"` / `kind:"plan"`
> payloads plus a `hookPid` echo on answers. The normative contract is
> [`docs/protocol.md`](../protocol.md).

## Problem

When an agent session hits a permission prompt, AgentBar already shows it (yellow
dot, "needs approval") but the user must switch to the terminal to answer. Users
without broad auto-allow settings answer these prompts constantly. AgentBar should
let them answer straight from the menu bar — and always show exactly what they are
approving.

## Scope

- All four agents, two backends:
  - **Claude Code** — native: a hook returns the decision; the terminal prompt never appears.
  - **Codex / Copilot** — best-effort: focus the terminal, send the approval keystroke.
    (Antigravity is an IDE without a scriptable prompt; its rows keep Open in terminal only.)
- Decisions supported for Claude: Allow once, Always allow (persist rule), Deny, Answer in terminal.
- Non-goals (v1): notifications with action buttons, approval history, per-project auto-allow lists, iOS/remote approval.

## Architecture (Claude path)

New folders under `~/.agentbar/`, same "a folder is the protocol" pattern as `state.d/`:

- `requests.d/<safe(session_id)>-<safe(prompt_id)>.json` — written by the hook when a permission is requested.
- `answers.d/<same name>.json` — written by the app when the user clicks.

Flow:

1. `HookInstaller` registers `Scripts/hooks/claude/permission.js` for the
   `PermissionRequest` hook event (per-hook `timeout: 630`). The old
   `update.js permreq` registration is replaced by this script; `update.js`
   keeps all other events.
2. On `PermissionRequest`, `permission.js`:
   - Parses stdin JSON (`session_id`, `prompt_id`, `tool_name`, `tool_input`,
     `permission_rule`/suggestions, `cwd`).
   - Builds a one-line display summary (see "Display summaries").
   - Updates the session's `state.d` file: `state: "permission"`, `label: <summary>`
     (the menu row renders "needs approval"; the summary shows on the request line under it).
   - Writes the request file atomically (tmp + rename): `{sessionId, agent: "claude",
     toolName, display, toolInputPretty (pretty JSON, ≤4 KB), ruleSuggestion?,
     pid: ppid, hookPid, ts}`; promptId is encoded in the file name.
   - Polls `answers.d/` every 100 ms. Every 2 s it also re-checks that AgentBar
     is running (`pgrep -x AgentBar`); if not, it cleans up and exits silently.
   - On answer:
     - `allow` → stdout `{"hookSpecificOutput": {"hookEventName": "PermissionRequest",
       "decision": {"behavior": "allow"}}}`
     - `always` → same as allow plus `"updatedPermissions": [<ruleSuggestion>]` — the
       hook echoes a Claude-supplied suggestion verbatim (only offered when one exists).
     - `deny` → `decision.behavior: "deny"`.
     - `defer` → no output, exit 0 → Claude Code shows the normal terminal prompt.
     - In all cases: delete the answer file and the request file.
   - On timeout (default 600 s, override `AGENTBAR_APPROVAL_TIMEOUT` seconds for
     tests): delete request file, exit 0 with no output → terminal prompt appears.
3. The app (`RequestStore`) watches `requests.d/` exactly like `SessionStore`
   watches `state.d/` (DispatchSource + 2 s fallback poll) and joins requests to
   sessions by `sessionId`.
4. Menu click → `AnswerWriter` writes the answer file atomically.

Fallback invariant: **every failure mode degrades to today's behavior** (prompt in
the terminal). App not running → immediate exit. App quits mid-wait → exit within
2 s. App never answers → timeout. Hook crash → Claude Code treats it as a
non-blocking hook error and prompts normally.

Known upstream cosmetic issue: the permission dialog may flash briefly even when a
hook allows (claude-code issue #12176). Harmless; documented in README.

## Menu UX

The request renders inline, directly under the session row — no second navigation
level (chosen over a submenu after A/B evaluation on 2026-07-23):

```
● AgentBar · main  needs approval   CLAUDE
      Bash: git push origin main          (small dimmed line; tooltip = full input)
      [✓ Allow] [✓ Always] [✕ Deny] [⌨ Terminal]   (button strip, NSMenuItem.view)
```

"✓ Always" appears only when a rule suggestion exists (rule text in the tooltip).
The defer button reads "⌨ Terminal" for CLI sessions and "⧉ Claude app" for
claude-desktop ones, and hands the prompt back to that surface. Clicking the
session row itself performs the same defer + focus.

Multiple concurrent requests for one session (parallel tool calls) each get their
own block under the session row, newest first.

### Display summaries

- `Bash` → `Bash: <command>` (first line, ≤60 chars + …)
- `Edit`/`Write`/`MultiEdit`/`NotebookEdit` → `<Tool>: <relative file path>`
- `WebFetch`/`WebSearch` → `<Tool>: <url/query>`
- MCP tools (`mcp__server__tool`) → `server: tool`
- anything else → `<tool_name>`
- Tooltip always carries the full pretty-printed `tool_input` (truncated at 4 KB).

## Non-Claude agents (keystroke backend)

For sessions in `permission` state whose agent has no request file:

- Submenu: disabled note `Can't show the request for <Agent>` +
  `Approve in terminal (sends keystroke)` + `Open in terminal`.
- `KeystrokeApprover` activates the session's terminal app (`term_program`) and
  posts the agent's approval keystroke via CGEvent. The keystroke is defined per
  agent in `Agents.swift` (rule 4: adding/tuning an agent touches only its entry);
  exact keys verified per agent during implementation.
- Requires Accessibility (`AXIsProcessTrusted`). When missing, the submenu item
  becomes `Grant Accessibility…` and deep-links to System Settings → Privacy →
  Accessibility.
- No "Always allow", no Deny (we cannot reliably pick the deny option across
  agents' prompt UIs; the user can open the terminal for anything beyond approve).
- Best-effort by design: injection targets the frontmost window after activation.
  If the user has multiple sessions in the same terminal app, the keystroke may hit
  the wrong tab — documented limitation; the item label says "sends keystroke" so
  the action is never mistaken for a guaranteed remote decision.

## New/changed units

| Unit | Responsibility |
|---|---|
| `Scripts/hooks/claude/permission.js` (new) | Blocking PermissionRequest hook: request file, poll, decision output |
| `Sources/AgentBar/ApprovalRequest.swift` (new) | Model: decode one `requests.d` file |
| `Sources/AgentBar/RequestStore.swift` (new) | Watch `requests.d/`, prune orphans, publish requests |
| `Sources/AgentBar/AnswerWriter.swift` (new) | Atomic answer-file writes |
| `Sources/AgentBar/KeystrokeApprover.swift` (new) | Non-Claude approve: activate terminal + CGEvent |
| `MenuBuilder.swift` | Inline approval rows (request line + button strip) |
| `Sources/AgentBar/ApprovalButtonsRow.swift` (new) | Allow/Always/Deny/defer button strip (NSMenuItem.view) |
| `StatusItemController.swift` | Menu actions → AnswerWriter / KeystrokeApprover |
| `HookInstaller.swift` | Register permission.js with timeout 630 |
| `Agents.swift` | Per-agent approval keystroke definition |
| `CLAUDE.md` rule 3 | Amended: permission hook may block (session is already waiting on the human) but must always time out to the terminal prompt |

## Error handling

- All files written atomically (tmp + rename), matching existing hooks.
- Hook deletes its request file on every exit path (answer, timeout, app-gone, signal via `process.on('exit')` best effort).
- App prunes `requests.d` entries whose `pid` is dead or whose `ts` exceeds the approval window; prunes `answers.d` orphans older than 60 s.
- Duplicate/late answers: hook reads at most once; leftover answer files are pruned by the app.
- Deny (Claude path) is never destructive: the agent receives an ordinary permission denial, identical to pressing "no" in the terminal.

## Testing

- `Scripts/test/permission-hook-test.sh`:
  1. answered-allow: fake event on stdin, `AGENTBAR_APPROVAL_TIMEOUT=5`, write allow answer → assert stdout decision JSON + files cleaned.
  2. answered-deny and defer variants.
  3. timeout: no answer → assert silent exit 0 within budget, request file removed.
  4. app-not-running guard: with pgrep failing → instant silent exit.
- App-side manual harness: drop a crafted request+state file pair with the current shell's PID, verify the inline approval rows, click each action, assert answer file bytes.
- Manual E2E checklist (in PR): real Claude Code session, approve `git status` from the menu; deny; always-allow with rule; defer to terminal; kill app mid-wait.

## Docs / changelog

- README: feature section + Accessibility note + #12176 note.
- `docs/specs/2026-07-23-agentbar-design.md`: link to this spec.
- Changelog entry (user-visible behavior change).
