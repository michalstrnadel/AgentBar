# Testing AgentBar

Everything outside the Swift app — the hook scripts, the agent bridges, the
OpenCode plugin and the cross-platform CLI — is plain Node and bash, and is
tested end-to-end against a throwaway `HOME` on any OS. The Swift app is
compiled in CI and unit-tested where its behaviour can be reached without a
running app; its two watchers have live-app integration suites that only run on
a Mac with the app up. This page says what each suite covers, how to run it, and
how to add to it.

## The suites

| Suite | Covers | Checks | Needs |
|---|---|---|---|
| `Scripts/test/permission-hook-test.sh` | The Claude hooks: `permission.js` (allow/always/deny/defer round-trips, rule forgery, questions, plans, timeouts, signals, successor/`hookPid` guards, surrogate-safe cuts, the session's `cwd` carried and omitted rather than emptied, **and Codex's dialect: a prefixed row and a `<session>-<turn>` request, Claude's envelope back, an *Always* with nothing to pin it to degrading to a one-shot allow, and the prefix staying off every other agent's rows**, **and the fall-through contract clause by clause: F1-F14 from `SECURITY.md`, each asserted under its own number so a clause nobody checks reads as a gap rather than hiding inside a scenario**), `update.js` (state mapping incl. Copilot's `recoverable` error, `started_at`, prompt/model/recap/activity rules, stalled stdin), `lifecycle.js` (seed, merge on resume/compact/clear, the mid-prompt open, dead-only sweep, launch guard, end), **"Compacting…" from `PreCompact` and the compaction's end restoring what the row said before it — a finished turn lands on `done` with its recap, a mid-turn one on what it was doing**, and **payloads nobody sane would send** — a command longer than any screen, an input nested two thousand deep, a session id shaped like a path, a lone surrogate, a tool name that is a number, every field null — each of which must exit 0, say nothing, and write only under `~/.agentbar`, because a host that reads a crash as a refusal would turn a malformed payload into a denial nobody made — and the same nonsense handed to the quiet hooks, whose failure is silent instead: a state file Swift cannot decode hides the session from every frontend, so every string they write has to survive a UTF-8 encode, **including a surrogate that arrived unpaired rather than one a cut created**; and **a note on a denial** (carried as the message, flattened to one line and capped, a blank or non-string note leaving the bare deny, a plan's feedback riding its keep-planning message, Copilot's bare envelope carrying it, and a lone surrogate never reaching the host); and **the launch an agent makes** — `open -g -a /Applications/AgentBar.app --args --background`, by path so no dev build answers instead, and marked so the app opens no window for it | 262 | node, python3 |
| `Scripts/test/bridge-hooks-test.sh` | The Cursor, Gemini, Antigravity and Codex bridges: dead-only stale sweep, app-launch guard (fake `open` in `PATH`), event → state mapping, project/prompt merge across events, the 64-char id cap, surrogate-safe cuts — and, since a cut is not the only way to get one, a lone surrogate already in the payload dropped on the way out rather than written into a file no frontend can read — Antigravity's fail-open `PreToolUse` decision — held to it against seven payloads nobody sane would send, because `agy` reads silence, a crash or any other stdout as *deny*, so a malformed payload must not become a refused tool call, and the Codex notify bridge standing down once the real hooks are wired **and** accepted — but never while they are only written, nor when the config cannot be read; and the Codex shim, which is where the shared scripts learn who is asking — a prefixed row, a live state rather than a bare `done`, an id that agrees with its own file name, the agent's own pid as the parent, a session that ends by deleting its row, and nothing at all run for a script name it cannot vouch for; and the **Aider, goose, Cline and Amp** bridges — each reporting status only, the agent's own pid rather than a shell's, nothing launched, no decision ever returned, garbage payloads harmless | 141 | node, python3 |
| `Scripts/test/opencode-plugin-test.sh` | The OpenCode plugin, loaded as ESM and driven through its event bus: created/prompt/tool/permission/idle/error/title/child/deleted — including "the idle that trails an error stays an error" | 25 | node |
| `Scripts/test/cli-test.sh` | `Scripts/cli/agentbar`: status/requests rendering, pruning rules, approve/deny/answer (incl. plan and multi-question refusals, `hookPid` stamping), waybar classes and heartbeat, the hook blocking on the CLI's presence, the history record an ended session leaves behind (baseline, once per ending, `idle` is not an ending, the weight read out of a Claude transcript with duplicate lines counted once, an agent with nothing on disk leaving the key out rather than writing zero, a Codex session whose whole cost was cached input still having a weight, and a quiet Antigravity session decaying to done here the way it does in the app — it is the one agent with no terminal event at all), `install-hooks` for every agent (idempotent, unparseable config untouched, `CLAUDE_CONFIG_DIR`, Copilot's own hooks file left alone, the written node path stable and the same interpreter, a dead Codex interpreter repaired), and `usage` (reading past a `premium` line to the account's windows, a rolled-over window carrying no bar, a stale rollout speaking for nothing, and naming what it could not ask rather than omitting it, and a reset time past the year 2100 dropped rather than printed as an invalid date — the same ceiling the app applies, where the same number is a crash), and the decision ledger (a decision recorded only once it reached `answers.d`, the shape keeping the verb and dropping every argument, the directory taken off the request and only then off the session, the wait measured, repeats not collapsing, `approvals` and `forget`), and the rules the human wrote (listed with what each has done, a firing counted from the ledger and never from a counter in the file, one bad rule or an unreadable `mode` voiding the whole file, a watching rule counted as what it *would* have done and as nothing that happened, and the command saying plainly that it lists rules rather than applying them), the decisions exported as CSV (a header, one row per decision, oldest first, a date rather than a number, and a leading `=` defused so a spreadsheet does not evaluate a command an agent wanted to run), and the Codex hooks block (every event present, the approval timeout above the hook's own wait, `SessionEnd` inside the cap Codex clamps to, the user's keys untouched, written exactly once, idempotent, and **notify still installed beside it** — the block carries the same path, so a blind marker match used to read it as "notify is wired"); `deny --note` (the note written, echoed, blank meaning none, refused on approve, never cut mid-emoji) and a denying rule's `tell` listed, an approving one voiding the file; and **working time** — `agentbar history` totalling the `spans` a line carries rather than how long the window was open, and a CLI-written line keeping the app's `spans` so the last-line-wins rule cannot erase them | 277 | node, python3 |
| `Scripts/test/doctor-test.sh` | `agentbar doctor`: a clean install reporting clean, an interpreter that moved, an agent installed but unwired, the escaped-slash marker trap, a config the installer refuses to touch, directories missing or unwritable, last-seen read from `history.jsonl` (blank is fine, a fortnight of silence is not), `--json`, a Codex hooks block written but not yet accepted, the rules file reported the way the app reports it — skipped, counted by mode, or failing whole — and that a diagnostic changes nothing it diagnoses. Assertions are by check id, never wording — see `docs/diagnostics.md` | 64 | node |
| `Scripts/cloud/test/*.test.js` | The cloud poller's adapters, which turn three vendors' very different task APIs into the same row: Codex's `ready` becoming `done` with a diffstat recap, Devin's `blocked` being a question and never a permission (nothing off this machine may raise an approval), both of Devin's and Cursor's payload shapes, the browser-versus-app URL, a run status outranking the agent's, retention keeping a thinking row and ageing out a finished one, and the invariants every cloud row carries — no `cwd`, `entrypoint: "cloud"`, and a frozen `ts` once it is terminal, plus the one state a run on somebody else's machine may not claim: `permission` is rewritten to `question` where the row is built, not left to each adapter; and **ssh hosts** (a host that could be read as an option never reaching argv, a long name shortened and a bad one reported, rows keeping their own agent while a remote permission arrives as a question, a host that is down costing only its own rows and only after a grace of polls, absurd times clamped, rows per host capped, and the real remote script run under a tcsh login shell with a banner, printing live rows and dropping dead ones) | 24 | node |
| `Tests/AgentBarTests/` (`swift test`) | The Swift app where it can be reached without a running app: the updater's relaunch script (new bundle opens; it refuses and the backup is restored and launched; both refuse and the old bundle stays with the staging dir kept; a hostile bundle path stays out of the shell's parser); the island's display choice (defaults, round-trip, a pinned display unplugged falling back to the pointer without losing the pin); the display row wrapping at one display through eight; the installer's node-path stabilisation and Codex repair; the history edge detector (a lingering `done` row written once, `idle` not an ending, a torn line costing one line, prune leaving an unchanged file alone); the digest's arithmetic (local midnight, a partial total saying what it covers, an end before its start not counting as timed, a token clause that drops rather than showing zero); what does and does not deserve a notification (off means off, an answered request is withdrawn, a watchdog-decayed end is not announced, **a successful turn is not an event at all**, the quiet burst announced once and only once the human is away, `notifyDone` migrating exactly once); what a session cost (duplicate transcript lines counted once, Codex's last cumulative `token_count` winning, Copilot's rows summed through real SQLite, every reader answering nil rather than zero, a token count too big for an `Int` read as no count rather than trapping on the way past it, a rollout claiming more cache than input flooring at zero, and a line torn by a crash mid-append costing only itself); what moved in the repo (the per-file subtraction and its zero floor, a binary counted as a file and no lines, a missing baseline producing nothing); what each provider has left (a rollout read past its `premium` bucket to the account's windows, a credit line only for an account that has credits, a rolled-over window refusing to quote the old number, Claude's `utilization` taken as a percentage and not a fraction, an expired credential left unused, Copilot's local day as a range against a UTC column, **only Claude's own field read out of a credential record that also holds every MCP server's token**, a zero expiry meaning no expiry rather than 1970, every failure carrying a sentence that names a cause, a token pasted in on purpose outranking the CLI's own, **one answer to the Keychain prompt remembered in both directions so no clock ever raises it**, a question not asked told apart from a login not there, **the hop to the main thread that every WebKit touch goes through, immediate when it is already there**, the island's line carrying what is running plus anything nearly spent, and **that line stating its own width**, since nothing else states one for it, and then **staying inside the width it is given**, since nothing clips it to that either); what the human decided (the shape's verb for multiplexers, leading `sudo`/env stripped, only the first command of a chain, no arguments kept at all, counts scoped per repo, defer and answer not counted as verdicts, the *Always* nudge needing repeats AND a clean record, a request with no timestamp contributing no wait); the diff on an approval card (a change in the middle being what you see, a gap where untouched lines were skipped, the cap announcing itself, the changed middle of a one-line edit measured in Characters and not UTF-16, a change past the right edge slid into view and a pair slid by one shared amount); the process runner giving up on a child that never returns; the launcher (a prompt round-tripping through a real `/bin/sh` as one argument whatever it contains, only agents with a verified prompt argument being handed one, recent projects deduped and still on disk); **the rules the human wrote** — the file (a round trip, one bad rule voiding all of it, an approving rule with no directory refused, a newer version refused rather than guessed at) and the engine (deny beating allow, a denial applying anywhere and an approval only in its own directory, a neighbouring checkout with a shared prefix staying outside, and the refusal table: a chained or piped line, `sudo` arriving under an innocent shape, a quoted flag not hiding it, destructive git and rm, anything reaching off the machine, a path outside the rule's directory or into anything that configures permission, a plan, a question, a tool that names nothing — plus the invariant that no matching rule means nothing is written at all), the three modes (a watching rule reaching a verdict and still answering nothing, a `watch` row counted by nothing as something that happened and by `wouldHave` as what would have, an unreadable `mode` refusing the file rather than defaulting to "on"), and the sheet's try-a-command field (what would happen, what the rule does not cover, and that no approving rule ever takes a `git push`); the record exported as a spreadsheet (oldest first, a watching rule's row included and saying what it would have done, and a formula defused only where it starts a field); which sessions a keystroke may be aimed at — never a cloud row, whose terminal is on somebody else's machine, and never an agent with no keys; every diagnostic check, by id, and the fixes it can carry out itself (only where the fix is AgentBar's to make, the directories actually created, and a sweep that takes the stale and leaves the live, and the two silences the approval self-test has to tell apart by the clock because every fall-through path exits 0); and numbers out of files AgentBar does not write — a reset time past `Int.max` and a wait longer than a year, both of which `Int(_:)` traps on rather than rounds; **the menu's session rows** (each state's dot and words, a finished row's recap cut at sixty, an ended row dimmed and timeless, the width held between its bounds, and a long detail giving way before the project name ever does); **the two empties** (a fresh install saying what to do, an ordinary quiet moment staying one line, a menu line wrapped at words without losing one); and **"Compacting…"** (the hook and the app agreeing on the exact label, the bar holding one word for it, and a stale label on a finished row not counting); and **jump-back beyond the three tty-aware terminals** (only hosts whose select reports a verified landing being aimable by a keystroke — tmux yes, kitty, Ghostty and the editors never; one TERM_PROGRAM-to-app mapping; tmux's pane and client lines read by tty with a malformed line skipped rather than shifted, the client already on the pane's session winning, the last-used one switched otherwise, and iTerm2's `-CC` gateway never chosen; a process-table walk that passes an editor's helper, finds no host above a daemonised tmux server, and ends on a loop; kitty asked for the whole ancestry with its own socket first); and **`agentbar://` links**, which any web page can open (no host that approves, denies, answers, writes a rule or runs anything parsing as anything at all, a key given twice refusing the link, a `cwd` that is relative, missing, a file, or reaches through `..` refused, a prompt one character over the cap refused rather than cut, newlines and right-to-left overrides taken out of it and script-looking text arriving as plain words, and "the session that needs you" being a permission before a question before work, and nobody when nothing waits); and **your own sounds** (each cue found under its own name and in any case, everything else in the folder ignored, several files for one cue chosen by extension order, a file over 2 MB never chosen while a smaller one for the same cue still is, a real WAV over 3 s refused from its header, something that is not audio refused, a short stereo file loaded with the 10 ms lead-in in front, and the Settings line naming what is yours and what was passed over and why); and since 1.44: **Your Day** (the card deterministic frame by frame, the build ending on the still card, both shapes, share-safe names, working time from Claude's transcript or recorded `spans` — a window open all day counting only its work — and you by the hour), **Allow all alike** (same tool, whole input and directory; only what was on screen), the **demo request** writing no answer file, **handoff** prompts, **the week of decisions**, a hook or update launch opening no welcome window, and **Mission Control** hiding the island | 824 | Swift 6 toolchain |
| `Scripts/test/antigravity-watcher-test.sh` | `AntigravityWatcher` against a staged `brain/` transcript: thinking → permission → done | — | macOS, app running, `AGENTBAR_LIVE_TESTS=1` |
| `Scripts/test/cowork-watcher-test.sh` | `CoworkWatcher` against a staged audit log | — | macOS, app + Claude.app running, `AGENTBAR_LIVE_TESTS=1` |

