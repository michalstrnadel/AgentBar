# Contributing to AgentBar

Thanks for your interest! AgentBar is intentionally small — please keep it that way.

## Ground rules

1. **One file, one responsibility.** Keep the unit layout from
   `docs/specs/2026-07-23-agentbar-design.md`; don't grow a god-object controller.
2. **Menu bar only.** No windows, no dock icon, no heavy dependencies.
3. **Hooks must never block the host agent** — async, atomic writes, exit fast.
   Sole exception: `permission.js` (see the comment at its top).
4. **Adding an agent** = one entry in `Agents.swift`, a sprite in
   `Sources/AgentBar/Sprites/`, and optionally a hook dir in `Scripts/hooks/<agent>/`.
   Nothing else should need touching.
5. Third-party marks belong in `THIRD_PARTY_NOTICES.md`.

## Developing

```bash
./Scripts/build.sh                        # builds build/AgentBar.app
open build/AgentBar.app
./Scripts/test/permission-hook-test.sh    # hook protocol tests (20 checks)
```

`swift build` works for quick compile checks and SourceKit-LSP; the shippable app
(bundle, Info.plist, hooks) comes from `./Scripts/build.sh`.

The whole app ↔ hook protocol is files in `~/.agentbar/` (`state.d/`, `requests.d/`,
`answers.d/`) — you can drive any app feature by writing JSON files there, no agent
needed. See `docs/specs/` for the design documents.

## Pull requests

- Conventional Commits (`feat:`, `fix:`, `docs:`, …).
- Add or extend a test when you touch the hook protocol.
- Update `CHANGELOG.md` for user-visible changes.
- CI must be green (build + hook tests).

## Releases

Bump `VERSION` in `Scripts/build.sh`, add a `CHANGELOG.md` section, tag `vX.Y.Z`,
and create a GitHub release with the changelog section as notes.
