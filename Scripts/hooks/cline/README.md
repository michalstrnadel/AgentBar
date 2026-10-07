# Cline — live status bridge

Cline runs executable files named after hook events — `TaskStart`,
`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `TaskComplete`, … — with a JSON
payload on stdin. The VS Code extension reads them from `~/Documents/Cline/Hooks/`
(and a workspace's `.clinerules/hooks/`); the Cline CLI reads the same folder
plus `~/.cline/hooks/`. `agentbar.js` is one script for all of them: it takes the
hook's name from the payload and calls `agentbar report` (status only — a report
cannot create an approval).

| Hook (extension / CLI) | Row |
|---|---|
| `TaskStart`, `TaskResume` / `agent_start`, `agent_resume` | `thinking`, the task as the prompt |
| `UserPromptSubmit` / `prompt_submit` | `thinking`, the prompt |
| `PreToolUse` / `tool_call` | `tool`, labelled `execute_command: <command>`, `read_file: <path>`, … |
| `PostToolUse` / `tool_result` | `thinking` |
| `TaskComplete` / `agent_end` | `done` |
| `TaskCancel` / `agent_abort` | `idle`, "Cancelled" |
| `TaskError` / `agent_error` | `error` |
| `Notification` with `waitingForUserInput` (older extension builds) | `question` |
| `SessionShutdown` / `session_shutdown` (CLI) | `end` (the row is deleted) |

The two dialects are both read from Cline's source: the extension serialises
`HookInput` from `apps/vscode/proto/cline/hooks.proto` (`taskId`,
`workspaceRoots`, `preToolUse.toolName`, …); the CLI's SDK adds `tool_call`,
`turn` and its own event names (`sdk/packages/core/src/hooks/subprocess.ts`). The
row is `cline-<taskId>`, its directory the first workspace root.

Docs: https://docs.cline.bot/customization/hooks ·
https://github.com/cline/cline/tree/main/sdk/examples/hooks

## Use

Hooks are on by default ("Enable Hooks" in Cline's feature settings). On Unix a
hook must be an extensionless executable named exactly after the event, and the
CLI skips symlinks — so each one is a two-line file pointing here:

```bash
d=~/Documents/Cline/Hooks; mkdir -p "$d"
for h in TaskStart TaskResume UserPromptSubmit PreToolUse PostToolUse \
         TaskComplete TaskCancel TaskError Notification SessionShutdown; do
  [ -e "$d/$h" ] && { echo "skipped $h: you have one already"; continue; }
  printf '#!/bin/sh\nexec "%s" "%s"\n' "$(command -v node)" "$PWD/Scripts/hooks/cline/agentbar.js" > "$d/$h"
  chmod +x "$d/$h"
done
```

The absolute `node` path matters: VS Code started from the Dock does not have
your shell's `PATH`. The script needs the `agentbar` CLI: `$AGENTBAR_CLI`, else
`agentbar` on `PATH`, else the copy in this checkout. A folder holds one file per
event, so where you already have a `PreToolUse` of your own, the loop leaves it
and that event goes unreported.

## Why it never answers

`PreToolUse` waits for stdout, and `{"cancel": true}` there stops the tool. The
bridge writes `{"cancel":false}` — the documented "carry on" — before it does
anything else, never anything after it, and exits 0 on every path. A crash
without that line is still an allow: the extension treats a hook with no JSON as
no cancellation, and the CLI drops a hook that produced invalid control JSON.

## The pid, and what stays behind

The extension starts a hook with `sh -c <path>`. The bridge walks past any shell
to the first process that is not one — the VS Code extension host, or the `cline`
CLI — and passes that as `--pid`.

The extension wires no end-of-session hook (`SessionShutdown` is CLI-only), so a
finished task stays as a `done` row until VS Code's extension host exits. Not
checked against a live Cline: built from the source above, not a running session.