Counts are as of this writing; each suite prints its own `N passed, M failed`
line and exits non-zero on any failure. The two live-app suites skip cleanly
("skip: AgentBar app not running") when their preconditions are missing.

## Running

```bash
swift test                                # Swift unit tests (needs Swift 6)
./Scripts/test/permission-hook-test.sh
./Scripts/test/bridge-hooks-test.sh
./Scripts/test/opencode-plugin-test.sh
./Scripts/test/cli-test.sh
./Scripts/test/doctor-test.sh
node --test Scripts/cloud/test/*.test.js  # the cloud poller's adapters
```

The glob matters in that last one: handed the directory instead, node's test runner
tries to run it as a test file and sits there until it times out.

Each suite creates its own temp `HOME` per scenario (`fresh_home`) and removes
it on exit, so nothing touches your real `~/.agentbar` or any agent's config —
with one historical exception worth knowing: `install-hooks` honors
`CLAUDE_CONFIG_DIR`, so `cli-test.sh` unsets it first. Keep that line if you
copy the pattern.

Runtime: the permission suite takes ~1.5 minutes (it exercises real timeouts);
the others finish in seconds.

### When `swift test` says the macro plugin is missing

On a Mac with **only the Command Line Tools** (no Xcode), `swift test` can fail with
dozens of `external macro implementation type 'TestingMacros.…' could not be found`
errors on files you did not touch. That is not your code: the toolchain's build system
omits the TestingMacros plugin from the *emit-module* invocation while including it in
the compile one, so the failure alternates from run to run. It reproduces on a package
created fresh by `swift package init`, which is the quickest way to confirm it is the
machine and not the change.

