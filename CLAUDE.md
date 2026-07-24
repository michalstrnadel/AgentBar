# AgentBar — AI Instructions

Context for AI coding assistants working on this repository.

## Project
AgentBar is a native macOS menu bar app (Swift, AppKit, SPM) showing live status of
AI coding agents (Claude Code, Codex, Copilot, Antigravity). Node.js hook scripts in
`Scripts/hooks/` write per-session JSON to `~/.agentbar/state.d/`; the app watches
that folder. Design spec: `docs/specs/2026-07-23-agentbar-design.md`.

## Build & run
```bash
./Scripts/build.sh          # builds build/AgentBar.app
open "build/AgentBar.app"
```

## Rules
1. One file, one responsibility — keep the unit layout from the spec; don't grow a
   god-object controller.
2. Menu bar only: no dock icon, no heavy dependencies. The sole window is the
   small Settings panel (`SettingsWindow.swift`); everything else stays in the menu.
3. Hooks must never block the host agent: async, atomic writes, exit fast.
   Sole exception: `permission.js` blocks while the session is already waiting on
   the human, and must always time out silently to the normal terminal prompt.
4. Adding an agent: entry in `Agents.swift`, sprite in `Sources/AgentBar/Sprites/`,
   optional hook dir in `Scripts/hooks/<agent>/`. Nothing else should need touching.
5. Third-party marks stay listed in `THIRD_PARTY_NOTICES.md`.
