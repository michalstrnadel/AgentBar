# Testing AgentBar

Everything outside the Swift app — the hook scripts, the agent bridges, the
OpenCode plugin and the cross-platform CLI — is plain Node and bash, and is
tested end-to-end against a throwaway `HOME` on any OS. The Swift app is
compiled (not unit-tested) in CI, and its two watchers have live-app
integration suites that only run on a Mac with the app up. This page says what
each suite covers, how to run it, and how to add to it.

## The suites

| Suite | Covers | Checks | Needs |
|---|---|---|---|
| `Scripts/test/permission-hook-test.sh` | The Claude hooks: `permission.js` (allow/always/deny/defer round-trips, rule forgery, questions, plans, timeouts, signals, successor/`hookPid` guards, surrogate-safe cuts), `update.js` (state mapping, `started_at`, prompt/model/recap/activity rules, stalled stdin), `lifecycle.js` (seed, merge on resume/compact/clear, dead-only sweep, launch guard, end) | 117 | node, python3 |
| `Scripts/test/bridge-hooks-test.sh` | The Cursor, Gemini, Antigravity and Codex bridges: dead-only stale sweep, app-launch guard (fake `open` in `PATH`), event → state mapping, project/prompt merge across events, the 64-char id cap, surrogate-safe cuts | 46 | node, python3 |
| `Scripts/test/opencode-plugin-test.sh` | The OpenCode plugin, loaded as ESM and driven through its event bus: created/prompt/tool/permission/idle/error/title/child/deleted — including "the idle that trails an error stays an error" | 23 | node |
| `Scripts/test/cli-test.sh` | `Scripts/cli/agentbar`: status/requests rendering, pruning rules, approve/deny/answer (incl. plan and multi-question refusals, `hookPid` stamping), waybar classes and heartbeat, the hook blocking on the CLI's presence, `install-hooks` for every agent (idempotent, unparseable config untouched, `CLAUDE_CONFIG_DIR`) | 41 | node, python3 |
| `Scripts/test/antigravity-watcher-test.sh` | `AntigravityWatcher` against a staged `brain/` transcript: thinking → permission → done | — | macOS, app running |
| `Scripts/test/cowork-watcher-test.sh` | `CoworkWatcher` against a staged audit log | — | macOS, app + Claude.app running |

Counts are as of this writing; each suite prints its own `N passed, M failed`
line and exits non-zero on any failure. The two live-app suites skip cleanly
("skip: AgentBar app not running") when their preconditions are missing.

## Running

```bash
./Scripts/test/permission-hook-test.sh
./Scripts/test/bridge-hooks-test.sh
./Scripts/test/opencode-plugin-test.sh
./Scripts/test/cli-test.sh
```

Each suite creates its own temp `HOME` per scenario (`fresh_home`) and removes
it on exit, so nothing touches your real `~/.agentbar` or any agent's config —
with one historical exception worth knowing: `install-hooks` honors
`CLAUDE_CONFIG_DIR`, so `cli-test.sh` unsets it first. Keep that line if you
copy the pattern.

Runtime: the permission suite takes ~1.5 minutes (it exercises real timeouts);
the others finish in seconds.

### Environment knobs the scripts honor

| Variable | Honored by | Meaning |
|---|---|---|
| `AGENTBAR_FORCE_APP=1\|0` | `permission.js`, `lifecycle.js`, all four bridges | Pretend a frontend is / isn't running, instead of `pgrep AgentBar` (macOS) or the `watcher.json` heartbeat. `0` is what makes the stale sweep and the launch path testable; `1` skips both. |
| `AGENTBAR_APPROVAL_TIMEOUT=<s>` | `permission.js` | Seconds to wait for an answer (default 600). Tests use 2–30. |
| `AGENTBAR_AGENT=<id>` | `lifecycle.js`, `update.js` | The agent id the row is written under (how Qwen reuses the Claude scripts). |
| `NODE=<path>` | every suite | Which `node` to run the scripts with. |

The launch path spawns `open -g -b <bundle id>` on macOS only. Tests put a fake
`open` first in `PATH` that touches `$FAKEOPEN_MARK`, so a suite can never start
a real AgentBar — and the positive assertion ("launches when down") is guarded
with `[ "$(uname)" != "Darwin" ] ||` because on Linux the spawn never happens.

## CI

`.github/workflows/ci.yml` runs all four portable suites twice — on
`macos-14` and on `ubuntu-latest` (Node 20) — and builds the universal app
bundle on macOS (`./Scripts/build.sh`), which is what compiles every Swift
change. A PR is green only when all three jobs pass.

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

- **Swift unit tests.** There is no XCTest target; the app is a thin AppKit
  layer over the file protocol, and the logic worth testing (state mapping,
  pruning, identity of requests) lives in the hooks and is tested there. CI
  compiles the Swift on macOS, which catches everything a type checker can.
- **Visual behaviour** (island layout, menu rendering, sprite animation). Run
  the app; `Scripts/dev/render-preview.swift` screenshots the real island views
  for eyeballing.
- **The two watchers' file-format parsing** is tested only through the live-app
  suites, because their inputs are what the third-party apps write.
