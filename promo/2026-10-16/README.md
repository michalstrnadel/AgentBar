# AgentBar — 16 October 2026: approvals

The film for what AgentBar is for: one approval queue for every agent. Three agents
ask, they line up in one island, Codex is allowed in a click, Claude is refused with
a note it then reads, and Copilot's request meets a rule that only watches. Two short
clips cover approvals on the phone and rules that watch before they answer.

Every island, the Rules page and the Phone page are the app's real views, drawn
offscreen with made-up sessions (`Scripts/dev/promo.swift --assets`). Two things are
set dressing, and only the words in them are AgentBar's:

- the terminal in the film's "reads your note" scene: the denial line is exactly what
  `Scripts/hooks/claude/permission.js` sends (`denyMessage`); the transcript around it
  is drawn;
- the phone in the phone clip: the notifications say what `PhoneRelay.body` and
  `PhoneRelay.verbs` produce for those requests (a readable `git push` gets Allow and
  Deny; an edit gets Deny only); the phone and lock screen are drawn.

## Files

`video/` and `stills/` are not in git (`promo/.gitignore`); the commands below make them again.

- `video/agentbar-approvals-wide.mp4`: 1920×1080, 36 s. YouTube, the website, LinkedIn.
- `video/agentbar-approvals-square.mp4`: 1080×1080, 36 s. X, Bluesky, Mastodon, LinkedIn feed.
- `video/agentbar-approvals-story.mp4`: 1080×1920, 36 s. Threads, Reels, Shorts, stories.
- `video/agentbar-phone-square.mp4`, `video/agentbar-phone-story.mp4`: 14 s. Approvals on the phone.
- `video/agentbar-watching-rule-square.mp4`, `video/agentbar-watching-rule-story.mp4`: 14 s. A rule in watching mode.
- `stills/*-poster.png`: one poster frame per file above.

Which clip goes where:

- X, Bluesky, Mastodon: the square film; the square clips as replies or later posts.
- LinkedIn: the square film (or wide).
- Threads: the story film; the story clips as later posts.

## Regenerate

The films live in the product-videos studio (`feat/agentbar-approvals`). From there:

```bash
sh scripts/agentbar-assets.sh            # the app's views → public/agentbar (approvals → public/agentbar/approvals)
node scripts/music.ts src/projects/agentbar/approvals.music.ts public/agentbar/approvals.wav
node scripts/music.ts src/projects/agentbar/approvals-phone.music.ts public/agentbar/approvals-phone.wav
node scripts/music.ts src/projects/agentbar/approvals-watch.music.ts public/agentbar/approvals-watch.wav
sh scripts/render.sh agentbar-approvals 17.5   # out/agentbar-approvals-{wide,square,story}.mp4 + posters
for id in agentbar-phone agentbar-watching-rule; do
  for shape in square story; do npx remotion render "$id-$shape" "out/$id-$shape.mp4"; done
done
```

Only the approvals pictures, without rebuilding the games (from this repo's root):

```bash
D=$(mktemp -d)
swiftc -O -parse-as-library -target arm64-apple-macos12.0 \
  $(find Sources/AgentBar -name "*.swift" ! -name "main.swift") Scripts/dev/promo.swift -o "$D/promo"
AGENTBAR_HOME="$D/home" "$D/promo" "$D/assets" --assets --approvals
```

That writes `approvals-*.png` (the islands, the note field at every length of the
note, the Rules and Phone pages) and `approvals-marks.json` (where each button is, in
points). The film reads those marks from `approvals.parts.tsx`; if a view's layout
changes, copy the new numbers there.

## Post drafts

Drafts in your voice. Short, plain, first person; edit freely. Each link carries its
network: `?utm_source=<network>&utm_medium=social&utm_campaign=2026-10-approvals`.

**X** (square film)

> I run Codex, Claude Code and Copilot side by side, and they all stop to ask before
> running things. AgentBar puts every one of those questions in one queue under the
> notch: allow, deny, or deny with a note the agent reads.
> Free, open source, macOS.
> https://michalstrnadel.com/agentbar?utm_source=x&utm_medium=social&utm_campaign=2026-10-approvals

**Bluesky** (square film)

> Three agents asking for permission at once used to mean three terminals. Now it's
> one queue at the top of my screen. Allow, deny, or deny with a note that tells the
> agent what to do instead. Free and open source for macOS.
> https://michalstrnadel.com/agentbar?utm_source=bluesky&utm_medium=social&utm_campaign=2026-10-approvals

**LinkedIn** (square or wide film)

> I built AgentBar because my coding agents kept waiting on me in terminals I wasn't
> looking at.
>
> It's one approval queue for all of them, under the notch on a Mac:
> • Allow in one click, with the exact command in front of you.
> • Deny with a note. The agent gets your words and changes course.
> • Rules you write start in watching mode. They record what they would have done and
>   answer nothing until you let them.
> • Optionally, requests reach your phone while you're away. Allow only comes with a
>   command short enough to read whole.
>
> Free and open source for macOS.
> https://michalstrnadel.com/agentbar?utm_source=linkedin&utm_medium=social&utm_campaign=2026-10-approvals

**Threads** (story film)

> My agents ask a lot of questions. AgentBar puts them all in one place: allow, deny,
> or deny with a note the agent actually reads. Free for macOS.
> https://michalstrnadel.com/agentbar?utm_source=threads&utm_medium=social&utm_campaign=2026-10-approvals

**Mastodon** (square film)

> AgentBar is a small macOS app I make: one approval queue for coding agents (Claude
> Code, Codex, Copilot). Allow, deny, or deny with a note. Rules start out only
> watching, so you can check what they would have done before they answer anything.
> Open source.
> https://michalstrnadel.com/agentbar?utm_source=mastodon&utm_medium=social&utm_campaign=2026-10-approvals
>
> #macOS #OpenSource

**Follow-ups for the clips** (any network; swap the `utm_source`)

> Phone clip: Away from the Mac, an agent's request can reach my phone. It's off until
> I switch it on, it only goes out while I'm away, and Allow only shows up when the
> whole command fits on the screen. Anything else gets Deny, or waits for the Mac.

> Watching-rule clip: A rule I write in AgentBar doesn't answer anything at first. It
> watches, writes down what it would have done, and shows whether I did the same. It
> answers only after I tell it to.