Pass the plugin yourself:

```bash
CLT=/Library/Developer/CommandLineTools
swift test -Xswiftc -load-resolved-plugin -Xswiftc \
  "$CLT/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib#$CLT/usr/bin/swift-plugin-server#TestingMacros"
```

It can still need a second run — the stale command is cached per file. CI installs
Xcode and never sees this.

### Environment knobs the scripts honor

| Variable | Honored by | Meaning |
|---|---|---|
| `AGENTBAR_FORCE_APP=1\|0` | `permission.js`, `lifecycle.js`, all four bridges | Pretend a frontend is / isn't running, instead of `pgrep AgentBar` (macOS) or the `watcher.json` heartbeat. `0` is what makes the stale sweep and the launch path testable; `1` skips both. |
| `AGENTBAR_APPROVAL_TIMEOUT=<s>` | `permission.js` | Seconds to wait for an answer (default 600). Tests use 2–30. |
| `AGENTBAR_AGENT=<id>` | `lifecycle.js`, `update.js` | The agent id the row is written under (how Qwen Code and Copilot CLI reuse the Claude scripts). |
| `NODE=<path>` | every suite | Which `node` to run the scripts with. |

The launch path spawns `open -g -a /Applications/AgentBar.app --args --background`
on macOS only (by bundle ID, `-b`, when no installed copy exists): by path, so
LaunchServices cannot pick a dev build instead, and `--background` so the app
puts no window up for a launch nobody made by hand. Tests put a fake `open` first
in `PATH` that writes its arguments to `$FAKEOPEN_MARK`, so a suite can never
start a real AgentBar and can check what it was asked — and the positive
assertions ("launches when down", "launch is --background") are guarded with
`[ "$(uname)" != "Darwin" ] ||` because on Linux the spawn never happens.

