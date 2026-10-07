# goose — live status bridge

goose has lifecycle hooks, delivered as a plugin: a directory with `plugin.json`
and `hooks/hooks.json`, discovered under `~/.agents/plugins/<name>/` (or a
project's `.agents/plugins/`). This directory **is** that plugin. Each hook runs
`agentbar.js`, which reads the payload goose pipes on stdin and calls
`agentbar report` (status only — a report cannot create an approval).

| goose event | Row |
|---|---|
| `SessionStart` | `idle` |
| `UserPromptSubmit` | `thinking`, `message` as the prompt |
| `PreToolUse` | `tool`, labelled `shell: <command>`, `write: <path>`, … |
| `PostToolUse`, `PostToolUseFailure` | `thinking` |
| `Stop` | `done`, `last_assistant_message` as the recap |
| `SessionEnd` | `end` (the row is deleted) |

The row is `goose-<session_id>`. Tool events carry `working_dir`, which becomes
the row's directory; the others inherit goose's own working directory.

Docs: https://goose-docs.ai/docs/guides/context-engineering/hooks/ ·
example plugin: https://github.com/aaif-goose/goose/tree/main/examples/plugins/hello-hooks

## Use

```bash
mkdir -p ~/.agents/plugins
ln -s "$PWD/Scripts/hooks/goose" ~/.agents/plugins/agentbar
```

goose's discovery follows a symlinked directory. It needs `node` and the
`agentbar` CLI: `$AGENTBAR_CLI`, else `agentbar` on `PATH`, else the copy in this
checkout. Turn it off with `{ "disabledPlugins": ["agentbar"] }` in
`~/.config/goose/settings.json`.

## Why it never answers

`PreToolUse` is the one event goose reads a decision from, and an exit 0 with an
empty stdout is its "allow" — the same as no hook at all. The bridge prints
nothing on any event, ignores every failure and exits 0, and the hooks keep
goose's default `on_failure: "allow"`, so a crash or a timeout here is logged by
goose and the tool call goes ahead. Nothing in AgentBar can approve or refuse a
goose tool call through this plugin.

## The pid

goose starts each hook with `sh -c`, so the hook's parent can be that shell,
gone a moment later. The bridge walks up past any shell to the first process that
is not one — goose itself — and passes that as `--pid`, so the row goes when the
goose session's process does even if `SessionEnd` never fires.

Not checked against a live goose: it was built from the documentation and the
`crates/goose/src/hooks` source, not a running session.
