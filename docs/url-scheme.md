# `agentbar://` — driving AgentBar from Shortcuts, Raycast and scripts

AgentBar registers the `agentbar` URL scheme, so anything that can open a URL can
bring a window or the waiting session forward: Shortcuts.app, Raycast, Alfred, a
Stream Deck button, or `open` in a terminal. It is the macOS app only — the Linux
CLI has no counterpart, and nothing here is part of the file protocol in
`docs/protocol.md`.

The parser is `Sources/AgentBar/URLCommands.swift`; its tests are
`Tests/AgentBarTests/URLCommandsTests.swift`.

## What a link can never do

**Any web page can open an `agentbar://` link.** A browser asks once before it hands
a scheme to an app, people tick "always allow", and from then on a page can fire
links at AgentBar as often as it likes. So the scheme is limited to what such a page
may be allowed to do:

- It **shows** things — the session that is waiting, the launcher, a Settings page,
  the welcome window — every one of which the person could have clicked to, and
  every one of which then waits for the person.
- It **never** approves, denies, answers a question, writes or edits a rule, changes
  a setting, or runs a command. There is no link for any of that, and there will not
  be one: rule 3 in `CLAUDE.md` (AgentBar answers nothing by itself) would mean
  little if a link could answer on your behalf.
- `new-task` stops **two keypresses short**. It opens the launcher filled in, the
  hint line says *From a link — read it, then ⏎ twice*, and the first Return only
  confirms you have seen it (and does nothing at all in the first second, when it is
  more likely a Return that was already on its way). A page that opened the link can
  also say "press Enter to continue"; one Return is not enough to run its prompt.
  Editing the prompt makes it yours, and then one Return starts it as usual. A link
  arriving while you are typing in the launcher never replaces what you typed.
- A link AgentBar does not recognise exactly — an unknown command, a stray path, a
  user or port in the URL, a key given twice, a `cwd` that is not an absolute
  existing directory, a prompt over 2,000 characters — **does nothing**. No alert and
  no beep (those would let a web page make your Mac beep); one line in Console.app
  naming the scheme and nothing else, since a query can carry somebody's prompt.

## The commands

| Link | Does |
|---|---|
| `agentbar://focus` | Jumps to the session that most needs you: one waiting on a permission, else one asking a question, else the working session that moved last. Nothing waiting, nothing happens. |
| `agentbar://focus?session=<id>` | Jumps to that session (the id is its file name in `~/.agentbar/state.d/`, without `.json`). An id that is not on screen does nothing. |
| `agentbar://new-task?cwd=<path>&agent=<id>&prompt=<text>` | Opens the launcher with that project, agent and prompt chosen. Every parameter is optional. Return twice to start (once if you edit the prompt). |
| `agentbar://settings` | Opens Settings. |
| `agentbar://settings/<page>` | Opens Settings on a page: `general`, `keep-awake`, `awake-triggers`, `agents`, `notifications`, `shortcuts`, `usage`, `approvals`, `rules`, `claude-code`, `diagnostics`, `whats-new`. |
| `agentbar://day`, `agentbar://week` | Opens Your Day — the recap of today, or the last seven days. Nothing is exported or shared. |
| `agentbar://appearance` (or `agentbar://welcome`) | Opens the Appearance window — the one a new install greets you with. |

Details that matter:

- **Focus only ever picks a session on this Mac.** A cloud or ssh-mirrored row
  would open the `url` its writer chose, so a link skips them, even when one is the
  only session waiting.
- **Focus brings the session's terminal forward and changes nothing else.** A row
  click on a waiting session also hands the prompt back to its terminal; a link does
  not, because any page can open one and a link must not move a pending decision.
  The card stays on the island, answerable where it was.
- **`cwd`** must be absolute, must exist, must be a directory, and must be spelled
  plainly: no `~`, no `.` or `..` component, no doubled slash, no control
  characters. A trailing slash is dropped. A directory that is not among your recent
  projects joins them at the front of the launcher, selected, so what will run is on
  screen.
- **`agent`** is an id from the agent table (`claude`, `codex`, `gemini`, `qwen`,
  `copilot`, `opencode`, …). One that is not installed on this Mac is ignored and
  the launcher's usual first agent stays chosen.
- **`prompt`** is percent-encoded text, up to 2,000 characters. Newlines and tabs
  become spaces (the field is one line, and a newline would hide what follows);
  invisible formatting characters such as right-to-left overrides are removed,
  because they make text read as something other than what it says. The content
  itself is never judged or evaluated — it reaches the agent only as one quoted
  argument, the same way a typed prompt does.
- A link that launches AgentBar is held until the first read of `state.d`, so
  `agentbar://focus` from a cold start still finds the waiting session.

## From a terminal

```bash
open "agentbar://focus"
open "agentbar://settings/rules"
open "agentbar://new-task?cwd=$HOME/Projects/app&agent=claude&prompt=fix%20the%20flaky%20test"
```

Percent-encode the prompt yourself — `python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "your text"`
does it.

## Shortcuts.app

1. New shortcut, add the **Open URLs** action.
2. Put `agentbar://focus` in it.
3. In the shortcut's details, **Add Keyboard Shortcut** or pin it to the menu bar.

For a task launcher, put an **Ask for Input** (text) action first, then a **URL
Encode** action on its result, then **Text** with
`agentbar://new-task?cwd=/Users/you/Projects/app&agent=claude&prompt=` followed by
the encoded result, and **Open URLs** on that. AgentBar shows the launcher with the
prompt in it; press Return twice to start.

## Raycast

A script command is a shell script with a few comment headers. Save this as
`agentbar-focus.sh` in your Raycast script-commands directory and `chmod +x` it:

```bash
#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Jump to the waiting agent
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName AgentBar
# @raycast.description Brings forward the session that most needs you.

open "agentbar://focus"
```

The same shape works for any other link; with `@raycast.argument1 { "type": "text",
"placeholder": "prompt" }` the typed text arrives as `$1`, ready to encode into a
`new-task` link.

## Alfred

A workflow with a keyword input connected to an **Open URL** action set to
`agentbar://focus` (or `agentbar://new-task?prompt={query}` — Alfred encodes
`{query}` for you when *Encode query* is ticked).
