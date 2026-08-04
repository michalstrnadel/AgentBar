# AgentBar — AI Instructions

Context for AI coding assistants working on this repository.

## Project
AgentBar is a native macOS status app (Swift, AppKit, SPM) showing live status of
AI coding agents (Claude Code, Codex, Cursor, Gemini, Copilot, Antigravity). Node.js hook scripts in
`Scripts/hooks/` write per-session JSON to `~/.agentbar/state.d/`; the app watches
that folder. It presents itself as a menu bar item, a Dynamic Island panel under the
notch, or both — the user picks in the welcome window. State file protocol (normative):
`docs/protocol.md`; original design spec (a 1.0.0 snapshot, read its header note):
`docs/specs/2026-07-23-agentbar-design.md`; presentation modes:
`docs/plans/2026-07-28-presentation-modes-and-island.md`.

## Build & run
```bash
./Scripts/build.sh          # builds build/AgentBar.app
open "build/AgentBar.app"
```

## Rules
1. One file, one responsibility — keep the unit layout from the spec; don't grow a
   god-object controller.
2. Stay out of the way: no dock icon, no heavy dependencies, nothing that unfolds
   over the screen on its own. Two surfaces only — the menu bar item
   (`StatusItemController`) and the island (`IslandController`) — both fed from the
   same stores through `MascotDriver` / `AgentActions`; never render one from the
   other's code. Windows are the exception, not the pattern: only `WelcomeWindow`
   and `SettingsWindow`, both small, both opened by the user.
3. Hooks must never block the host agent: async, atomic writes, exit fast.
   Sole exception: `permission.js` blocks while the session is already waiting on
   the human, and must always time out silently to the normal terminal prompt.
4. Adding an agent: entry in `Agents.swift`, sprite in `Sources/AgentBar/Sprites/`,
   optional hook dir in `Scripts/hooks/<agent>/` plus its installer step in
   `HookInstaller.swift`, and the agent id in the `docs/protocol.md` list and the
   README agent table. Nothing else should need touching.
5. Third-party marks stay listed in `THIRD_PARTY_NOTICES.md`.
