# Diagnostics — the check catalogue

`agentbar doctor` (CLI) and **Settings ▸ Diagnostics** (macOS app) answer the same
question: *why isn't this agent showing up?* They are two implementations, the same
way `install-hooks` is — `Sources/AgentBar/Diagnostics.swift` and the `doctor`
function in `Scripts/cli/agentbar`. This file is what keeps them in step: **the
check ids below are the contract.** The wording is free to change; an id is not.

Adding an agent adds `agent.<id>.*` rows on both sides — see rule 5 in `CLAUDE.md`.

## Why this exists at all

Every integration AgentBar has fails the same way: **silently.**

- A hook that is not wired is an *absence*, not an error. Nothing fires, so nothing
  reports.
- A hook wired to an interpreter that has moved never runs — after `nvm install 22`
  or a Homebrew Cellar bump the path in the config names a file that is gone.
- A config the installer refuses to touch (it is *your* file) is skipped with one
  `NSLog` line in Console.app, which nobody reads.
- Hook config is read **once, at session start**, so a change never reaches a
  session that is already running.

In all four cases the user sees "Codex doesn't appear" and has nowhere to look.

## Status values

| status | means |
|---|---|
| `ok` | nothing to do |
| `warn` | works, but something is worth knowing — or will break later |
| `fail` | this is why your agent isn't showing up |
| `skipped` | not applicable, almost always "you don't have this agent" |

A `fail` or `warn` **must** carry a `fix` — a check that reports a problem without
naming the next action is just a nicer way of saying nothing.

## The checks

### Environment

| id | asserts |
|---|---|
| `node.found` | a node interpreter exists at all — every hook is a node script |
| `node.stable` | it is at a path that survives an upgrade, not a version-pinned one. Warn, not fail: an nvm-only machine genuinely has no stable alias |

### The protocol directories

| id | asserts |
|---|---|
| `dirs.state.d` | exists **and an actual write succeeds** |
| `dirs.requests.d` | the same |
| `dirs.answers.d` | the same |

Existence is not enough: a directory can be there and unusable, and this is the
failure hooks hit most often — they have nowhere to report it to.

### Hook scripts

| id | asserts |
|---|---|
| `hooks.copied` | every hook directory survived the copy into `~/.agentbar/hooks/` |
| `hooks.shebang` | `cursor.js` and `antigravity.js` name a real node rather than `#!/usr/bin/env node`. Checked **only for agents that are installed** — the installer pins a script when it wires that agent, so an unpinned copy on a machine without Cursor is fine |

### Per agent

Repeated for each entry in the integration table, `<id>` being the agent id.

| id | asserts |
|---|---|
| `agent.<id>` | emitted **only** when the agent is absent, as `skipped` |
| `agent.<id>.wired` | AgentBar's marker is in its config |
| `agent.<id>.parseable` | the config parses (JSON configs only), emitted only when it does not |
| `agent.<id>.interpreter` | the node path *inside that config* still exists, emitted only when it does not |
| `agent.<id>.lastSeen` | when this agent last reported, from `history.jsonl`. **No record is `ok`**, not a warning — history only starts when a frontend starts keeping it, so every agent is blank on a freshly updated machine and flagging that would bury the one row that matters under eight that don't. Wired and silent for 14 days *is* a warning: that is the shape of a broken integration every other check passes |
| `claude.configDir` | the `~/.agentbar/claude-config-dir` hint agrees with the live `CLAUDE_CONFIG_DIR`. App only, emitted only when the hint exists; the CLI reads the hint for wiring and does not check it |
| `codex.hooks` | Codex has accepted its hooks. Codex runs none until a human says yes, and an unaccepted hook is skipped in silence — so the wired row, which the older `notify` key alone satisfies, cannot tell you. `warn` until the answer lands in `[hooks.state]` |
| `copilot.exec` | Copilot's hook runs node directly. A `bash` wrapper makes the hook's parent a shell that exits at once — and that pid is what prunes dead rows, so every Copilot row would vanish on the next refresh |

Some rows carry a **Fix it** button as well as a sentence — only where the repair is
AgentBar's own to make: re-installing the hooks (wiring, a node path that moved, the
script copies), creating the `~/.agentbar` directories, and clearing files past their
pruning window. A `chmod` on a path in your home stays a sentence, because a button
that silently changed permissions there would be the worse product.

