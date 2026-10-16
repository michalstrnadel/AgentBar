# Never an implicit approval

AgentBar sits in the path where an agent asks a person for permission. This page
is the promise it makes there, every way it can fail, and the test that holds each
one on every release.

## The invariant

> **A tool call is approved through AgentBar only when an answer that says `allow`
> (or `always`) reaches the one hook waiting on that exact request: a click on the
> card for it, a tap on the phone push for it, or a rule the person wrote that
> matches it. On every other path, the hook writes nothing, and the agent shows
> its own prompt, as if AgentBar were not installed.**

Nothing is the whole mechanism. Claude Code, Copilot CLI and Codex CLI all read an
empty stdout from a permission hook as "nobody decided" and fall back to their own
prompt (measured, with versions, in [permission-surfaces.md](permission-surfaces.md)).
So a failure that is caught does not need a decision written for it. It needs the
hook to exit without saying anything. That is all `permission.js` does on a failure,
and the only two shapes it ever prints are the decision envelopes in `respond()`.

The numbered clauses (F1–F23) are the same ones listed in
[SECURITY.md](../SECURITY.md#the-fall-through-contract). This page sorts them by what
goes wrong, says which hooks each applies to, and says what the agent shows.

## Which hooks this covers

| Host | Hook event | Script | Can AgentBar approve through it? |
|---|---|---|---|
| Claude Code | `PermissionRequest` | `Scripts/hooks/claude/permission.js` | Yes. The decision goes back inside `hookSpecificOutput`. |
| Copilot CLI | `permissionRequest` | the same script, `AGENTBAR_AGENT=copilot` | Yes. The decision goes back bare as `{"behavior":…}`. |
| Codex CLI | `PermissionRequest` | `Scripts/hooks/codex/hook.js` → `permission.js` | Yes. The decision goes back in Claude's envelope. |
| Antigravity (`agy`) | `PreToolUse` | `Scripts/hooks/antigravity/antigravity.js` | No. See below. |
| Cline | `PreToolUse` | `Scripts/hooks/cline/agentbar.js` | No. See below. |
| Cursor, Gemini CLI, goose, Qwen Code, OpenCode, Amp, Codex `notify` | status events only | their bridges | No. They print nothing. |

**The two bridges that print something.** Both hosts fail closed: a crash, a
non-zero exit or output that is not a valid decision is read as *refuse*. So each
bridge prints a fixed "carry on" line first, on every `PreToolUse`, before it does
anything else. Antigravity's bridge prints `{"decision":"allow"}`, and Cline's prints
`{"cancel":false}`. Neither one reads `answers.d`, a rule, or anything else AgentBar
knows, so the line is the same whether the app is running and whatever is
waiting for an answer. It is how these hosts spell "this hook does not object".
On agy 1.2.14 the host's own permission check still applies after it (verified
2026-10-01, see `Scripts/hooks/antigravity/README.md`). That claim depends on agy's
version. If agy ever treats a hook's `allow` as approving the call by itself, this
bridge stops being harmless and has to be rewired (issue #8), so check it again
whenever agy changes its hook contract.

## What the agent shows

"Its own prompt" means one specific thing for each host:

- **Claude Code**: its permission dialog in the terminal. For a question
  (`AskUserQuestion`), the answer wizard, which was already on screen during the
  wait. For a plan (`ExitPlanMode`), the plan dialog, which was also on screen.
- **Copilot CLI**: its own permission prompt.
- **Codex CLI**: its own approval prompt.

On every path below, that prompt is what appears. The only differences are how
soon it appears and whether AgentBar showed a card first.

## Every failure path

**Hooks** says which approval hooks the row applies to: **all** means Claude Code,
Copilot CLI and Codex CLI; **Claude** means only Claude Code sends that kind of
request. **Prompt** says when the agent's own prompt appears. Each row is driven
through the real scripts by `Scripts/test/contract-test.sh` under its `P` number.

| # | Path | What the code does | Hooks | Prompt | Clause |
|---|---|---|---|---|---|
| P1 | **App not running** | `appRunning()` is false: no `AgentBar` process for this user, and `watcher.json` is missing or older than 60 s. The hook exits before it writes anything. An `allow` already sitting in `answers.d` is never read. | all | immediately | F1 |
| P2 | **App quits mid-wait** | `appRunning()` is checked again every 20 polls (about 2 s). Once it is false, the hook exits and takes its request file with it. | all | within about 2 s | F11 |
| P3 | **`answers.d` missing** | If it is missing at the start, it is created (0700). If it is removed during the wait, there is nothing to read, and the wait ends by timeout or quit. If it, or the state root, is not a directory, `mkdir` throws and the hook exits. | all | at the timeout, or immediately when it is not a directory | F6, F12 |
| P4 | **`answers.d` or `requests.d` not writable** | If `answers.d` is not writable, no answer can land, and the wait ends by timeout. If a leftover answer under the request's name cannot be removed, the hook exits **before** it publishes the request. If `requests.d` is not writable, the request write throws and the hook exits. | all | at the timeout, or immediately | F6, F12, **F23** |
| P5 | **Malformed answer** | The answer is read once. Junk, empty, not JSON, not an object, a directory, or a `behavior` that is not exactly one of the verbs (`"ALLOW"`, `"allow "`, `["allow"]`, `{"decision":"allow"}`) all end the wait with no output. | all | immediately | F7 |
| P6 | **Answer for another session** | The hook opens one file and no other: `answers.d/<its own request name>`. That name is `<session>-<prompt>`, with Codex rows prefixed `codex-` and Copilot named by the hook's own pid. An answer under any other name is never read, and frontends prune orphans after 60 s. | all | at the timeout, unless a real answer comes | — |
| P7 | **Stale answer** (left over before the request existed) | Before the request is published, any file under its name is deleted. If that delete fails, see P4 / F23. | Claude, Codex (Copilot's name is unique per hook) | at the timeout, unless a real answer comes | F23 |
| P8 | **Duplicate answer** | The first answer ends the hook, and its `exit` handler deletes both the request and the answer. A second answer then lands under a name with no request. The next hook to use that name deletes it before it publishes (P7). | Claude, Codex | the second answer reaches nobody | F23 |
| P9 | **Answer for another request** (wrong `hookPid`) | An answer whose `hookPid` is not this hook's own is deleted, and the wait continues. If the request file now carries another hook's pid (a successor took the name), the hook exits without reading the answer. | all | at the timeout, or immediately for a successor | F9, F10 |
| P10 | **Unknown protocol version or verb** | `answers.d` has no version field. Forward compatibility comes from the verb: anything other than `allow`, `always`, `deny`, or `answer` on a question ends the wait silently, and that includes `defer`. Extra fields such as `v` are ignored and cannot turn a non-verb into an allow. A `rules.json` whose `v` is not exactly `1` is void as a whole (P11). | all | immediately | F8, F16 |
| P11 | **Rules file unreadable or malformed** | The hook never reads `rules.json`. Only the app applies rules, and it applies none at all from a file that is unreadable, is not strict JSON, repeats a key, has a trailing comma, has a field of the wrong type, has an unreadable `mode`, or has a newer `v`. Diagnostics reports it. The request goes to the person as if there were no rules. | all | when the person answers, or at the timeout | F16, F17, F20 |
| P12 | **Timeout** | 600 s (`AGENTBAR_APPROVAL_TIMEOUT`). A value that is not positive, or not a number, means 600, never 0. Each host's own hook timeout is set to 630 s, so the hook gives up first and exits silently instead of being killed. | all | after 600 s | F12 |
| P13 | **Full disk** | A write that throws while the request is set up (`ENOSPC`) ends the hook with no output, and no request is published, so nothing can be answered. The state row is best-effort. During the wait the hook writes nothing until it has decided, and the decision goes to a pipe, not to the disk. | all | immediately | F6 |
| P14 | **Clock skew** | No answer is accepted or refused because of a timestamp. The clock only sets the deadline and decides whether `watcher.json` is fresh. If the clock jumps forward, the wait ends early. If it jumps back, the deadline moves later, but the quit check counts polls rather than clock time, and the host's own 630 s timeout still ends the hook (P15). A heartbeat stamped in the future keeps the hook waiting until the timeout. | all | early, on time, or at the host's timeout | F11, F12 |
| P15 | **Hook killed** | On SIGTERM or SIGINT, the hook removes its request and exits 0. SIGHUP or SIGKILL ends it with no output and a non-zero exit. The request it leaves behind is pruned once its `hookPid` is dead, and an answer written to it is a leftover that the next hook of that name deletes (P7). | all | as soon as the host sees the hook end | F13 |
| P16 | **The hook cannot read its input or cannot start** | stdin does not close within 1 s, is empty, is not JSON, or is not an object. The Codex shim gets no script name, or an unsafe one, or the script throws while it loads. In every case the hook exits 0 with nothing printed. If `node` itself is missing, the host gets a failed command with nothing on stdout. | all (the shim: Codex) | immediately | F2–F6 |
| P17 | **A question or a plan** | An `allow` or `always` sent to a question or a plan is deleted, and the wait continues. A question answer that names an option the question never offered ends the wait with nothing printed. If the question or plan is answered in the terminal, the row moves on and the hook retires within about 2 s. | Claude | the wizard or plan dialog, already on screen | F14 |
| P18 | **A rule cannot answer** (app side) | Nothing is written to `answers.d` if no rule matches, the live command trips the refusal table, the request text lost a BOM, the command was cut at 2,000 characters, or the ledger row cannot be written. | all | when the person answers, or at the timeout | F15, F18, F19, F21, F22 |
| B1 | **A status bridge** | No bridge reads `answers.d`. Each one prints nothing, or the fixed line described above, whatever state AgentBar is in. | Antigravity, Cline, Cursor, Gemini, goose, Claude status hooks | the host's own permission flow, every time | — |

### Two things worth knowing

- **A killed hook is the one exit AgentBar does not control.** SIGKILL, or a host
  timeout that is not handled as SIGTERM, gives the host a non-zero exit with
  nothing on stdout. Claude Code documents any exit code other than 2 as a
  non-blocking hook error, so its normal flow continues and the dialog appears.
  `permission.js` never exits with code 2. For Copilot CLI and Codex CLI a killed
  hook has not been measured. Each one's hook timeout sits above the hook's own wait
  so that the hook ends first, and the Copilot installer notes that Copilot's own
  timeouts fail open from 1.0.67 on.
- **An answer with no `hookPid` is still accepted** if it is under the right name
  and arrives after the request was published, as the protocol allows for older
  frontends. That is an answer someone wrote, not a failure. The app and
  the CLI always include it. P7 and P8 are what keep a *leftover* answer without
  one from counting.

## How it is held

- `Scripts/test/contract-test.sh` drives P1–P17 and B1 through the real hook
  scripts. It runs each one as all three approval hosts where that applies, in a
  throwaway `AGENTBAR_HOME`. Every failure path must print nothing. At the end, all
  output from all paths is searched for `allow`. A positive control for each host
  first checks that a real clicked allow does show up, so a hook that printed
  nothing at all could not pass. It also fails if the numbered Swift tests that
  hold P11 and P18, or the shared fixtures for F19 and F20, disappear.
- `Scripts/test/permission-hook-test.sh` covers the same clauses one by one, as
  F1–F14 and F23. `RuleEngineTests` and `RulesStoreTests` cover F15–F18, F21 and
  F22. F19 and F20 are covered by the shared fixtures under `Tests/Fixtures/`,
  which the Swift suite and `cli-test.sh` both read.
- **Releases.** `.github/workflows/ci.yml` runs the contract suite on macOS and
  Linux. A release has to come from a commit whose CI push run succeeded
  ([CONTRIBUTING.md](../CONTRIBUTING.md#releases), step 2), and
  `release-provenance.yml` will not attest one that did not. So a path that approves
  by default fails CI, and a release cannot ship from that commit.

A path that is missing from this table is a bug in this page. Please report it the
way [SECURITY.md](../SECURITY.md) describes.
