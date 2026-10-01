# Google Antigravity — live status bridge

Antigravity 2.0 (I/O 2026) added lifecycle hooks to both the desktop app and the
`agy` CLI: `PreInvocation`, `PreToolUse`, `PostToolUse`, `PostInvocation`, `Stop`,
configured via `hooks.json` in `~/.gemini/antigravity/` (desktop) and
`~/.gemini/antigravity-cli/` (CLI). `antigravity.js` is the bridge; HookInstaller
registers it under a top-level `"agentbar"` rule group in both files. There is no
SessionStart/SessionEnd — sessions appear on first activity and are pruned by
pid/staleness. Docs: https://antigravity.google/docs/hooks

## PreToolUse is fail-closed, so this bridge always answers

`agy` treats **all three** of these as *deny* on `PreToolUse`: a non-zero exit, a
crash, and stdout that is not a valid decision — a bare `{}` included. The bridge
used to exit 0 with nothing on stdout, which is one parser change away from
blocking every tool call in the CLI.

So it writes `{"decision":"allow"}` before doing any of its own work, via
`fs.writeSync` rather than `console.log` (`process.exit` can truncate a buffered
async write), and an `uncaughtException` handler guarantees exit 0. A status
bridge must never be the reason a tool call was refused. Only `PreToolUse` gets a
decision — no other event takes one, and the desktop app ignores stdout entirely.

Evidence for the contract, all from integrations that got denied by it:
[cmux#5358](https://github.com/manaflow-ai/cmux/issues/5358) (`Tool call denied by
jsonhook__cmux_PreToolUse_0_0` on invalid stdout),
[cmux#4768](https://github.com/manaflow-ai/cmux/issues/4768) (non-zero exit
blocks), [claude-mem#4058](https://github.com/thedotmack/claude-mem/pull/4058)
(the agy 1.2.1 contract expects `{"decision":"allow"}`).

The full decision enum, read from the bundled engine's jsonschema tag
(`Antigravity.app/Contents/Resources/bin/language_server`), is wider than the docs
suggest: `allow | deny | ask | force_ask | deny_unless_prior_grant`.

What `allow` does *not* mean, checked 2026-10-01 on agy 1.2.14: with the bridge
answering `{"decision":"allow"}`, `agy -p "…touch probe.txt…"` still enforced its
own permission and refused the command — stderr: `a tool required the "command"
permission that headless mode cannot prompt for, so it was auto-denied`. A hook's
`allow` means "this hook does not object"; it does not bypass agy's permission
system. So the bridge answers nothing on the user's behalf — CLAUDE.md rule 3
holds.

## Remote approval: the CLI could, the desktop can't

Checked 2026-09-16. `agy` fires blocking `PreToolUse` and honours the decision, so
native Allow/Deny is buildable for CLI sessions. The desktop app does not appear
to fire `PreToolUse` at all: a [2026-08-06
repro](https://discuss.ai.google.dev/t/do-antigravity-ide-2-0-actually-execute-plugin-hooks-pretooluse-posttooluse-or-is-that-cli-only-right-now/176814)
(IDE 2.1.1, desktop 2.5.0, agy 1.1.10) found zero invocations across every
registration route, and the official changelog has desktop hook entries but none
about `PreToolUse` or decisions. Local sessions corroborate it — they ran normally
while our decision-less hook was registered, which fail-closed semantics would
have blocked.

Tracking issue: [#8](https://github.com/michalstrnadel/AgentBar/issues/8). Until
the desktop side moves, the keystroke path stays for desktop sessions.

## Install path drift, worth a periodic check

We install to `~/.gemini/antigravity{,-cli}/hooks.json`. The
[docs](https://antigravity.google/docs/hooks/) now name only
`~/.gemini/config/hooks.json` (global) and `.agents/hooks.json` (workspace). The
product-scoped path is still read — an agy 1.2.1 log shows `hooks_manager.go:53]
loaded 1 named hooks from 1 hooks.json file(s)` — but if Antigravity rows ever go
quiet after an upgrade, this is the first thing to check.
