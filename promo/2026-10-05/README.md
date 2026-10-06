# AgentBar — 5 October 2026 (1.38 → 1.41)

Everything here is drawn from the app's real views, offscreen, with made-up
sessions (`Scripts/dev/promo.swift`). The one exception is the terminal in the band
scene: its band line is the mod's own; the Claude Code transcript around it is set
dressing.

## Files

- `video/agentbar-today-square.mp4`: 1080×1080, 37 s. For X, LinkedIn and Instagram feed.
- `video/agentbar-today-wide.mp4`: 1920×1080. For YouTube, the website and LinkedIn.
- `video/agentbar-today-story.mp4`: 1080×1920. For stories, Reels and Shorts.
- `gifs/take-a-break.gif` (+ `.mp4`): the island game, played by its autopilot.
- `gifs/take-a-break-steps-aside.gif` (+ `.mp4`): play, then an agent asks, the game steps aside, and you go back to the break.
- `gifs/bug-hunt.gif` (+ `.mp4`): Bug Hunt played by its hunter — the beagle walks in, bugs fly, he fetches.

`stills/` and `video/` are not in git (about 145 MB); the commands below make them again.
The polished films and posters live in the separate product-videos studio.
- `stills/NN-…-square.png` and `stills/NN-…-wide.png`: one frame per scene, with its title.
- `stills/ui-*.png`: the bare UI on dark, for threads and the README.

Regenerate:

```bash
D=$(mktemp -d)
swiftc -O -parse-as-library -target arm64-apple-macos12.0 \
  $(find Sources/AgentBar -name "*.swift" ! -name "main.swift") Scripts/dev/promo.swift -o "$D/promo"
AGENTBAR_HOME="$D/home" "$D/promo" promo/2026-10-05
```

Other modes, same build: `--game` (the Space Bugs film alone), `--hunt` (the Bug Hunt GIF and MP4),
`--assets DIR` (bare transparent UI, game clips and Bug Hunt clips for the video studio).

Frames stream into ffmpeg; nothing is written to the temp folder.

## Post drafts

These are drafts in your voice. Keep them short and edit freely.

**X / Bluesky (EN)**

> AgentBar 1.41: when an agent needs you, my little island game steps aside.
> Today also: it now sees what Claude Code decides without asking (auto mode included),
> shows a command a mod is holding as a wait, and has release notes inside.
> Free, open source, macOS. github.com/michalstrnadel/AgentBar

**LinkedIn (EN)**

> Shipped four AgentBar releases today.
> • Claude Code mods support: see what Claude Code runs without asking you — by your rules,
>   its mode, a hook, or auto mode.
> • A command another mod holds for you (rm -r, a force push) now shows as "waiting on you".
> • Live Claude quota and context, straight from Claude Code.
> • Release notes inside the app.
> • And a tiny game in the island that pauses the moment an agent needs you.
> Open source: github.com/michalstrnadel/AgentBar

**Czech**

> Dnes čtyři releasy AgentBaru. Vidí, co Claude Code udělá bez ptaní (i v auto módu),
> zadržený příkaz ukáže jako čekání na tebe a release notes má přímo v aplikaci.
> A v islandu je malá hra, která ustoupí, jakmile tě agent potřebuje.
> Zdarma a open source: github.com/michalstrnadel/AgentBar
