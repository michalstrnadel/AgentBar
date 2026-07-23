# Mascot frame generators

Self-contained Swift scripts that render the animated menu bar mascots as
transparent PNG frame sets (plus preview GIFs and System-mode simulations).

```bash
swift generate-codex-antigravity.swift <outDir> ../../Sources/AgentBar/Sprites/LogoAssets.swift
swift generate-copilot.swift    # writes to ./final
```

Frames land in `<outDir>/frames/<agent>/f*.png`. To ship them, base64 each
frame into the matching `Sources/AgentBar/Sprites/*Frames.swift` array (the
files' headers say which). The Copilot head and Antigravity arch grids were
traced pixel-by-pixel from the official artwork — see THIRD_PARTY_NOTICES.md.
The earlier original-character concepts live in
`docs/archive/2026-07-23-mascot-concepts/`.