## CI

`.github/workflows/ci.yml` runs all five portable suites, and the
cloud poller's `node --test` run, twice — on `macos-14` and on `ubuntu-latest`
(Node 20) — builds the universal app bundle on
macOS (`./Scripts/build.sh`), which is what compiles every Swift change, and runs
`swift test` on `macos-15`. A PR is green only when all four jobs pass.

The Swift suite uses **swift-testing** (`import Testing`), not XCTest, and that is
deliberate: XCTest only resolves under a full Xcode install, while swift-testing
ships with the toolchain — so `swift test` works on a machine that has nothing but
the Command Line Tools. It needs Swift 6, which is why that job runs on `macos-15`.

Two local caveats worth knowing. A stale module cache reports `plugin for module
'TestingMacros' not found`. **Alternating `swift build` and `swift test` is what
causes it most often** — building the product target evicts the macro plugin, and
the next `swift test` fails before rebuilding it. Simply running `swift test` again
is usually the whole fix; `swift package reset` clears it when it is not
(`swift package clean` is sometimes not enough). And `./Scripts/build.sh` builds universal, so it needs an x86_64 Swift
runtime — Command Line Tools alone ships `libswiftCompatibility56.a` for arm64
only, and the link fails there with `Undefined symbols for architecture x86_64`.
Use `./Scripts/build.sh --native` for a runnable dev bundle (this Mac's
architecture only), or `swift build` for a compile check. Releases stay
universal — CI has a full Xcode and both slices.

