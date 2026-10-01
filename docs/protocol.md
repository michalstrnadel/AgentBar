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
  requests.d/  one JSON per pending approval    (writer: permission hook — Claude Code, Copilot CLI, Codex CLI)
  answers.d/   one JSON per user decision       (writer: frontends; reader: the hook)
  watcher.json frontend presence heartbeat      (writer: CLI watch/waybar)
  history.jsonl  one line per ended session     (writer: frontends only)
  decisions.jsonl one line per permission decision (writer: frontends only)
  history-seen.json  the CLI's previous tick, so one-shot commands can diff
  config-changes.json  the macOS installer's last settings writes, as diffs (writer: the app only; mode 0600)
  hooks/       installed copies of the hook scripts (refreshed by the installer)
  claude-config-dir  optional hint: custom CLAUDE_CONFIG_DIR path (one line)
```

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
  "agent": "claude",           // agent id: claude | codex | copilot | antigravity | cursor | gemini | qwen | opencode | devin
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

  "weight": { "in": 1330, "out": 622024, "cacheWrite": 1453897,
              "cacheRead": 220795232, "src": "claude-transcript" },
                               // OPTIONAL: what the session cost, in the agent's own
                               //   numbers. Absent = nobody could measure it.
  "change": { "files": 7, "added": 210, "removed": 80, "base": "3a30264" }
                               // OPTIONAL: what moved in the repo while it ran.
}
```

Rules:

- **Frontends write this, hooks never do.** Hooks exit fast (rule 3), and the
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
- `via` names what answered: `app` | `cli` | **`rule`**. `rule` means nobody was
  asked — a rule the user wrote answered on their behalf (see `rules.json` below).
- `rule` is the id of that rule, and is empty for every other `via`. It is what
  makes a rule auditable: "what has this rule ever done" is answered by filtering
  the ledger on it, which is why the rules file itself holds no counters.
- A reader that reports how many prompts a person answered, or how long agents
  waited on them, MUST count `via:"rule"` rows **separately**. Nobody waited and
  nobody was asked; folding them in overstates one number and understates the other.

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
  exactly like working correctly.
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
question; and anything it cannot parse. `deny` skips these checks. The list is not
exhaustive and is expected to grow; the rule is that it may only ever grow.

Today only the macOS app applies rules. `agentbar rules` lists them and says so:
the live-request check is one table, and a second implementation of it is a second
thing to keep byte-identical in the one place where drifting apart means approving
something nobody meant to. (`shape` is already normalised twice — in
`DecisionLedger.swift` and in the CLI — and that is one copy too many already.)

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
