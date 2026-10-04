# AgentBar mod for Claude Code

A Claude Code mod (2.1.287 or later) that lets AgentBar see what the hooks cannot:
the calls Claude Code allowed or refused **without asking you**, and the figures it
measures itself. Contract: [`docs/protocol.md`, "mods.d"](../../../docs/protocol.md#modsd--what-claude-code-decided-without-asking-and-what-it-measures).

## What it does

- Writes one file per session, `~/.agentbar/mods.d/<session_id>.json` (or under
  `$AGENTBAR_HOME`), at most once a second, and a last time with `"ended": true`
  when the session ends:
  - `context` and `rate_limits`: Claude Code's own figures, a missing one left out,
    never zeroed;
  - `subagents`: how many subagents are running;
  - `decisions`: the newest 200 verdicts reached without a prompt (`allow` or
    `deny`), each naming who decided: a settings `rule`, the permission `mode`, or
    a `hook`. Read-only tools are left out, and only `command`, `file_path`, `url`
    and `description` are kept from a call's input.
- Optionally (off unless `~/.agentbar/mods/config.json` says `{"band": true}`)
  draws one line above the prompt when *another* session waits on you, with a Jump
  button that opens `agentbar://focus?session=<id>`.

## What it never does

- Answer anything. Every hook returns exactly what Claude Code (and every hook
  beneath it) returned; a failure in the mod's own bookkeeping is caught and
  changes nothing. It never writes `answers.d/`, never approves, denies or asks.
- Reach the network, read your environment beyond `HOME` and `AGENTBAR_HOME`, or
  run any command but `/usr/bin/open agentbar://focus?…`, and that one only when you
  press Jump.

## What it can do, as Claude Code reads it

`claude plugin validate --json --strict Scripts/mods/claude` lists it:

```
./register.js hooks: session.start, session.measure, tool.check, tool.call, agent.spawn, turn.complete, session.end, ui.render{component=AbovePrompt}
./register.js calls: $.clock.after (via schedule), $.clock.every (via onStart, refreshBand), $.clock.now (via onCall, onCheck, pollWaiting, writeFile), $.env.get (via resolveRoot), $.fs.exists (via onStart), $.fs.list (via pollWaiting), $.fs.read (via pollWaiting, readConfig), $.fs.write (via writeFile), $.process.run (via jump), $.session.cwd (via ensureSession, onStart), $.session.id (via ensureSession, onStart), $.session.usage (via onStart), $.ui.invalidate (via setWaiting), $.ui.resolve (via drawBand)
./register.js env writes: nothing
./register.js env reads: AGENTBAR_HOME, HOME
```

`Scripts/test/mod-test.sh` holds those lists to an allow-list, so an edit that
gains a capability fails CI rather than slipping through review.

## Trying it

```bash
claude --plugin-dir Scripts/mods/claude      # this session only
bash Scripts/test/mod-test.sh                # validate, allow-list, tests
AGENTBAR_LIVE_TESTS=1 bash Scripts/test/mod-test.sh   # plus one real turn (about a cent)
```