## Writing a test

The suites share one shape, and new checks should keep to it:

- `check "short name" 'shell condition'` — the condition is `eval`'d; `ok`/`FAIL`
  is printed per check and the counts summed at the end. Names read like the
  invariant they protect ("sweep keeps live session"), not like the code.
- `fresh_home` before every independent scenario. Assert on the **files** the
  protocol defines (`state.d/*.json`, `requests.d`, `answers.d`,
  `watcher.json`), not on script internals — the files are the contract.
- Drive hooks the way their host does: JSON on stdin (`printf … | node hook.js
  <event>`), the Codex notify payload as `argv[2]`, the OpenCode plugin via
  `import()` + factory (see `opencode-plugin-test.sh`'s driver).
- For a blocking `permission.js` run, start it in the background, `wait_req`
  for the request file, drop an answer into `answers.d/`, then `wait` on the
  pid and read its stdout.
- JSON assertions: `grep -q '"field":"value"'` is fine for flat fields (the
  hooks write compact JSON with no spaces). For structure, or for "is this
  well-formed UTF-16?", use python3 — `json.load(...)[key].encode("utf-8")`
  raises on a lone surrogate, which is exactly the class of bug the
  surrogate-safe cuts guard against.
- Time-based behaviour (poll intervals, the ~2 s retire) is asserted with
  bounded waits (`sleep 1`, `for _ in $(seq 50)`), never with fixed long sleeps.
- **A new test must fail on the old code.** Before committing a fix + test
  pair, run the test against the unfixed script (stash the fix, or `git show
  main:path > /tmp/old.js` and point `NODE`/the path at it) and watch it go red.

When a hook fix touches the protocol, update `docs/protocol.md` in the same
commit — the tests assert the protocol, so a silent divergence there will
mislead the next reader.

## What is not covered here, and why

- **Most of the Swift.** The app is a thin AppKit layer over the file protocol,
  and the logic worth testing (state mapping, pruning, identity of requests)
  lives in the hooks and is tested there. What the swift-testing target does
  cover is the app-side logic with no hook equivalent: the relaunch script,
  island display resolution, display-picker geometry, the history edge
  detector, the installer's node-path and Codex repair, and every diagnostic
  check. CI also compiles the Swift on macOS, which catches everything a type
  checker can.
- **Visual behaviour** (island layout, menu rendering, sprite animation). Run
  the app; `Scripts/dev/render-preview.swift` screenshots the real island views
  for eyeballing.
- **The two watchers' file-format parsing** is tested only through the live-app
  suites, because their inputs are what the third-party apps write.

## Keeping the two halves honest

`Scripts/cli/agentbar` is a transliteration of the app with no shared source, so the
cheapest bug in this repo is one half drifting from the other while both stay green.
Two suites catch behaviour; what they cannot catch is a table that grew on one side
only. That is compared by extracting the tables and diffing them, which takes a
minute and has found three real bugs:

- the event wired per agent (`claude`, `codex`, `copilot`, `cursor`, `gemini`/`qwen`,
  `antigravity`), with its script, argument and timeout
- the multiplexer list the decision shape is built from
- every pruning window — `state.d` 24 h, `requests.d` 660 s, `answers.d` 60 s
- what counts as a session ending, and what a weight has to contain to exist
- the ids `doctor` reports, against `Diagnostics.run`

Five ids legitimately differ and are meant to: `app.accessibility`,
`app.singleInstance` and `app.islandPin` are macOS notions with no Linux
counterpart, `claude.configDir` is checked by the app only, and
`frontend.present` asks whether a frontend is running, which the app already knows
about itself. Everything else matching is the contract.

## What was checked by hand, against the running app

A suite proves the logic; it does not prove that the app anybody installed is
wired to it. These were run on 19 Sep 2026 against **1.28.0 in `/Applications`**,
using the hook as installed in `~/.agentbar/hooks` and a real request, and they
are worth repeating whenever the approval path is touched:

| What | How it was seen |
|---|---|
| The whole path, allow and deny | The installed `permission.js` was run with a real payload, answered from `agentbar approve` / `deny`, and printed the envelope an agent would have received |
| A rule the human wrote answers | An `on` rule for `bash:echo` in one directory answered in under a second, with a ledger row carrying `via:"rule"` and the rule's id |
| A watching rule answers nothing | The same rule in `watch` mode wrote `decision:"watch"` naming itself, and the prompt still went to the human |
| **The refusal table stops an approving rule** | A rule written to allow `bash:git push`, in the right directory, in `on` mode, did not answer: the hook waited out its deadline and wrote nothing, and no ledger row was written at all. Same for `git status && echo …` under a rule for `git status` |
| A denying rule may be broad | A `deny` rule with no directory answered a `curl` immediately, and the row names it |
| The Codex shim, end to end | `hook.js permission.js` with a Codex payload wrote `requests.d/codex-<session>-<turn>.json` and a `state.d/codex-<session>.json` row, filed the request under `codex`, and returned Claude's envelope |
| The notify bridge has not stood down | With the hooks written and **not** yet accepted, `notify.js` still wrote its row — which is the only thing showing a Codex session in that window |

The one that matters is the fourth: it is the difference between a rule engine and
a rule engine somebody can widen by writing the rule they wanted. It failing would
look exactly like it working, from everywhere except the ledger.

Still not checked by hand: the Codex trust prompt (needs a real Codex session), and
the rule sheet's own editor.
