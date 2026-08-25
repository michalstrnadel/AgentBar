# agentbar-cloud

External poller that mirrors **cloud** coding-agent runs into the AgentBar menu
bar: Cursor cloud agents, Devin sessions, and Codex cloud tasks become protocol
rows in `~/.agentbar/state.d/` (`entrypoint: "cloud"`, a `url`, this poller's
pid). Clicking a row opens the run where it lives — cursor.com / app.devin.ai /
chatgpt.com. No changes to the app beyond the protocol's optional `url` field.

## Setup

```bash
./Scripts/cloud/install.sh        # writes a starter ~/.agentbar/cloud.json + launchd agent
./Scripts/cloud/install.sh uninstall
```

Config `~/.agentbar/cloud.json` (chmod 600 — it holds API keys):

```jsonc
{
  "pollSeconds": 30,
  "retentionMinutes": { "done": 60, "error": 240 }, // how long finished/failed rows linger
  "syntheticErrorRow": true,   // one clickable "<vendor>: auth failed" row on persistent failure
  "cursor": { "enabled": true, "apiKey": "…",  // cursor.com/dashboard -> API Keys
              "openIn": "app",                 // cursor:// run deep link; "web" = cursor.com/agents/<id>
              "apiVersion": "v1" },            // "v0" = legacy status-on-agent endpoint
  "devin":  { "enabled": true, "apiKey": "…",  // app.devin.ai Settings -> API Keys
              "openIn": "app",                 // focuses Devin Desktop (no per-session deep link
                                               // exists); "web" = app.devin.ai/sessions/<id>, thread-precise
              "recentHours": 48, "showSuspended": false },
  "codex":  { "enabled": true }                // rides `codex login`, no key needed
}
```

Keys may also come from `CURSOR_API_KEY` / `DEVIN_API_KEY` in the launchd
environment instead of the file.

## Behavior

- Poll every 30 s (codex 60 s — it shells out to `codex cloud list --json`).
- After each **successful** vendor poll the vendor's rows are reconciled to the
  fresh set; a vendor that keeps failing (~5 min) gets its rows replaced by one
  clickable error row. Vendors never affect each other's rows.
- Actively working runs always show; finished/failed runs age out per
  `retentionMinutes`; blocked/suspended ones per `recentHours`.
- Rows carry the poller's pid: stop the poller and the app prunes them.

## Dev

```bash
node Scripts/cloud/index.js --once   # single poll, then exit
node --test Scripts/cloud/test/      # pure-function tests, no network
```
