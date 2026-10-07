# Demo assets

Everything in `docs/assets/` that moves is generated here, so it can be made again
after the UI changes instead of being re-recorded by hand. Run all of them from the
repo root. None of them launches the app, touches `~/.agentbar`, or needs a screen
recording permission.

| Output | Generator | How it draws |
|---|---|---|
| `agentbar-tour.gif` / `.mp4` / `.jpg`, `deny-with-note.gif`, `rules-try-it.gif`, `hand-a-file.gif` | `feature-gifs.swift` via `make-gifs.sh` | **the app's own views**, compiled in |
| `demo-claude-codex.gif` | `demo-gif.swift` | hand-drawn stage, mascot frames from the sprite sources |
| `demo-island.gif` | `demo-island-gif.swift` | hand-drawn stage and island |
| `social-preview.png` | `social-preview.swift` | the banner, from the 1024 icon master and the Your Day card (`--render-wrap … --demo`) |

## Feature GIFs: the generator to reach for

```bash
Scripts/demo/make-gifs.sh              # writes into docs/assets
Scripts/demo/make-gifs.sh /tmp/gifs    # or anywhere else, to look first
Scripts/demo/make-gifs.sh /tmp/gifs hand-a-file   # one scene only, by its output name
```

`make-gifs.sh` compiles `feature-gifs.swift` together with every file in
`Sources/AgentBar` (except `main.swift`) and runs it. That is the point of it: the
island card, the note composer, the rule sheet are the **real** classes, fed fake
sessions and requests through the real decoders. A GIF made this way cannot drift
from the app — change the card and the next run shows the change — and it never
shows something the app does not draw. The older hand-drawn generators can.

What is staged around the real views is shared in `enum Stage`: the wallpaper, a
menu bar with a notch, the island's flush-top shape, a pointer, a caption, and
`snapshot(_:)`, which renders any `NSView` at 2x into an image of its exact pixel
size. Frames are drawn on a 1:1 pixel canvas (`Stage.frame`), so a 460 pt island
panel is 920 px wide on a 1200 px frame, the same scale the other demos use.

### Adding a GIF

1. Add an `enum` beside `Tour`, `DenyWithNote` and `RulesTryIt` with a
   `static func write(to url: URL)`.
2. Build its fixtures the way those two do: `Stage.tmp(name, json)` writes a state or
   request file, and `Session(fileURL:)` / `ApprovalRequest(fileURL:)` read it back.
   Use a `cwd` that does not exist (`/tmp/agentbar-demo-…`): the approval card looks
   up your real decision history by directory, and a real one would print
   *Allowed 3× here* into a marketing GIF.
3. Render the real view with `Stage.snapshot`, find where its buttons are with
   `Stage.button("Title", in: view)` so the pointer lands on them, and push one
   `Stage.frame { … }` per frame. Cache snapshots by state; re-rendering an unchanged
   view every frame is most of the run time.
4. Register it in `FeatureGIFs.main`'s `scenes`, then
   `Scripts/demo/make-gifs.sh /tmp/gifs <name>` renders just that one; look at a few
   frames before writing into `docs/assets`.

`hand-a-file.gif` (`HandAFile`) drives the row's real drop face by calling
`IslandRowView.draggingEntered` with a stand-in `NSDraggingInfo` and then
`report(.pasted)`; its pasted path is `DropToAgent.text(for:)`. The quiet chip is a
working session whose `ts` is 12½ minutes old, and the footer's amber
*out ~HH:MM* is the real `UsagePace` fit, fed forty minutes of samples into
`UsagePace.shared` (this process's, not the app's). The forecast is read against
the real clock, so the scene's menu bar shows the time it was rendered.

### Outputs and encoding

The tour is written three ways from one set of frames:

- `agentbar-tour.gif` — `Stage.writeGIF`, ImageIO, looping, 0.085 s a frame.
  Budget: about 2.2 MB. A full-frame cross-fade is the most expensive thing in
  it (every pixel changes for four frames), so cuts that keep the same subject
  in place, like the hello into the approval, are hard cuts.
- `agentbar-tour.mp4` — `Stage.writeMP4`, AVFoundation (`AVAssetWriter` with a
  pixel-buffer adaptor): H.264 High, ~320 kbit/s, BGRA in and 4:2:0 out, even
  dimensions, `moov` at the front for streaming. Frame `i` shows at `i × delay`
  and the last one is held for its own delay, so it runs exactly as long as the
  GIF. Keep it under ~1.5 MB; `ffprobe` should say `h264`, `yuv420p`, 1200×1000.
- `agentbar-tour.jpg` — the poster for the `<video>`: the island open on the
  approval with the pointer on its way to Allow.

The tour opens on Clawd's launch hello, the real `MascotEyes.waveFrames` on the
pill's resting mark, each of its frames held for `Greeting.frameLength`; its open
panel carries an `aider` row with `agent_name`, which the real row draws as a
generic agent with a monogram. Keep the whole loop under ~34 s.

Timing: 0.08–0.085 s a frame (about 12 fps) keeps a 15-second story under ~600 KB.
Hold the frame that carries the point — the verdict, the answer — for 2 seconds or
more; a viewer scrolling past needs it to still be there.

A view that reads real state beyond its arguments will show it. The known ones:
the approval card's decision history (keyed by `cwd`, see step 2), the rule sheet's
*In* menu, which lists directories from your history but only draws the one it was
given, and the Rules page, which lists your real `~/.agentbar/rules.json` — the tour
leaves it out for that reason.

The generator is an unbundled process, which has two consequences worth knowing:
its `UserDefaults` are **its own domain**, not AgentBar's, so the tour can switch
settings on for the picture without touching yours (and a value it wrote stays for
the next run — clear what you set, as `Tour` and `Poke.record` do); and anything that needs a bundle, such as the
notification center, raises. Keep the notification switches off in a scene, or the
Notifications page asks for its status and the run aborts.

Windows come from `renderForVerification`-style hooks in the app:
`SettingsWindow.renderPageForVerification(_:to:)` and `sidebarFrame(of:)`,
`WelcomeWindow.renderForVerification(mode:mark:word:wired:)` (draws a mode without
saving it), and `RuleSheet.renderForVerification`. A new window gets one of those
before it gets a scene.

## The hand-drawn ones

```bash
swift Scripts/demo/demo-gif.swift Sources/AgentBar/Sprites/CrabFrames.swift \
  Sources/AgentBar/Sprites/CodexFrames.swift docs/assets/app-icon.png docs/assets/demo-claude-codex.gif
swift Scripts/demo/demo-island-gif.swift Sources/AgentBar/Sprites/CrabFrames.swift \
  docs/assets/app-icon.png docs/assets/demo-island.gif
```

Each takes an optional last argument, a directory, into which it dumps a handful of
frames as PNGs for checking. They draw the UI themselves, so after a UI change they
are the ones that go stale; prefer `feature-gifs.swift` for anything new.
