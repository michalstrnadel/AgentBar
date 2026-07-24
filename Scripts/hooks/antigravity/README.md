# Google Antigravity — live status bridge

Antigravity 2.0 (I/O 2026) added lifecycle hooks to both the desktop app and the
`agy` CLI: `PreInvocation`, `PreToolUse`, `PostToolUse`, `PostInvocation`, `Stop`,
configured via `hooks.json` in `~/.gemini/antigravity/` (desktop) and
`~/.gemini/antigravity-cli/` (CLI). `antigravity.js` is the observe-only bridge;
HookInstaller registers it under a top-level `"agentbar"` rule group in both files.
There is no SessionStart/SessionEnd — sessions appear on first activity and are
pruned by pid/staleness. Docs: https://antigravity.google/docs/hooks
