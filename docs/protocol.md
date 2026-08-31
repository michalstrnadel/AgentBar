# The `~/.agentbar` file protocol

AgentBar has no daemon and no IPC: **the folder is the protocol**. Hook scripts
(spawned by each agent's own hook mechanism) write small JSON files; any frontend —
the macOS menu bar app, the cross-platform `agentbar` CLI, a waybar module — reads
them. This document is the normative contract; it is OS-neutral (macOS, Linux).

All writes MUST be atomic: write to `<file>.<pid>.tmp` in the same directory, then
`rename(2)` over the final name. Readers never observe partial files and need no
locks. All timestamps (`ts`) are Unix seconds.

```
~/.agentbar/
  state.d/     one JSON per live session        (writer: hooks, or a frontend watcher; reader: frontends)
  requests.d/  one JSON per pending approval    (writer: permission hook)
  answers.d/   one JSON per user decision       (writer: frontends; reader: the hook)
  watcher.json frontend presence heartbeat      (writer: CLI watch/waybar)
  hooks/       installed copies of the hook scripts (refreshed by the installer)
  claude-config-dir  optional hint: custom CLAUDE_CONFIG_DIR path (one line)
```

## state.d — sessions

File name: `<sessionId>.json` where `sessionId` is sanitized `[A-Za-z0-9_.-]`,
max 64 chars (fallback `"unknown"`). The file name is the session's identity;
`sessionId` inside is informative.

```json
{
  "agent": "claude",           // agent id: claude | codex | copilot | antigravity | cursor | gemini | qwen | opencode
  "state": "tool",             // idle | thinking | tool | permission | question | done | error
  "label": "Running command",  // short human hint for the current state ("" ok)
  "project": "AgentBar",       // basename of cwd ("" ok)
  "cwd": "/path/to/project",
  "sessionId": "abc-123",
  "entrypoint": "cli",         // "cli" | "claude-desktop" | "antigravity-app" | "" — which surface hosts it
                               // "claude-desktop" also covers Cowork: the row opens the app, not a terminal
  "term_program": "WarpTerminal", // $TERM_PROGRAM of the hosting terminal ("" ok)
  "pid": 12345,                // the agent process (hook's ppid) — liveness handle
  "started": true,             // false = session opened but no real activity yet
  "ts": 1784844796,

  "started_at": 1784844700,    // OPTIONAL: unix seconds the session began
  "prompt": "fix the auth bug",// OPTIONAL: latest user prompt, one line, <= 120 chars
  "model": "claude-opus-5",    // OPTIONAL: model name, when the agent reports one
  "recap": "Fixed the auth bug and added 3 regression tests",
                               // OPTIONAL: what the agent last said, one line, <= 160 chars
  "activity": ["Reading", "Searching", "Editing"]
                               // OPTIONAL: the turn's recent tool steps, oldest → newest,
                               // <= 5 short labels, consecutive duplicates collapsed
}
```

Rules:
- Hooks read the previous file (if any) and merge (`{...prev, ...}`), so fields a
  later event doesn't know (e.g. `entrypoint`) survive.
- `state: "end"` is not written — the session's file is **deleted** instead.
- `error` means the turn ended badly (Qwen's `StopFailure`, OpenCode's
  `session.error`). It is a *finished* state like `done`, but frontends MUST NOT
  celebrate it: no green tick, no done sound. `label` carries the reason when the
  agent gives one. Writers that can't tell success from failure keep using
  `done`; frontends that predate `error` decode it as `idle`, which is harmless.
- `started` stays `false` on SessionStart; the first real event flips it. Frontends
  MUST hide sessions with `started: false`.
- The optional fields are additive: writers that don't know them simply omit
  them, and frontends MUST render fine without them — old state files and
  third-party writers stay valid. `started_at` is set once (session start, or first
  write for sessions predating the field) and MUST be preserved on merge; elapsed
  time is `now - started_at`, computed by the frontend. `prompt` is the *latest*
  user prompt — it names the task a session is on, and a newer prompt replaces it.
  `recap` is the *latest* turn-end summary — one line of what the agent last said,
  written by the agent's turn-end hook (Claude's Stop) and replaced on each turn
  end. Writers MUST drop it (omit, not carry forward) when a new prompt starts, so
  a working session never advertises the previous turn's result. Absent = the
  writer doesn't know what was said. `activity` follows the same reset rule: it is
  the ring of the *current* task's tool steps (≤ 5 short labels, oldest → newest,
  consecutive duplicates collapsed), and a new prompt starts it clean.

Frontend pruning (each refresh):
- delete when `pid > 0` and the process no longer exists (`kill(pid, 0)` → ESRCH);
- delete when `ts > 0` and older than **24 h**;
- on session start with no frontend present, hooks wipe the whole `state.d/`
  (leftovers from a crash — start honest).

## requests.d / answers.d — remote approval

Written by the blocking Claude `PermissionRequest` hook. File name:
`<sessionId>-<promptId>.json` (both sanitized). **The answer file MUST use exactly
the same file name** — that is how the hook finds its own answer.

