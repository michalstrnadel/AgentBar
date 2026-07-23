# Archived mascot concepts (2026-07-23)

Original animated mascot concepts designed for the non-Claude agents before the
menu bar art switched to animations based on each tool's real visual identity
(OpenAI knot + Codex CLI dot-matrix, official Copilot pixel head, official
Antigravity pixel arch).

Kept here on purpose — especially the paper plane, which may return as an
alternate Copilot look.

| File | Concept | Status |
|---|---|---|
| `copilot-paper-plane.gif` | Copilot as a purple paper plane in a wave glide with a fading trail (`-menubar.gif` = actual menu bar size) | **Reserve** — liked, kept as a ready alternative |
| `codex-terminal-robot.gif` | Codex as a walking terminal robot with a blinking cursor | Superseded by knot + braille dot-matrix |
| `antigravity-astronaut.gif` | Antigravity as a weightless astronaut with twinkling stars | Superseded by the official pixel arch |

## Regenerating

`generator.swift` is the self-contained renderer that produced all three
(frames, preview GIFs, System-mode simulations):

```bash
swift generator.swift <outDir>
```

Frame sets land in `<outDir>/frames/<agent>/` as transparent PNGs sized for the
app's sprite pipeline (`Agent.Artwork.frames` + `IconRenderer.adaptiveTemplate`).
To ship one of these, base64 the frames into a `Sources/AgentBar/Sprites/*.swift`
array and point the agent's `artwork` at it — same as the crab.

All three designs are original AgentBar artwork (MIT, like the rest of the
repo); they reference the tools only by brand color, so no third-party
trademark notices are needed for them.
