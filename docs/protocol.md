# The `~/.agentbar` file protocol

AgentBar has no daemon and no IPC: **the folder is the protocol**. Hook scripts
(spawned by each agent's own hook mechanism) write small JSON files; any frontend —
the macOS menu bar app, the cross-platform `agentbar` CLI, a waybar module — reads
them. This document is the normative contract; it is OS-neutral (macOS, Linux).

All writes MUST be atomic (one exception: `mods.d/`, below): write to `<file>.<pid>.tmp` in the same directory, then
`rename(2)` over the final name. Readers never observe partial files and need no
locks. All timestamps (`ts`) are Unix seconds.

```
~/.agentbar/
  state.d/     one JSON per live session        (writer: hooks, or a frontend watcher; reader: frontends)
  requests.d/  one JSON per pending approval    (writer: permission hook — Claude Code, Copilot CLI, Codex CLI)
  answers.d/   one JSON per user decision       (writer: frontends; reader: the hook)
  watcher.json frontend presence heartbeat      (writer: CLI watch/waybar)
  history.jsonl  one line per ended session     (writer: frontends only)
  decisions.jsonl one line per permission decision (writer: frontends only)
  history-seen.json  the CLI's previous tick, so one-shot commands can diff
  config-changes.json  the macOS installer's last settings writes, as diffs (writer: the app only; mode 0600)
  hooks/       installed copies of the hook scripts (refreshed by the installer)
  claude-config-dir  optional hint: custom CLAUDE_CONFIG_DIR path (one line)
  wire-disabled  agents the installers leave unwired, one id per line (writer: frontends)
  wire-enabled   integrations that start off and were switched on, one id per line (writer: frontends)
  mods.d/      one JSON per Claude Code session the AgentBar mod sees (writer: the mod; reader: frontends)
  mods/        installed copy of the AgentBar Claude Code mod, and its config.json (writer: frontends)
```

### Where state lives

`~/.agentbar` is the default. `AGENTBAR_HOME`, set to a non-empty **absolute**
path, replaces that directory itself: everything above (and every other file this
document names, `rules.json`, `sounds/`, `cloud.json` included) lives directly
under it. It exists for test sandboxes and side-by-side dev copies; the app, the
hooks, the CLI and the cloud poller all honour it.

- It moves the state root and nothing else. Agent configs (`~/.claude`,
  `~/.codex`, …) are still found through `HOME` and their own variables.
- Unset or empty means `~/.agentbar`, exactly as before.
- No `~` expansion; trailing slashes are dropped (`/tmp/x/` is `/tmp/x`).
- A relative value is a mistake, and each reader handles it by what it cannot
  afford: a hook ignores it and uses the default (a hook must never fail its
  agent); the CLI and the cloud poller exit non-zero with a one-line error naming
  the variable (a typo must not quietly write into the real directory).
- A hook reads it from its own environment, which is the agent's: an agent started
  with `AGENTBAR_HOME` set reports there, one started without it reports to
  `~/.agentbar`. Hooks never derive the root from where they are installed.
- `agentbar install-hooks`, `wire` and `unwire` refuse to run under a root other
  than `~/.agentbar`: they write the agents' real configs, which would then point
  at hooks under a sandbox. To test installation, borrow `HOME` instead.

## state.d — sessions

File name: `<sessionId>.json` where `sessionId` is sanitized `[A-Za-z0-9_.-]`,
max 64 chars (fallback `"unknown"`). The file name is the session's identity;
`sessionId` inside is informative.

A writer MAY prefix that name (AgentBar's hooks do it for Codex, whose rows a
second writer already named `codex-<thread-id>`), but the prefix is part of the
identity: **every writer for one agent MUST agree on it**, prefix included, or one
session becomes two rows. The cap counts the prefix.

```json
{
  "agent": "claude",           // agent id: claude | codex | copilot | antigravity | cursor | gemini | qwen | opencode | devin,
                               // or any other `[a-z0-9-]{1,32}` id (frontends render unknown ids generically)
  "state": "tool",             // idle | thinking | tool | permission | question | done | error
  "label": "Running command",  // short human hint for the current state ("" ok)
  "project": "AgentBar",       // basename of cwd ("" ok)
  "cwd": "/path/to/project",
  "sessionId": "abc-123",
  "entrypoint": "cli",         // "cli" | "claude-desktop" | "antigravity-app" | "cloud" | "" — which surface hosts it
                               // "claude-desktop" also covers Cowork: the row opens the app, not a terminal
                               // "cloud" = the session runs on another machine — a vendor's infrastructure,
                               // or one of your own hosts mirrored over ssh; the row opens `url`
  "term_program": "WarpTerminal", // $TERM_PROGRAM of the hosting terminal ("" ok)
  "pid": 12345,                // the agent process (hook's ppid) — liveness handle
  "started": true,             // false = session opened but no real activity yet
  "ts": 1784844796,

  "started_at": 1784844700,    // OPTIONAL: unix seconds the session began
  "agent_name": "Aider",       // OPTIONAL: display name for an id the frontend doesn't know, <= 24 chars
  "prompt": "fix the auth bug",// OPTIONAL: latest user prompt, one line, <= 120 chars
  "model": "claude-opus-5",    // OPTIONAL: model name, when the agent reports one
  "recap": "Fixed the auth bug and added 3 regression tests",
                               // OPTIONAL: what the agent last said, one line, <= 160 chars
  "activity": ["Reading", "Searching", "Editing"],
                               // OPTIONAL: the turn's recent tool steps, oldest → newest,
                               // <= 5 short labels, consecutive duplicates collapsed
  "url": "https://app.devin.ai/sessions/abc"
                               // OPTIONAL: where the session lives when it isn't local.
                               // Required for entrypoint "cloud": a row click opens it
                               // (https:// or a vendor scheme like cursor://).
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
  MUST hide sessions with `started: false`. A writer whose agent can open a session
  with a prompt already in flight MUST seed it `true` — that session is working the
  instant it exists, and some agents (Copilot CLI) fire their start and prompt
  events concurrently, so a seed of `false` can land second and hide a live row.
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
- `started` absent counts as `true`: only an explicit `false` hides a row, so a
  writer that never heard of the field still shows up.
- `agent_name` names an agent the frontend has no entry for. Frontends strip
  control characters, trim, cap it at 24 characters, and fall back to the id when
  it is absent or empty. A known id keeps its own name, sprite and actions; an
  unknown one gets a generic mark and no keystroke approvals.

Frontend pruning (each refresh):
- delete when `pid > 0` and the process no longer exists (`kill(pid, 0)` → ESRCH);
- delete when `ts > 0` and older than **24 h**;
- on session start with no frontend present, hooks sweep `state.d/` of rows whose
  owning process is gone (leftovers from a crash — start honest). Only dead rows:
  another agent's session outlives a frontend restart, and a wipe would hide it.

## requests.d / answers.d — remote approval

Written by the blocking permission hook. File name:
`<sessionId>-<promptId>.json` (both sanitized). **The answer file MUST use exactly
the same file name** — that is how the hook finds its own answer.

Three hosts speak this today and one script serves all of them. Claude Code sends
`PermissionRequest` and reads the decision back wrapped in `hookSpecificOutput`;
Copilot CLI sends `permissionRequest` — camelCase, raw tool ids, no `prompt_id`
(the hook's own pid separates two requests in one turn) — and reads the decision
bare as `{"behavior": …}`. Codex CLI sends `PermissionRequest` in Claude's own
spelling and reads Claude's own envelope, differing only in having no `prompt_id`
(its `turn_id` takes that place) and no suggestion channel. What lands in
`requests.d` is identical apart from `agent`, so frontends need to know nothing
about any of the three dialects.

`ruleSuggestion` is null for Copilot and Codex and always will be: neither output
contract has a channel for a standing rule, so "always" degrades to a one-shot
allow, and a frontend MUST NOT offer an *Always* affordance for a request that
carries no `ruleSuggestion`.

Request:
```json
{
  "sessionId": "abc-123",
  "agent": "claude",
  "toolName": "Bash",
  "display": "Bash: git push origin main",   // one line, <= ~60 chars
  "toolInputPretty": "{ ... }",              // full tool input, capped at 4 KB
  "cwd": "/Users/me/AgentBar",               // the session's directory; ABSENT when unknown
  "filePath": "Sources/AgentBar/Weight.swift", // the file an edit/write names; ABSENT when none
  "context": { "kind": "bash", "command": "git push origin main" },
  "ruleSuggestion": { },                     // verbatim from Claude Code, or null
  "pid": 12345,                              // the claude process
  "hookPid": 12399,                          // the waiting hook — primary liveness handle
  "ts": 1784844796
}
```

`cwd` is the directory the agent is working in, carried since 1.28.0 because a rule
that says "in this repository" cannot be evaluated without it and because every
reader was otherwise joining back through `state.d` on `sessionId` to learn
something the hook already had. A writer that does not know it MUST omit the field
rather than send an empty string: empty is indistinguishable from `/` in a prefix
test, and a rule scoped to one repository would then match every one. A reader that
does not find it falls back to the session join.

`filePath` is the file an edit or write names (`tool_input.file_path`,
`notebook_path`, `path` or `filePath`, the first one present), as its own field
because `toolInputPretty` is cut at 4 KB and a cut is not JSON: a reader that
could only parse it there lost the path of every large edit, and the shape a rule
is keyed on with it. A writer MUST omit it when the tool names no file or the path
is implausible (over 1024 chars). A reader that does not find it falls back to
parsing `toolInputPretty`.

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
{ "behavior": "deny", "message": "use pnpm in this repo, not npm", "hookPid": 12399 }
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

`message` is OPTIONAL and only means something with `deny`: what the human wants
done instead. It is the one way a permission hook can steer an agent rather than
stop it — the hook returns it inside the denial, and the agent reads it as the
tool's result. The hook flattens it to one line (control characters and runs of
whitespace become one space), trims it, caps it at 500 characters, and wraps it in
its own words: `The user denied this tool call (via AgentBar) and said: "…". Do not
retry the same call; follow the user's instruction instead.` On a `kind:"plan"` request it is the feedback the plan goes back
with, after the keep-planning message. A `message` that is not a non-empty string
is ignored and the denial goes out bare, exactly as it did before the field
existed; on any other verb it is ignored. Older hooks ignore it too, which is
harmless: the refusal still refuses.

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

## history.jsonl — what happened after state.d forgot

`state.d` is a **live** set. A row is deleted when its process dies or its `ts`
passes 24 h, so an agent that ran yesterday and exited cleanly leaves nothing
behind at all. Two things need a past anyway: "when did this agent last report
anything", which is how a broken integration is told apart from an idle one, and
any account of a day's work. Hence one append-only JSON Lines file.

```json
{ "v": 1, "agent": "codex", "sessionId": "abc-123", "project": "AgentBar",
  "cwd": "/Users/me/src/AgentBar", "label": "build", "prompt": "fix the linker",
  "model": "gpt-5", "startedAt": 1784844000, "endedAt": 1784844796,
  "state": "done", "decayed": false,
  "agentName": "Aider",        // OPTIONAL: the row's `agent_name`, when it had one

  "weight": { "in": 1330, "out": 622024, "cacheWrite": 1453897,
              "cacheRead": 220795232, "src": "claude-transcript" },
                               // OPTIONAL: what the session cost, in the agent's own
                               //   numbers. Absent = nobody could measure it.
  "change": { "files": 7, "added": 210, "removed": 80, "base": "3a30264" }
                               // OPTIONAL: what moved in the repo while it ran.
}
```

Rules:

- **Frontends write this, hooks never do.** Hooks exit fast (rule 4), and the
  end of a session is precisely the event several agents have no hook for.
- A session is recorded when it reaches `done` or `error`, and again when its row
  disappears. Deliberately **not** on `idle` — that is where a session waits
  *between* turns, and counting it would write a record every time someone paused
  to read the output.
- Appends are `O_APPEND` and whole-line, so two frontends sharing a home cannot
  truncate each other and a crash costs at most the last line. Readers MUST skip
  a line that does not parse rather than giving up on the file.
- A session therefore appears more than once. Readers MUST keep the **last** line
  for a given `sessionId`; the newest wins and duplicates need no coordination.
- `decayed: true` means a frontend watchdog synthesized the ending rather than the
  agent reporting it. A reader that counts those as clean finishes is inventing
  outcomes.
- Writers prune to **30 days** and a hard cap of **5000 records**.

### `weight` — what the session cost

Optional and additive: a writer that cannot measure a session **omits the key**. A
reader MUST treat an absent `weight` as *unmeasured*, never as zero — most sessions
will not have one, because only three of the supported agents keep a per-session
number on disk at all (Claude Code's transcript, Codex's rollout file, Copilot CLI's
`session-store.db`). `src` names which of those produced it.

The four counts are stored separately **because the agents do not agree on what a
token is**. Claude reports cache reads alongside everything else; Codex folds cached
input *into* its input count; Copilot keeps every category apart. Writers normalise to
one shape — `in` excludes anything served from cache, `cacheRead` carries it — so that
the components are comparable even though no single pre-summed total would be.

Frontends show `in + out + cacheWrite` and **leave `cacheRead` out**. On one real
session that is the difference between 2.1 M and 222.9 M: cache reads say how long a
conversation is, not how much work it did. A frontend that wants the other number has
it, but must say which one it is showing.

Records for one session supersede each other (last line wins), so `weight` is always
the session's **running total**, never a per-turn delta. That is what makes a total
read before the agent flushed its last message self-correcting.

### `change` — what moved in the repo

Optional on the same terms. `base` is the short commit the span was measured from.

The wording matters and is normative for frontends: this is **what changed in the
repository while the session was open**, not what the agent did. The same working tree
takes edits from the human and from any other session sharing the checkout, and
nothing on disk can separate those — two sessions in one repo will report the same
change. A frontend MUST NOT present it as the agent's own output.

The measurement compares per-file line counts against a baseline, not content, so it
errs low: work that rewrites lines already uncommitted when the session began is not
counted. Exact when the tree was clean at the baseline.

A writer emits it only when it observed the whole span. No baseline (the frontend
started mid-session), a `cwd` that is not a repository, or a history rewritten under
the baseline commit all mean the key is omitted.

`history-seen.json` is an implementation detail of the CLI, not part of the
protocol: a snapshot of the previous tick so that one-shot commands (`status`,
`waybar`) can diff. The macOS app keeps the same snapshot in memory.

## decisions.jsonl — what the human decided

One append-only line per permission decision that **actually reached `answers.d`**.
Written by frontends only, same mechanics as `history.jsonl` (O_APPEND, one line at
a time, a torn line costs that line). Unlike the history, nothing collapses: two
decisions about the same command are two decisions, and counting them is the point.

```json
{"v":1,"ts":1789561881,"agent":"claude","sessionId":"abc-123","project":"AgentBar",
 "cwd":"/Users/me/AgentBar","tool":"Bash","shape":"bash:git push",
 "display":"Bash: git push origin main","decision":"allow","waited":42,"via":"app",
 "rule":"","would":""}
```

- `decision` is one of the verbs the answer carried: `allow` | `always` | `deny` |
  `defer` | `answer` | `watch`. Only `allow`/`always`/`deny` are verdicts; the rest
  are a hand-off, a question, and a note that nothing happened, and a reader
  counting repeats MUST skip them.
- `watch` means a rule in its watching mode matched a request and **deliberately
  did not answer it**; `would` carries what it would have said. It is spelled as
  its own decision rather than as an `allow` with a flag beside it precisely so
  that every reader already switching on the verdicts skips it without being
  changed. A row saying `allow` when nothing was allowed would be a false record.
- A `watch` row is **agreed with** when the human's own answer to the same prompt
  is in the ledger: the first not-yet-paired row with `via` other than `rule`, a
  verdict (`always` counts as `allow`), the same non-empty `sessionId`, `tool` and
  `shape`, a `ts` no earlier than the watch row's and at most 15 minutes after it.
  No such row means the prompt was answered where AgentBar cannot see — the
  terminal, a keystroke, a timeout — and it is counted as unwitnessed, never as
  agreement. The app and `agentbar rules` count it the same way.
- `waited` is seconds between the request's `ts` and the decision — how long the
  agent sat blocked on the human. A request with no `ts`, or one stamped in the
  future, contributes `0` rather than a negative number.
- `shape` is the key repeats are counted by, and it is **normalised on purpose**:
  the first meaningful word of a command (two for a multiplexer — `git push`,
  `npm test`), or `<tool>:<folder>/*.<ext>` for an edit or a write. It MUST NOT
  carry arguments, paths or URLs: those never repeat, and they are where a secret
  would be if one were ever typed into a command.
- `display` is the request's own one-line summary, already capped by the hook, kept
  so a count can be shown next to what it refers to.
- `via` names what answered: `app` | `cli` | **`rule`** | **`claude`**. `rule` means
  nobody was asked — a rule the user wrote answered on their behalf (see `rules.json`
  below). `claude` means Claude Code decided the call itself, before any prompt existed,
  and the AgentBar mod saw it (see `mods.d` below); such a row also carries `by`
  (`rule` — a Claude Code settings rule, named in `claudeRule`; `mode` — the permission
  mode or the tool's own check; `hook` — a hook or another mod: Claude Code says a
  `PreToolUse` hook decided but not why, and names no mod, so `reason` is often empty), `reason` (Claude Code's sentence, capped at 300 characters) and
  `toolUseId`, which is unique: a frontend writes one row per id, ever. Its `waited`
  is `0`. A frontend that offers a switch to stop writing rows (AgentBar: *Remember
  what I decided*) applies it to `claude` rows too, and marks their ids as taken
  while it is off, so switching back on does not backfill. Readers cap `claude` rows
  apart from the person's (AgentBar keeps up to 5 000 of each), so a busy day of
  Claude Code's own decisions cannot push the person's record out.
- `rule` is the id of that rule, and is empty for every other `via`. It is what
  makes a rule auditable: "what has this rule ever done" is answered by filtering
  the ledger on it, which is why the rules file itself holds no counters.
- A reader that reports how many prompts a person answered, or how long agents
  waited on them, MUST NOT count `via` `rule` or `claude` as the person's (rows written
  before `via` existed, with it empty, are the person's), and counts those two
  **separately**. Nobody waited and nobody was asked; folding
  them in overstates one number and understates the other. For the same reason a
  `claude` row never pairs with a `watch` row as agreement, and never counts towards
  "allowed N× here".

**What is deliberately absent.** Keystroke approvals — the ones AgentBar sends for
agents with no request file (Antigravity, and Codex sessions started before its
hooks were accepted), and a Claude plan approval, which is also a keystroke — write
**no line**. A frontend presses a key at a terminal and never learns what the
terminal did with it; recording that as "the user allowed" would be a claim no
writer is in a position to make. So the ledger covers the agents that speak
`requests.d`, and a reader must not treat its silence about a keystroke-approved
session as "nothing was ever approved there".

Rows are the user's own record of their own decisions. Nothing is sent anywhere, a
frontend MAY offer a switch to stop writing them (AgentBar: **Settings ▸
Approvals**), and `agentbar forget` empties the file.

## mods.d — what Claude Code decided without asking, and what it measures

Claude Code 2.1.287 and later loads **mods**: plugins whose code runs inside its own
process, sees every tool call, and may approve one before a prompt exists. The
AgentBar mod (`Scripts/mods/claude`, opt-in: Settings ▸ Agents ▸ Claude Code mod, or
`agentbar wire claude-mod`) **observes only** — every hook passes Claude Code's own
result through unchanged — and writes one file per session:
`mods.d/<session_id>.json`, where `session_id` is the same id the session's
`state.d` row is named by.

```json
{"v":1,"agent":"claude","session_id":"0fbdbf48-…","ts":1791146583,"mod":"1.36.0",
 "cwd":"/Users/me/AgentBar","ended":false,
 "context":{"percent":16,"tokens":31310,"window":200000},
 "rate_limits":[{"kind":"five_hour","percent_used":62,"resets_at":"2026-10-04T23:00:00.000Z"},
                {"kind":"seven_day","percent_used":28,"resets_at":"2026-10-10T05:00:00.000Z"}],
 "subagents":0,
 "decisions":[{"id":"toolu_013T…","ts":1791146581,"tool":"Bash",
               "input":{"command":"git status --short"},
               "verdict":"allow","by":"rule","rule":"Bash(git status:*)","reason":""}]}
```

- **Not atomic.** A mod can only rewrite a file in place (Claude Code gives it no
  rename), so this is the one file in the protocol a reader can catch half-written.
  A reader MUST treat a file that does not parse as "no news" and keep what it read
  last; the next write, at most a few seconds later, is whole again.
- `context` and `rate_limits` are Claude Code's own figures (`$.session.usage()`): a
  figure it does not have is left out, never zeroed. `rate_limits` is empty off a
  subscription and until the session's first turn has been measured; `resets_at` is
  ISO 8601 as Claude Code gives it. `percent_used` is 0–100 and may pass 100 on an exceeded spend limit.
- `decisions` is a ring of the newest 200 verdicts Claude Code reached **before a
  prompt was due**: `allow` or `deny`, never `ask` (an `ask` reaches the person, and
  from there `requests.d`). A verdict the permission mode reaches *on* an `ask` —
  don't-ask mode, the auto-mode classifier, a headless host — happens after the mod
  has looked and is not among them; a reader must not present the ring as everything
  that ran unasked. Read-only tools (`Read`, `Glob`, `Grep`, `LS`, `TodoWrite`,
  `NotebookRead`, `WebSearch`, `ToolSearch`, `BashOutput`) are left out: they change
  nothing, and listing every file read would bury the calls that did. `input` keeps
  only `command`, `file_path`, `url` and `description`, each capped at 2 KB. `by` is
  as in `decisions.jsonl`: `rule` with `rule` naming the settings rule, `mode`, or
  `hook`. A `deny` with `by: "hook"` is how a mod holding a command (and the person
  cancelling it there) shows up. Such a mod acts before Claude Code's own permission
  check, so a call it holds is `by: "hook"` even where a settings rule would also have
  refused it.
- `subagents` counts subagents launched and not yet finished, background ones
  included (`0` when none); foreground ones are dropped when the main turn ends.
- `ended` is set when Claude Code ends the session. The mod cannot delete a file, so
  a frontend removes `mods.d/<id>.json` once the `state.d` row is gone and either
  `ended` is true or `ts` is more than 24 hours old.
- A frontend turns each decision into one `decisions.jsonl` row (`via: "claude"`),
  keyed by `id`, and never again for the same id. It MAY keep its own record of the
  ids it has ledgered (AgentBar: `mods.d/.ingested.json`); a dot-file in `mods.d/` is
  never a sidecar.

The mod reads `mods/config.json` (`{"band": true}` turns on the line it draws above
Claude Code's prompt when *another* session waits on the person — off unless set).
`AGENTBAR_HOME` moves `mods.d/` and `mods/` with everything else.

## rules.json — what the human decided in advance

Optional. One JSON document at `~/.agentbar/rules.json`, written by a frontend and
edited by hand. Its subject is the one thing everything else in this protocol
avoids: **answering without asking.**

```json
{
  "v": 1,
  "rules": [
    {
      "id": "r-3f9c1a",            // unique in the file; names the firing in decisions.jsonl
      "created": 1789646400,
      "decision": "allow",         // allow | deny
      "agent": "",                 // "" = any agent
      "shape": "bash:git status",  // exactly the decisions.jsonl key, same normalisation
      "cwd": "/Users/me/AgentBar", // "" = anywhere, DENIALS ONLY
      "note": "read-only",         // the person's own memo; never sent anywhere
      "tell": "",                  // OPTIONAL, deny only: said to the agent on every refusal
      "mode": "watch"           // on | watch | off; absent means "on"
    }
  ]
}
```

Normative, and the reason each one is here:

- A rule is matched on `shape`, which by design carries **no arguments**. That is
  safe for a denial and not safe on its own for an approval, which is what the
  refusal list below exists for.
- `cwd` empty means "any directory" and is **legal only for `decision:"deny"`**.
  Refusing more than the user meant costs a prompt; approving more than they meant
  is the failure this whole file has to not have. A reader MUST refuse a file
  containing an approving rule with no `cwd`.
- A non-empty `cwd` is absolute and **written plainly**: no trailing `/`, no `//`,
  no `.` or `..` part (`/` itself is plain). Directories are compared as text, so
  `/x/repo/` would never match a session in `/x/repo`, and `/x/repo/../other`
  names somewhere the person did not write down. A reader MUST refuse the file
  rather than tidy it — textually, without resolving symlinks.
- A rule MUST NOT be created from a `ruleSuggestion`. Suggestions are produced by
  the agent being guarded; a rule is written from what the person did.
- `mode` is `on` (answers), `watch` (answers nothing and writes down what it
  would have answered) or `off` (does nothing). Absent means `on`. A `mode` that
  is present and unreadable **refuses the file**: a typo must never be read as
  "start answering". `watch` exists because an approving rule cannot be checked by
  reading it — you find out whether it matched what you pictured by watching it
  not answer for a week, which is what everything else that enforces anything
  does before it enforces.
- `tell` is what a **denying** rule says to the agent when it refuses — written to
  the answer as its `message`. It is a field of its own rather than a reuse of
  `note`, because `note` was always private and a memo must not start arriving in
  an agent's context because the format grew. A reader MUST refuse a file in which
  an approving rule carries a non-empty `tell`: an approval has nothing to explain.
  Readers that predate it ignore it, and the rule still refuses.
- The file carries **no counters**. What a rule has done is read back from
  `decisions.jsonl` by its `id`, so intent and record never disagree.
- **A file that does not parse, or that contains one invalid rule, means no rule is
  applied at all.** Not the valid ones, not a best effort: a policy half in force
  leaves someone believing they wrote four rules while three are running, with
  nothing on screen saying which. A frontend SHOULD surface the refusal (AgentBar
  does, in Diagnostics) rather than fail silently, because silence here looks
  exactly like working correctly. "Parses" means strict JSON: a trailing comma, or
  a key written twice in one object, is refused — readers disagree about what
  either means (one JSON library keeps the first of two equal keys, another the
  last), and a rule that says `deny` and then `allow` must not mean one thing to
  the app and another to `agentbar rules`. A field that is present must have its
  type: `"agent": 5` is a refusal, not "any agent".
- `v` is the number `1` exactly; `"1"`, `1.5` and `true` are not it.
- An unknown `v` is refused for the same reason: a later version may add a field
  that *narrows* a rule, and ignoring it would apply a wider rule than was written.

A rule whose `mode` is `watch` is matched exactly as an `on` rule is — including
the live-request re-check below, because the answer being written down has to be
the answer that would have been given — and then writes a `watch` row instead of
an answer.

**Before writing an `allow` answer from a rule, a frontend MUST re-check the live
request** — the command as it will actually run, not its shape — and fall through
to the human on any of: more than one command on the line, or a pipe, redirect,
background or substitution; elevation (`sudo` and friends); a destructive or
history-rewriting subcommand; anything that reaches off the machine; a path outside
the rule's `cwd`; a path that configures permission itself (`~/.agentbar`, an
agent's settings directory, `.git/hooks`, `.git/config`); a plan review or a
question; and anything it cannot parse — an unterminated quote, a line break of
any kind (`\n`, `\r`, `\r\n`), or a request whose text the reader could not keep
exactly (a JSON string that begins with U+FEFF loses it in some decoders, and the
command it leaves is not the one that runs). `deny` skips these checks. The list is not
exhaustive and is expected to grow; the rule is that it may only ever grow.

Today only the macOS app applies rules. `agentbar rules` lists them and says so:
the live-request check is one table, and a second implementation of it is a second
thing to keep byte-identical in the one place where drifting apart means approving
something nobody meant to. (`shape` is already normalised twice — in
`DecisionLedger.swift` and in the CLI — and that is one copy too many already.)
Every rule the two halves both implement — `shape`, reading `rules.json`,
`wire-disabled`, `wire-enabled`, unwiring, session rows — is pinned by one language-neutral fixture
per rule under `Tests/Fixtures/`, which the Swift suite and the CLI suite both read;
a case is added there, never to one side alone.

## wire-disabled — agents the person switched off

Optional. `~/.agentbar/wire-disabled` lists the agents both installers — the macOS
app's on every launch, the CLI's `install-hooks` — must **unwire** instead of wire:

```
# Agents AgentBar leaves unwired, one id per line.
# Written by AgentBar (Settings > Agents) and the agentbar CLI.
cursor
gemini   # a trailing comment too
```

- One agent id per line (the ids above, plus the integration id `claude-mod`, below).
  Everything after `#` is a comment;
  surrounding blanks are trimmed; ids are lowercased; a line that is not
  `^[a-z0-9][a-z0-9_-]*$` is skipped, never trusted.
- An id a reader does not know is **kept** when it rewrites the file, so a newer
  frontend's agent survives an older one saving it.
- Missing or unreadable means nothing is disabled — the behaviour before the file
  existed. Writers write it atomically, mode `0644`, as the two header lines above
  followed by the ids sorted; saving an empty set **deletes** the file, so "nothing
  disabled" has one spelling on disk.
- Unwiring is the inverse of wiring: AgentBar's rules come out of each config (and
  an event, or `hooks`, left empty goes with them), Antigravity loses its
  top-level `agentbar` key, Codex loses the marker block and AgentBar's own
  `notify` line (someone else's stays), and the two files AgentBar owns outright —
  Copilot's `hooks/agentbar.json`, OpenCode's plugin — are deleted. Every change is
  backed up beside the file first, exactly like a wiring write; a file holding
  nothing of AgentBar's is never rewritten. Sessions already running keep the hooks
  they started with.
- CLI: `agentbar unwire <id>` / `agentbar wire <id>` change one agent;
  `install-hooks --skip a,b` adds to the list and `--only a,b` disables every other
  agent it knows (unknown ids in the file stay). Diagnostics report a listed agent as
  `skipped`, never as a failure.

### wire-enabled — integrations that start off

Every agent is wired the moment it is found. One integration is not: `claude-mod`,
the AgentBar Claude Code mod (`mods.d`, above), which runs inside Claude Code's own
process and so waits until somebody asks for it. Asking is written to
`~/.agentbar/wire-enabled`, read and written by exactly the rules of
`wire-disabled` (same parsing, same atomic `0644` write, saved empty is deleted),
with its own header:

```
# Integrations AgentBar wires only because you asked, one id per line.
# Written by AgentBar (Settings > Agents) and the agentbar CLI.
claude-mod
```

- What an installer unwires is `wire-disabled` plus every default-off id that
  `wire-enabled` does not list. **`wire-disabled` wins**: a `claude-mod` line there
  turns it off whatever `wire-enabled` says.
- Switching it on adds the id here and removes it from `wire-disabled`; switching it
  off removes it from here and writes nothing to `wire-disabled` — off is the file
  not naming it. `agentbar wire claude-mod` / `unwire claude-mod` do the same;
  `install-hooks --only …` switches it on when it names `claude-mod` and off when it
  does not; `--skip claude-mod` lists it in `wire-disabled`.
- Why a second file rather than a line planted in `wire-disabled` on first run: a
  planted line has to remember it was planted (and `wire-disabled` saved empty is
  deleted, which would forget it and switch the mod on), and a machine where the CLI
  runs first would have to plant it too. A missing line meaning off needs no memory
  in any reader. An older frontend knows no default-off id, never wires one, and
  never reads this file.
- Wiring `claude-mod` writes one entry into `env.CLAUDE_CODE_PLUGIN_DIRS` (a
  `:`-separated list of absolute paths) of `settings.json` in every Claude config dir
  the installer knows that exists: the person's own entries stay first and in order,
  any entry containing `/.agentbar/mods/` is replaced, and the real
  `~/.agentbar/mods/claude` goes last (never a sandbox's path — a sandbox wires
  nothing). Unwiring removes every entry containing `/.agentbar/mods/`, drops the key
  when it empties, and drops `env` when that empties. An `env` that is not an object,
  or a value that is not a string, is left exactly as it is. Claude Code older than
  2.1.287 does not read the setting, so the installers skip it there.
- Both frontends copy the bundled mod to `~/.agentbar/mods/<name>` on every run,
  replacing a copy that differs and leaving `mods/config.json` alone.

## Adding a frontend or an agent

A new frontend only needs: read `state.d` (apply the pruning rules), optionally
read `requests.d` and write `answers.d`, and maintain `watcher.json` if it wants
hooks to block for it. A new agent only needs a bridge script that maps its hook
events onto the `state.d` schema above (see `Scripts/hooks/*/` for examples).

### Bring your own agent

An agent AgentBar has never heard of needs no entry anywhere: any `[a-z0-9-]` id is
valid, and frontends render it with a generic mark and its `agent_name`. The CLI's
`agentbar report` writes the row with the same mechanics as the hooks (atomic
write, merge, `started_at` kept, values one-lined and capped). Wrapping any
command-line agent:

```bash
#!/bin/bash
# aider-bar: run aider, show it in AgentBar while it runs.
r() { agentbar report --agent aider --name Aider --pid $$ "$@"; }   # $$: this wrapper
r --state thinking --prompt "$*"
r --state tool --label "Running"
aider "$@"; code=$?
if [ "$code" -eq 0 ]; then r --state done --recap "aider finished"
else r --state error --label "exit $code"; fi
sleep 5; r --state end
```

`--pid` matters: without it the row carries the CLI's parent pid, which for a
one-shot call from a pipeline or a tool runner may be a process that is gone a
moment later — and the row with it. Give it a pid that lives exactly as long as
the agent (the agent's own, or a wrapper's like `$$` above), so the normal
liveness pruning removes the row if the wrapper is killed before it reports `end`. The default row name is
`<agent>-<basename of cwd>`, stable across one-shot calls from the same
directory; pass `--session` to keep two runs in one directory apart.

A writer that would rather not shell out writes the file itself:
`~/.agentbar/state.d/<sessionId>.json`, written to a temp file in the same folder
and renamed over the target:

```json
{ "agent": "aider", "agent_name": "Aider", "state": "tool", "label": "Editing",
  "project": "myproj", "cwd": "/home/me/myproj", "sessionId": "aider-myproj",
  "pid": 4242, "started": true, "started_at": 1784844700, "ts": 1784844796 }
```

Delete the file for `end`. Lone UTF-16 surrogates must never reach the file (cut
on code points, not code units): one makes the macOS app reject the whole row.

**Approvals are not possible this way, by design.** There is no `permission`
state in `agentbar report`, and a row alone never creates a request: an approval
is a rendezvous with a hook that blocks the agent while the human decides
(`requests.d`, above). A wrapper has nothing waiting on the answer, so offering
one would be a button that does nothing. Use `question` when the agent waits on its
user. Approvals need a native bridge that blocks the agent's own permission step.

An agent with no usable hook mechanism can still be covered by a **watcher** in
the frontend that upserts `state.d` files itself — same schema, same pruning
rules. AgentBar does this for Antigravity (sparse hooks) and for Claude Cowork,
which hands every session a throwaway config directory so there is nothing to
install into. A watcher MUST leave newer hook writes alone and SHOULD stamp a
`pid` that dies with the session, so the normal pruning rules clean up after it.

Sessions that run on a vendor's infrastructure (cloud agents) are the same
pattern taken out of process: an external poller writes rows with
`entrypoint: "cloud"`, a `url`, `cwd: ""` (there is no local checkout — a
non-empty cwd would advertise the wrong git branch), and the **poller's own
pid** — rows die with the poller. Cloud writers MUST NOT write `requests.d`:
remote approval is a rendezvous with a blocking local hook, and no such hook
exists for a cloud session. Use `question` (not `permission`) when a cloud
session waits on its user, so frontends never offer a keystroke approval that
has nowhere to land.

That is a MUST on writers, and anybody may write a row — so a frontend SHOULD
refuse to aim a keystroke at a row carrying `entrypoint: "cloud"` whatever its
`state` says, rather than trust every writer to have read this paragraph. Both of
AgentBar's halves do: the poller rewrites `permission` to `question` as it builds
the row, and the app checks the entrypoint before it types anything
(`AgentActions.mayKeystroke`).