Request:
```json
{
  "sessionId": "abc-123",
  "agent": "claude",
  "toolName": "Bash",
  "display": "Bash: git push origin main",   // one line, <= ~60 chars
  "toolInputPretty": "{ ... }",              // full tool input, capped at 4 KB
  "context": { "kind": "bash", "command": "git push origin main" },
  "ruleSuggestion": { },                     // verbatim from Claude Code, or null
  "pid": 12345,                              // the claude process
  "hookPid": 12399,                          // the waiting hook — primary liveness handle
  "ts": 1784844796
}
```

`context` is one of: `{kind:"bash", command}`, `{kind:"diff", old, new, more}`,
`{kind:"write", preview}`, `{kind:"question", questions}`, `{kind:"plan", plan}`,
or absent.

`kind:"plan"` marks a **plan review** (Claude's `ExitPlanMode`): `plan` is the
plan markdown, capped at 8 000 chars. The plan dialog renders in the terminal
alongside the hook's wait (like the question wizard). `deny` becomes a
deny-with-message the model reads as "keep planning". `allow` **cannot** approve
a plan — the approval also picks the next permission mode, which a hook decision
can't express (verified on Claude Code 2.1.234) — so the hook swallows it and
keeps waiting; frontends approve by answering the dialog itself (the macOS app
focuses the session's tab and selects "manually approve edits"). Once the dialog
is answered anywhere, the session's state leaves `permission` and the hook
retires within ~2 s.

`kind:"question"` marks an **answerable question** (Claude's `AskUserQuestion`):
the hook blocks the same way it does for permissions, but the terminal wizard
renders alongside the wait — whoever answers first wins, and the loser's answer
is ignored upstream. `questions` carries what the wizard shows (≤ 4 questions,
≤ 6 options each, strings capped):

```json
{ "kind": "question", "questions": [
  { "question": "Which auth strategy?",   // <= 300 chars
    "header": "Auth",                     // may be ""
    "multiSelect": false,
    "options": [
      { "label": "JWT", "description": "Stateless tokens" }
    ] }
] }
```

Answer (frontend → hook):
```json
{ "behavior": "allow", "rule": { }, "hookPid": 12399 }
{ "behavior": "answer", "answers": [["JWT"]], "hookPid": 12399 }
```
`behavior`: `allow` | `always` | `deny` | `defer` | `answer`. `rule` only with
`always`, and the hook accepts it **only** if it structurally equals one of the
request's own `ruleSuggestion` entries (key-order-insensitive) — a forged rule
degrades to a one-shot allow. `answer` only for `kind:"question"` requests:
`answers` is one array of chosen option **labels** per question (exactly one
unless that question's `multiSelect`); labels the request never offered, wrong
counts, or duplicates degrade to `defer` — an answer can only say things the
request itself offered. `allow` / `always` / `deny` at a `kind:"question"`
request are **swallowed** (deleted, wait continues), the same way `allow` is at
a `kind:"plan"` one: a frontend that speaks only the older verbs must leave the
question answerable rather than silently deferring it while showing "allowed". `defer` (or junk) makes the hook exit silently, falling
back to the agent's normal terminal prompt (for questions: the wizard, which is
already on screen).

`hookPid` SHOULD echo the request's own `hookPid`. Request names repeat across
the tools of one turn, so a successor hook can be polling the same file name the
frontend answered — the hook **swallows** (deletes, keeps waiting) an answer
naming a hook other than itself, so a frontend that stamps it can never answer a
request it wasn't displaying. Answers without `hookPid` (older frontends) are
accepted as before.

Lifecycle: the hook polls `answers.d` (100 ms), times out after 600 s (env
`AGENTBAR_APPROVAL_TIMEOUT`), and deletes both files on exit (including SIGTERM/
SIGINT). Frontends prune requests whose `hookPid` is dead or older than **660 s**,
and orphaned answers older than 60 s.

## watcher.json — frontend presence

Hooks only offer remote approval (and only block) when *somebody can answer*:
- macOS: the AgentBar app process exists (`pgrep -x AgentBar`), or
- any platform: `watcher.json` has a heartbeat fresher than **60 s**:

```json
{ "pid": 4242, "ts": 1784844796 }
```

`agentbar watch` refreshes it every render tick and removes it (own pid only) on
exit; `agentbar waybar` refreshes it on every poll — keep the module interval
≤ 30 s. Env override for tests: `AGENTBAR_FORCE_APP=1|0`.

## Adding a frontend or an agent

A new frontend only needs: read `state.d` (apply the pruning rules), optionally
read `requests.d` and write `answers.d`, and maintain `watcher.json` if it wants
hooks to block for it. A new agent only needs a bridge script that maps its hook
events onto the `state.d` schema above (see `Scripts/hooks/*/` for examples).

An agent with no usable hook mechanism can still be covered by a **watcher** in
the frontend that upserts `state.d` files itself — same schema, same pruning
rules. AgentBar does this for Antigravity (sparse hooks) and for Claude Cowork,
which hands every session a throwaway config directory so there is nothing to
install into. A watcher MUST leave newer hook writes alone and SHOULD stamp a
`pid` that dies with the session, so the normal pruning rules clean up after it.
