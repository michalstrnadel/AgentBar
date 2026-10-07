# Aider — live status bridge

Aider has no hook API. It has one outward signal and one file it writes, and
`agentbar-aider` is a wrapper built on exactly those two, reporting through
`agentbar report` (status only — a report cannot create an approval).

| Aider signal | Row |
|---|---|
| the wrapper starts Aider | `idle`, or `thinking` with the task for a one-shot `--message` / `--message-file` run |
| a new line lands in the input history file (`--input-history-file`, default `.aider.input.history` in the git root) | `thinking`, with that line as the prompt |
| `--notifications-command` fires | `done` — "Waiting for you" |
| Aider exits | `end` (the row is deleted) |

`--notifications-command` is documented as running "when the LLM has finished
generating a response and is waiting for your input"
(https://aider.chat/docs/usage/notifications.html). Read from the 0.86 source
(`aider/io.py`, `ring_bell`): it runs through `sh -c`, only when `--notifications`
is also on, and only after the model has actually produced something — so the
first prompt after start fires nothing, which is why the row opens as `idle`.

## Use

```bash
ln -s "$PWD/Scripts/hooks/aider/agentbar-aider" ~/bin/agentbar-aider
agentbar-aider --model sonnet src/app.py     # any aider arguments
alias aider=agentbar-aider                   # optional
```

It needs the `agentbar` CLI: `$AGENTBAR_CLI`, else `agentbar` on `PATH`, else the
copy in the checkout the wrapper was linked from. With none of those it just
`exec`s Aider. `AGENTBAR_AIDER_BIN` names the Aider to run (default `aider`).

`--pid` is the wrapper's own pid: it lives exactly as long as Aider, so a row
whose `end` never came (the terminal was closed) is pruned when the wrapper dies.
Each run is its own row (`--session aider-<pid>`), so two Aiders in one
directory stay two rows.

## What it cannot see, honestly

- **Waiting on a yes/no is not told apart from a finished reply.** Aider rings
  the same bell before "Add file to the chat?" or "Run shell command?" as before
  its prompt, and the command is given no arguments, so both show as `done`.
- **Working is inferred from the history file**, polled once a second. An
  `input-history-file` set only in `.aider.conf.yml` is not read, and a reply
  shorter than the poll may go from `done` to `done` without `thinking` between.
- **The terminal bell is replaced.** Aider runs the notification command
  *instead of* ringing. A `--notifications-command` of your own passed after
  ours wins, and then the row never reaches `done`.
- No tool or file labels: Aider says nothing about its edits to anyone but the
  terminal.
