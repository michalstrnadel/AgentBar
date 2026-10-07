# Amp — live status bridge

Amp has no shell hooks; it has plugins — JavaScript/TypeScript modules it loads
from `~/.config/amp/plugins/` (or a project's `.amp/plugins/`) and runs with Bun,
which subscribe to events with `amp.on(...)`. `agentbar.js` is such a plugin and
calls `agentbar report` for each event (status only — a report cannot create an
approval).

| Amp event | Row |
|---|---|
| `session.start` (a thread is opened or started) | `idle` |
| `agent.start` (a prompt is submitted) | `thinking`, the prompt |
| `tool.result` | `tool`, labelled with the tool that just finished (`… failed` on error) |
| `agent.end` | `done`; `error` on `status: "error"`; `idle` "Cancelled" on `"cancelled"` |

The row is `amp-<thread id>`, its directory what `amp.$\`pwd\`` answers — the
way Amp's own docs get the working directory.

Docs: https://ampcode.com/manual/plugin-api · https://ampcode.com/docs/customize/plugins

## Use

```bash
mkdir -p ~/.config/amp/plugins
ln -s "$PWD/Scripts/hooks/amp/agentbar.js" ~/.config/amp/plugins/agentbar.js
```

then `plugins: reload` from Amp's command palette, or start a new `amp`. It needs
the `agentbar` CLI: `$AGENTBAR_CLI`, else `agentbar` on `PATH`, else the copy in
this checkout (the plugin resolves its own symlink to find it).

## Why it never answers

Amp has exactly one event whose handler returns a decision — `tool.call`, which
can allow, reject, modify or synthesise a tool call — and this plugin does not
listen to it. With several plugins on one event, Amp leaves their order
undefined, so even an "allow" from a status bridge could stand next to another
plugin's refusal in ways nobody can predict. Leaving it alone costs one thing:
the tool label arrives when a tool *finishes*, not when it starts.

## What is not verified

Built from the documentation, not a running Amp:

- **The pid.** Amp says plugins are "long-lived processes" run by Bun, not whose
  child that process is. The plugin passes its parent's pid — unless the parent
  is a shell, in which case this process is the Amp the user started and its own
  pid is used. Either way the row should go when Amp does; a wrong guess leaves
  a row that lives as long as your shell.
- **No end event.** Amp has no thread-closed event, so a finished thread stays
  `done` until that pid exits.
- Amp's web client also runs plugins; rows from there would carry a pid on
  whatever machine ran it, and are not a case this bridge tries to serve.

Kiro was the other option in the issue. Its CLI hooks are moving between
formats (the v3 docs now point at standalone `.kiro/hooks/*.json` and their
stdin payload is not documented on that page), so it is left for a bridge that
can be checked against a running Kiro.