Beside them sits **Test an approval**, which is not a check at all: it raises a real
approval through the real hook and waits for you to answer it. Every other row can
pass while the thing it describes has never once run.


Where each agent lives, and what says it is ours:

| agent | config | marker |
|---|---|---|
| claude | `~/.claude/settings.json` (+ `$CLAUDE_CONFIG_DIR`, + the `claude-config-dir` hint). The CLI checks the same set `install-hooks` writes — a `$CLAUDE_CONFIG_DIR` outside HOME only with `AGENTBAR_ALLOW_CONFIG_OUTSIDE_HOME=1` — and `wired` needs **every one** of them | `/.agentbar/hooks/claude/` |
| codex | `~/.codex/config.toml` | `/.agentbar/hooks/codex/` |
| copilot | `~/.copilot/hooks/agentbar.json` | `/.agentbar/hooks/claude/` |
| cursor | `~/.cursor/hooks.json` | `/.agentbar/hooks/cursor/` |
| gemini | `~/.gemini/settings.json` | `/.agentbar/hooks/gemini/` |
| qwen | `~/.qwen/settings.json` | `/.agentbar/hooks/claude/` |
| antigravity | `~/.gemini/antigravity{,-cli}/hooks.json` | the top-level `agentbar` key |
| opencode | `~/.config/opencode/plugins/agentbar.js` | the file is ours |

### Leftovers and presence

| id | asserts |
|---|---|
| `orphans` | nothing in `state.d` / `requests.d` / `answers.d` is past its pruning window. Warn only — frontends skip them |
| `frontend.present` | somebody can answer a blocking hook: the app on macOS (`pgrep -x AgentBar`), a fresh `watcher.json` heartbeat anywhere. CLI only; the app knows this about itself |
| `rules.file` | `~/.agentbar/rules.json` parses and every rule in it is valid. **`fail` when it does not**, naming the rule — this is the one failure in the app that is invisible by design: no rule fires, every prompt comes back, and that is indistinguishable from AgentBar working normally. `skipped` when there is no file, which is most people. The detail counts the rules by mode (answering / watching / off). Reported by both halves, and the CLI's wording says the app is what applies them — a `doctor --json` pasted into a bug report is often the only thing anybody sees |

### macOS only

| id | asserts |
|---|---|
| `app.singleInstance` | one AgentBar is running. Two both watch *and write* `state.d` and overwrite each other's rows |
| `app.accessibility` | Accessibility is granted — needed only for keystroke approval |
| `app.islandPin` | emitted only when the island is pinned to a display that is not connected |

## Two things the two sides deliberately disagree about

Worth knowing before "fixing" either one.

**Trailing commas.** Foundation's `JSONSerialization` accepts a trailing comma;
Node's `JSON.parse` does not. So a config with one is wired by the macOS installer
and skipped by `install-hooks` on Linux. Each `doctor` matches the installer
standing next to it, because a diagnosis that contradicts the installer on the same
machine is worse than one that is merely incomplete.

**Node candidate order.** The macOS installer prefers `/opt/homebrew/bin` and the
CLI lists `/usr/bin` first. That is not an oversight: in the CLI the list only maps
an already-known-good interpreter onto an equivalent alias, so the order cannot
matter, while on macOS it also decides which node gets used at all.

## The escaped-slash trap

`JSONSerialization` escapes forward slashes, so every config the macOS app writes
reads `"\/.agentbar\/hooks\/claude\/"` on disk. The installers never notice — they
match against the *parsed* value — but anything searching the raw text does. The
first live run of `doctor` reported a perfectly wired Mac as entirely unwired.

Both sides now flatten `\/` to `/` before any raw-text search, and both suites have
a regression test that asserts the raw text really does hide the marker.

## Running it

```bash
agentbar doctor            # human-readable, colored on a TTY
agentbar doctor --json     # what goes into a bug report
```

In the app: **Settings ▸ Diagnostics**, with **Copy report** for the same text.

Tests: `Scripts/test/doctor-test.sh` (CLI, in both CI jobs) and
`Tests/AgentBarTests/DiagnosticsTests.swift` (app). Both assert by **id**, never by
wording.
