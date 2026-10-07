# Changelog

All notable changes to AgentBar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## 1.47.0 - 2026-10-07

### Fixed

- **Your Day's agent time is the time agents were working, not the time their
  windows were open.** Three Claude Code windows open since morning added up to
  "52h of agent time" in one day. It now comes from two sources:
  - **Claude Code's own transcript**, where every prompt and every step is
    stamped. A turn runs from your prompt to its last step, and a silence of
    more than five minutes inside a turn is waiting, not work.
  - **What AgentBar saw**, for every other agent: the stretches a session spent
    in thinking or tool. These are now written to `history.jsonl` as `spans`.

  A session with neither is counted but gets no time. The peak, the bars and the
  longest run come from the same stretches.

### Added

- **You, through the day.** Under the agents' bars, a dot marks every hour you
  typed prompts or answered requests, bigger the more you did.
- **More on the card:** your prompts and when you sent the most, the longest
  run, and the busiest hour.

### Changed

- **The Your Day window's controls are two buttons.** **Copy** puts the card on
  the clipboard. **Share** holds Share…, Save Image, Save Square Image, Save
  Video, Save GIF and **Include Project Names** (still off by default). Today and
  This Week sit beside them. The recap loads off the main thread, because a
  week of transcripts can be megabytes.

## 1.46.0 - 2026-10-07

### Added

- **Allow all alike.** When the same request waits in several sessions — three
  agents asking for the same `npm test` in the same folder — the island card and
  the menu's inline strip offer **Allow all 3**.
  - "The same" is strict: the same tool, the whole same input byte for byte, and
    the same directory.
  - Only the requests on screen when you click are answered; one that arrives a
    moment later is not.
  - Each one is written to the approval history as your own answer.
  - Plans and questions never batch.
- **Try an approval.** The welcome window has a button that puts one made-up
  request where a real one would wait: at the notch, or in the menu bar. You
  answer it the way you would answer a real one, before any agent is wired. It is
  on screen only: nothing runs, no file is written, and it never reaches the
  history, the approval record, a notification or a rule. It goes away by itself
  after three minutes, as a real request times out.

## 1.45.1 - 2026-10-07

### Fixed

- **1.45.0's release could not be attested.** One check of the new Amp bridge
  failed on Linux CI, and 1.45.0 was published anyway, so its download has no
  provenance attestation. 1.45.1 is the same release from a green run and is
  attested. The bridge itself also changed: on Linux it now asks `/proc` which
  program its parent runs, because a shell running a script is named after the
  script there and was not recognised as a shell.

## 1.45.0 - 2026-10-07

### Added

- **Carry a session on in another agent.** When a session's quota is half an
  hour from running out, its island row says **out ~15:40 ↗**. Click it, or
  right-click any session row, or use **Continue … Elsewhere** under the menu's
  meter, and pick an agent. The launcher opens in the same project with that
  agent and a one-line prompt: your last prompt, the agent's last update, and
  "look at `git status` and `git diff` first". You read it, you press Return, and
  the first session is left exactly as it was.
- **Your week of decisions**, at the top of Settings ▸ Approvals: the five kinds
  of request that held your agents up longest over the last seven days, how often
  each was asked, how long they waited, and how you answered.
  - A watching rule says what it would have answered and about how much waiting
    that would have saved.
  - An answering rule says what it took itself.
  - A request you always answer the same way, with no rule yet, offers **Write a
    rule…**: the usual sheet, prefilled, starting in watching mode. Nothing is
    saved until you save it.
- **Status bridges for Aider, goose, Cline and Amp** (#17, #18, #19, #20), each in
  `Scripts/hooks/<agent>/` with a README naming the signal it uses:
  - **Aider:** a wrapper around `aider`, using its notifications command and its
    input history.
  - **goose:** a goose plugin on its hooks.
  - **Cline:** one hook script for both the VS Code extension and the CLI.
  - **Amp:** an Amp plugin.

  All four only report status through `agentbar report`. None of them answers,
  approves or blocks anything, and an agent without AgentBar is unaffected. Kiro
  is not covered: its hook payload is not documented well enough to build on
  honestly.

### Fixed

- **The island no longer floats over Mission Control.** It stayed drawn over the
  Spaces bar while the desktop zoomed out beneath it, still taking the hover and
  playing its expand over the shrunken screen. Mission Control now hides it, as it
  hides the menu bar.
- A Settings row with a wide button (**Open Rules**, **Export…**) no longer lets
  its caption run under the button.

## 1.44.3 - 2026-10-07

### Fixed

- **The welcome window no longer opens when an agent starts AgentBar.** With
  **Show this window on launch** ticked, every launch showed the window, including
  the ones nobody made by hand: a hook starting AgentBar for a session (Claude
  Code's after every `/compact` among them) and an update's relaunch. Those
  launches now say so (`--background`) and open no window. A first run still
  shows it however it started, and a launch you make shows it as you asked.
- **Hooks start the installed AgentBar, not whichever copy LaunchServices
  prefers.** By bundle ID alone it could pick an old dev build lying in a
  checkout, which started as a second instance and stopped the real one. The
  hooks now name `/Applications/AgentBar.app` (or `~/Applications`) when it is
  there.

## 1.44.2 - 2026-10-07

### Changed

- **Your Day, redrawn plainly.** 1.44.1's card had glowing blobs on a dark ground,
  a neon headline, a giant faint symbol and glass tiles: the look of every
  generated recap, not of something you would put your name to. The card is now
  paper and ink:
  - the date and the range in a header over a hairline;
  - agent time as the one big number, and who you were as a sentence under it;
  - the hours as bars in each agent's colour, with a legend, and the peak (or a
    week's best day) marked by a thin line and a few words;
  - the rest as a list, with the label on the left, the value on the right and a
    hairline between rows.

  Colour appears only where it carries something: on the bars, and on the lines
  added and removed. The window is light to match, and the GIF is about half the
  size again.

## 1.44.1 - 2026-10-07

### Changed

- **Your Day is one card now, not a story of nine slides.** A recap you open every
  evening is read, not watched, and at five seconds a slide the story took 45
  seconds to say what the card at its end said at a glance. The card carries it
  all:
  - who you were today as the headline, with the number that earned it;
  - agent time, counting up;
  - the day as bars in each hour's agent colour, with your peak of agents at
    once marked on them (a week marks its best day);
  - tiles for your top agent, what changed, your answers and where the work went.

  It builds once in about two seconds when it opens and then holds still. A click
  or Space builds it again. **Video** and **GIF** now save the card building
  itself: a 6-second MP4, or a looping GIF a quarter of the old size, dithered so
  the soft colours do not band. The slide player, its progress bar and its arrow
  keys are gone.
- A week's Orchestrator says which day its peak was on.
- The README shows it all moving: the card building itself, a file handed to a
  session with a quiet one beside it and the limit forecast in the footer, and a
  new social preview with the card.

## 1.44.0 - 2026-10-07

### Added

- **Your Day — your day with your agents, as a story.** **Your Day…** in the menu
  and the island's ⋯ plays the day (or, with **This week**, the last seven) the way a
  year-in-music recap does:
  - agent time, with the day as bars;
  - your top agent and its share;
  - where the work went, and the longest run;
  - what changed in your repos;
  - how long the agents waited on you, with every answer a dot on the day;
  - your peak of agents at once;
  - who you were today: The Orchestrator, The Marathoner, The Night Owl, The
    Delegator, The Quick Draw, and others.

  It ends on a card you can share. Copy it, save it as a story or square PNG, save
  the whole story as an MP4 or a GIF, or hand it to the share sheet. Project names
  and tasks stay out of every export unless you tick the box.

  The numbers follow AgentBar's usual rules: a partial figure says it is partial,
  and a slide with nothing behind it is left out. Your Day never opens by itself,
  and `agentbar://day` and `agentbar://week` open it on request.
- **Hand a file to an agent.** Drag files, an image or a screenshot thumbnail onto
  a session in the island, and their paths go into that agent's prompt.
  - AgentBar pastes them only into a tab it has verified (iTerm2, Terminal,
    WezTerm, tmux) and never presses Return. Anywhere else the paths are copied
    and the row says ⌘V.
  - **Your latest screenshot in the island** (Settings ▸ General, off by
    default) keeps a screenshot from the last three minutes in the open
    island's footer, so you can drag it straight onto a session.
- **Will it last?** When a quota window's recent pace runs it out before it
  resets, the meter says when: "out ~15:40" on the island, turning amber in the
  last half hour, and "At this pace: limit ~15:40 (+18 %/h)" in the menu.
- **Quiet sessions ask.** A working session with no word from its agent for ten
  minutes says **quiet 12m?** on its row. You can change the threshold to 20 or 30
  minutes, or turn it off, in Settings ▸ General.

From a full audit — security, engineering, UX and the paths that failed in silence:

### Security

- **A rule never answers without its row.** The ledger row naming the rule is now
  written first, and a rule whose row cannot be written (full disk, read-only
  `~/.agentbar`) gives no answer — the human decides (F22).
- **A command too long to have been read whole is refused.** The hook cuts a
  command at 2,000 characters, so a line padded past that could hide a second
  command after the cut (F21).
- **Git's program-running options are refused**: an option in front of the
  subcommand (`git -c …`, `--config-env`, `-C`) and `grep -O`, `--ext-diff`,
  `--textconv`, `--upload-pack` and friends.
- **Paths are checked with their links followed**, so a symbolic link inside the
  rule's directory that leads out of it is outside.
- **No rule speaks for a question.** A deny rule hid the question's card and wrote
  a "deny" row for something nothing denied.
- **Links and rows are narrower.** An `agentbar://new-task` prompt starting with
  `-` is refused (it would reach the agent's CLI as an option), and a typed one is
  kept a prompt; a cloud row opens only https, http, ssh and the vendors' own
  schemes.
- **Hooks look for this user's AgentBar only**, so another account's copy on a
  shared Mac cannot keep a hook waiting for nobody.
- `requests.d` and `answers.d` are private to you (0700), and **the install
  script verifies the download's signature** before installing it.

### Fixed

- **Copy, paste, select all, undo and ⌘W work** in every text field — the
  Launcher, the deny note, the token field. They did nothing before.
- **Re-install hooks and the Agents switch say when they did not work** (a
  settings file AgentBar will not rewrite, no node), instead of reporting success.
  A switch that could not wire its agent goes back off.
- **Off and Remove in Settings ▸ Rules** edit the file as it is now — a rule added
  by hand meanwhile is kept — and say so when the write fails.
- **A broken `rules.json` shows on the Diagnostics… row at once**, not after a
  relaunch, and Diagnostics names session rows it cannot read.
- **The welcome window greets a new install once.** It used to take focus on every
  launch, the update's silent relaunch included. From the menu it is the
  **Appearance** window; Esc closes it; with nothing to wire it says so instead of
  "Setting up hooks…" for ever.
- **New Task… is in the island's ⋯ menu**, and the Launcher says why when there is
  no agent to start, walks projects with ↑↓ and agents with ⇥.
- Approvals left waiting by **Antigravity or Cowork** are retired when the watcher
  stops reading their logs, instead of saying "approve?" all day.
- **A notification is posted again** when its request is replaced by a new one
  under the same file name.
- **The ledger and history keep their limits while the app runs**, not only at
  launch; a row appended during pruning is no longer lost, and a line pruning
  cannot read is kept rather than deleted. A corrupt settings-change record is set
  aside instead of overwritten.
- Hooks no longer write an `unknown` row for a payload without a session, and the
  stale-row sweep no longer deletes another hook's write in flight.
- A login shell that blocks, or a stale network mount, no longer stalls the node
  probe or the Antigravity lookup; the Cowork watcher reads its logs off the main
  thread.
- An update whose relaunch script fails is opened directly instead of being
  reported as a failed install.

### Changed

- **Island text is easier to read**: secondary lines are brighter, and brighter
  still with Increase Contrast.
- **Icon Color ▸ Colorful / Monochrome** (was Color ▸ Color / System); New Task…
  and Global Allow / Deny Shortcut… in title case.
- VoiceOver: Settings' sidebar pages and the island's session rows are buttons,
  approval buttons are read without their glyphs, and the finish hop respects
  Reduce Motion.
- A failed update check says what to do, and names a GitHub rate limit.

## 1.43.0 - 2026-10-06

### Changed

- **The two games have their own names.** The joystick's menu is headed **Take a
  break** and offers **Space Bugs…** (the shooter that was called Take a break)
  and **Bug Hunt…**.
- **Bug Hunt's dog, drawn again.** A proper beagle now: from the side as he walks
  in, with a long dark ear, a saddle on his back and his tail up; from the front
  with a white blaze when he holds up the catch, and a wide-open laugh when one
  gets away.

## 1.42.0 - 2026-10-06

### Added

- **Bug Hunt, a second game for your break.** The joystick beside ⋯ now offers two
  games (the last one you played first), and so does the ⋯ menu. Bug Hunt plays
  by the rules of the old light-gun hunt, drawn in AgentBar's own pixels (the
  dog is ours, a beagle in Clawd's orange collar):
  - The dog walks in, sniffs, and jumps into the grass; bugs rise out of it one at a time
    (**Game A**) or in pairs (**Game B**).
  - You get **three shots** per flight. A hit bug freezes, tumbles into the grass,
    and the dog pops up holding it.
  - Miss three times, or wait too long, and it **flies away**: the sky turns, and
    the dog laughs at you.
  - A round is ten bugs, and the hit bar along the bottom shows how many the round
    needs: six at first, then seven, eight, nine and ten. Go short and the game is
    over; hit all ten for a **perfect** bonus.
  - Each round is faster. The three kinds of bug are worth 500, 1000 and 1500,
    rising in later rounds.
  - Each game keeps its own best score on this Mac.
  - Aim with the pointer (a crosshair over the field) and click, or move a sight
    with the arrows and fire with Space. P pauses; Esc or Close stops.
  - It follows Take a break's rules to the letter: it opens only on your click,
    pauses when you click away, and steps aside the moment an agent needs you, with
    **Back to the break** to pick it up again.
  - Its sounds are its own and play only with Sounds on.

## 1.41.0 - 2026-10-05

### Added

- **Take a break.** The joystick beside ⋯ in the island's corner (or **Take a
  break…** in the ⋯ menu) opens
  into a small Galaxian-style game — Clawd as the ship, a formation of bugs in
  three colours swaying and diving at you, double points for a diver, a token now
  and then, three ships, faster waves, and a best score kept on this Mac. It is
  the island and nothing more: it opens only on that click, pauses the moment you
  click elsewhere, and **steps aside the instant an agent needs you** — the game
  pauses, the island shows the request, and **Back to the break** in the same menu
  picks up with the score intact (for fifteen minutes). Arrows or A/D to move, Space
  to fire, P to pause, Esc or Close to stop. Its blips play only with Sounds on;
  under Reduce Motion the stars hold still. Nothing of it runs when it is closed.
  While a game is put aside the joystick wears the accent colour.

### Fixed

- **An update waiting to be installed was hard to see.** Its menu row was drawn in
  accent blue on the translucent grey menu, which is nearly the same value; the row
  is now in the menu's own colour and semibold, with only its arrow in the accent.

## 1.40.0 - 2026-10-05

### Added

- **What auto mode runs instead of asking you is counted.** Settings ▸ Claude Code ▸
  Answered without you gains **Auto mode, instead of asking you**: a call Claude Code
  would have asked about, that ran with no prompt reaching you. The mod sees the ask
  and what came of it, and AgentBar's permission hook now leaves a note the moment a
  prompt is due (`mods.d/.prompted-<session>`), so an answer of yours — in AgentBar or
  in the terminal, app running or not — is never mistaken for auto mode. What auto
  mode refuses is still not counted, and the card says so: a refusal comes back
  looking like a command that failed.
- **A command another mod holds for you is a wait, not work.** blast-radius holds
  `rm -r`, hard resets and force pushes in its own pane until you answer, and nothing
  reported it: AgentBar showed the session as busy. A call that has not reached
  Claude Code's permission check three seconds after it began is now reported by the
  mod, and the session shows as **waiting on you — Held before it runs: rm -r build**,
  on the island and in the menu, with only "Open in terminal" on offer (there is
  nothing to approve from here). The band above another session's prompt says so too.

### Fixed

- **Switching the Claude Code mod on reached only `~/.claude`.** AgentBar, launched
  from Finder, never sees `CLAUDE_CONFIG_DIR`, so a Mac with one Claude config per
  account (`~/.claude-work`, `~/.claude-personal`) had the mod written where no
  session read it — and its hooks there were never refreshed either. Every
  `~/.claude-*` whose settings already name AgentBar now counts, in the app and the
  CLI; one nobody wired is left alone.

## 1.39.0 - 2026-10-05

### Added

- **Release notes, inside AgentBar.** **Settings ▸ What's New** shows what changed in
  every release that arrived since you last looked, marked **New**, with a few before
  them — and, while an update is on offer, what it brings before it installs, with the
  button to install it. A downloaded update's notes come from inside the verified
  bundle, so they cover every release since yours, not only the newest. After an
  update the menu (and the island's ⋯ menu) offers **What's New in …** for two weeks,
  and the page keeps a dot in the sidebar until you open it. Nothing opens by itself:
  an update installs at a quiet moment and stays quiet afterwards. The notes are this
  changelog, bundled with the app — readable offline, and the same text as the GitHub
  release. `agentbar://settings/whats-new` opens the page.

## 1.38.0 - 2026-10-05

Claude Code 2.1.287 runs **mods** — plugins whose code lives inside its process, sees
every tool call, and can approve one before anyone is asked. That is a new way for
something to answer on your behalf, and until now AgentBar could not see it. This
release is about making it visible, without AgentBar answering anything itself.

### Added

- **The AgentBar Claude Code mod** (`Scripts/mods/claude`), off until you switch it on
  in **Settings ▸ Agents ▸ Claude Code mod** (or `agentbar wire claude-mod` on Linux).
  Switching on adds one entry to `env.CLAUDE_CODE_PLUGIN_DIRS` in your Claude Code
  settings, beside any of your own — backed up and shown as a diff first, like every
  write AgentBar makes — and needs Claude Code 2.1.287 or later. The mod **observes
  only**: every hook hands Claude Code's own result back untouched, and CI pins what
  it may call (`claude plugin validate`) so it cannot quietly gain a capability
  (SECURITY.md ▸ The Claude Code mod). It writes one file per session to
  `~/.agentbar/mods.d/` (`docs/protocol.md` ▸ mods.d).
- **Settings ▸ Claude Code**, a page for what answers for you inside Claude Code:
  - **Answered without you** — what Claude Code ran or refused on its own, today and
    over seven days, by your Claude Code rule (`Bash(git status:*)` — 2 ran), by its
    permission mode, or by a hook or another mod, with the commands it ran most. It
    says what it cannot see: what auto mode's classifier or don't-ask mode settles
    after Claude Code would have asked happens after the mod looks.
  - **Claude Code plugins that can answer for you** — every enabled plugin or mod that
    can settle a prompt before AgentBar sees it, with what it can do ("Can hold or
    refuse Bash commands before they run"), read from `claude plugin validate`. Works
    without the mod. `agentbar doctor` lists them too.
  - **Show other agents waiting, above Claude Code's prompt** — an optional line the
    mod draws inside Claude Code while another session needs you, with a key that
    jumps to it. It never answers anything.
- **Claude's quota, live from Claude Code.** With the mod on, the five-hour and weekly
  windows come straight from Claude Code after every turn — no Keychain, no sign-in,
  no request of AgentBar's own — and the Claude meter uses them first, saying "from
  Claude Code, live". The last reading stays for half an hour after the session ends.
- **`ctx 82%`** on a Claude Code session's row, on the island and in the menu, once
  its context window passes 70 % (amber from 85 %, red from 95 %): the one context
  number worth a glance, because a full window is about to compact.
- Claude Code's own decisions land in your record as `via: "claude"` rows, one per
  tool call, with the rule or mode behind them; the export gains `by` and
  `claude rule` columns. They never count as you: not toward "Allowed N× here", the
  *Always* nudge, rule offers, rule agreement or the time agents waited, and they have
  a ceiling of their own so a busy day cannot push your answers out. `agentbar
  approvals` counts them on their own line. A rule of yours notes when Claude Code
  already allows the same command itself.
- `~/.agentbar/wire-enabled`, for integrations that start off (the mod is the first).

### Fixed

- **A Fix-it button no longer takes Settings ▸ Diagnostics down.** A row with a
  repair button pinned its width to the list before it was in the list; AppKit raises
  on that, and the rest of the report went with it.

## 1.37.0 - 2026-10-03

### Added

- **Clawd raises a hand when Claude waits on you** — with an amber **!** for a
  permission request and a blue **?** for a question, waving now and then. It takes
  the place of the badge dot, and the **!** and **?** keep their colour in System mode
  as the dot did.
- **Clawd falls asleep** after ten minutes with nothing working or waiting: eyes
  shut, a z and a Z. In the menu bar he is a still picture, since the mark there never
  moves at rest; in the island, with the mascot's personality on, he breathes and the
  z's drift up. That makes twelve scenes; the README and `docs/clawd-scenes.md` show
  them all.

### Fixed

- **In System mode on a light Mac, the island's mark vanished when it wore a dot** —
  an approval, a question or a failure. The mark is drawn in the bar's ink, which was
  resolved against the light system appearance: black on the black pill. The island
  now draws it as the island looks.

## 1.36.1 - 2026-10-03

### Fixed

- **A session's line counts no longer go missing when the Mac is busy.** The git
  runner behind them read the child's output on a shared worker queue, and with every
  worker blocked that read never started: a `git` that answered at once came back
  as a timeout eight seconds later, and the row showed no numbers. The reader now
  has a thread of its own. CI caught it as a flaky test.

## 1.36.0 - 2026-10-03

### Changed

- **Clawd shows what Claude is doing.** While a session works he no longer just
  walks: he reads a book when it reads, sweeps a magnifier when it searches, types on
  a laptop when it edits or writes, hammers on an anvil when it runs a command, sends
  waves from an antenna when it is on the web, works beside a little Clawd when it
  hands off to a subagent, squashes a box shut while it compacts, and turns to face
  you, thinking, at the start of a turn or when it has been quiet for a few seconds.
  A tool with no picture of its own keeps the walk. Each scene plays to its end before
  the next one starts, so a session hopping between thinking and tools several times
  a second does not flicker. In the menu bar and the island; his working mark is a
  few points wider so every scene fits one canvas and the words beside him stay put.
  The README shows all nine; `docs/clawd-scenes.md` explains how they are chosen and
  drawn, and `Scripts/mascots/render-clawd-scenes.swift` re-renders the GIFs from
  the app's own code.
- The Claude hook names Claude Code's `Agent` tool (the newer name of `Task`)
  *Delegating* instead of *Using tool*.

### Fixed

- The working animation no longer restarts at its first frame on every state
  update; during a run of tool calls it used to replay the same stride.

## 1.35.0 - 2026-10-02

### Added

- **Settings ▸ Agents.** The agent switches moved out of Diagnostics onto a page of
  their own, and each now says whether the agent is actually reporting — *Wired · last
  session today*, *Wired · no session yet*, *Off — your choice*, *Not on this Mac* — so
  a wired agent that never shows up is visible without running a check. Below them,
  **Your own agent**: any tool that reports itself with `agentbar report` is listed by
  the name it gave itself, and **Copy example** puts a five-line wrapper on the
  clipboard that shows any command as a session while it runs.
- **Send Feedback…** in both menus opens a new GitHub discussion with your AgentBar and
  macOS versions filled in, and nothing else. AgentBar itself sends nothing.
- **`AGENTBAR_HOME`.** Set to an absolute path, it moves the whole state directory
  (`~/.agentbar`) for the app, the hooks, the CLI and the cloud poller — for test
  sandboxes and a dev copy running next to the installed one. A copy running under it
  wires no agent and never installs an update by itself, and the CLI's `install-hooks`,
  `wire` and `unwire` refuse to run under it. `Scripts/dev/sandbox.sh` starts such a
  copy, with its own preferences, beside the installed app.

### Changed

- **Clawd has a little life in it from the first launch** — for a new install. Eyes
  that follow the pointer, a blink, the hello, a poke on the mark. Anyone who already
  had AgentBar keeps it off, because with it on a click on a row's mark pokes Clawd
  instead of jumping to the session; **Settings ▸ General ▸ Let the mascot react**
  switches it either way.
- **The island's ⋯ menu and the menu bar's menu are drawn from one list**, so neither
  can lose a row the other has — the way the island's update row did before 1.34.0. The
  island menu gains **Diagnostics…** with its failure count, so Island-only users see a
  broken hook too; the menu bar gains a plain **Settings…**; both end in **Quit AgentBar
  ⌘Q**, and **Diagnostics…** opens Settings on that page.

### Fixed

- **A rule no longer approves a second command hidden behind a carriage return.**
  `ls x\r\nreboot` under a rule for `bash:ls` was approved: Swift reads `\r\n` as one
  character, so the check for a line break never saw the `\n`. Lines are now searched
  byte by byte, and a lone `\r` refuses too. Also refused now: a command with a quote
  that never closes, and a request whose command starts with an invisible U+FEFF —
  the app's JSON reader drops that character, so the command it checked was not the
  one the shell would run. Each falls through to you, as everything the engine cannot
  read does (SECURITY.md, F18–F20).
- **`rules.json` means the same thing to the app and to `agentbar rules`.** A key
  written twice (`"decision":"deny", …, "decision":"allow"` was applied as deny and
  listed as allow), a trailing comma, a `v` of `1.5`, or a field of the wrong type
  (`"agent": 5` read as "every agent", `"cwd": null` as "anywhere") now refuses the
  whole file on both sides. A rules file starting with a byte-order mark is read on
  both.
- **The app leaves an agent settings file with a trailing comma alone**, as the CLI
  always did, rather than rewriting it.
- **`agentbar status` no longer deletes a session row** whose `pid` or `ts` is text or
  out of range — the app showed those rows — and it strips control characters from an
  `agent_name` before printing it. `"started": 0` no longer hides a session in the app;
  only an explicit `false` does, as the protocol says.

### Internal

- Every rule the CLI implements a second time — rule shapes, the rules file, the
  wire-disabled file, unwiring, session rows — is held to one set of shared fixtures
  (`Tests/Fixtures/*/cases.json`, about 270 cases) that both the Swift tests and the
  CLI tests read, so the two can no longer drift apart unnoticed. That is how the
  fixes above were found.

- The island controller and its view, and the menu builder, are split by
  responsibility into files of a few hundred lines each; code moved, behaviour did not.
- Releases are ready to move to an Apple Developer ID: `Scripts/dev/notarize.sh`
  (hardened runtime, notarization, stapling, a Gatekeeper check), the one entitlement
  it needs, and `UpdateSignature.successors`, so a bridge release can teach the copies
  in the field to accept the new certificate before the first notarized release
  arrives. CONTRIBUTING.md has the order. Nothing changes until there is an account.

## 1.34.0 - 2026-10-02

### Added

- **Updates install themselves, at a quiet moment.** The daily check used to stop at
  an offer in the menu, and an offer is something a person has to notice. Now a newer
  release is downloaded and checked in the background, the row reads *Update to X
  ready — Relaunch now* for whoever would rather not wait, and otherwise the app
  installs it the first time nothing is waiting on you — no approval, no question, no
  plan, no session asking — and you have been away from the keyboard for five
  minutes, or at the next launch if you quit first. Nothing appears to say so: the app
  relaunches as the new version with the menu bar and the island exactly as they
  were. Before anything is swapped in, the download's signature must satisfy the
  running app's own designated requirement — its bundle identifier and the
  certificate that signed it — so only a bundle signed with the same key gets in; one
  that does not is deleted, the row says *Update could not be verified*, and it is
  tried again at most once a day. A dev build signed ad-hoc has nothing to check
  against and keeps the click. Switch it off in **Settings ▸ General ▸ Install
  updates automatically**. Versions before this one only offer updates, so this one
  update still takes a click — or `brew upgrade --cask michalstrnadel/tap/agentbar`.

### Fixed

- **Updates work in Island-only mode.** The island's **⋯** menu had a bare *Check for
  Updates…* that checked and then had nowhere to say what it found: no *Up to date*,
  no *Install & Relaunch*, so anyone who chose the island alone could never update
  from the app. The row is now the same one the menu bar shows — checking, the
  result, and the install — and it redraws in place if the answer lands while the
  menu is open. Until this release reaches you, `brew upgrade --cask
  michalstrnadel/tap/agentbar` or the one-line installer gets you there.

## 1.33.0 - 2026-10-02

### Added

- **A watching rule is judged on whether it matched you.** Its line said how often
  it matched — *"Would have allowed 14×"* — which is a fact about prompts, not about
  the rule. It now says whether you, answering the same prompt moments later, did
  what it would have done: *"Would have allowed 14× · you did the same 13×, the other
  way 1× · last today"*, with the time you went the other way, and what it was, one
  hover away. A prompt answered in the terminal, by keystroke or left to time out
  writes nothing, so it is counted as unseen and never as agreement. Evidence starts
  at the rule's last save, because rows from before an edit were about another rule.
  After ten agreements across three days and not one disagreement, the row offers
  **Let it answer** — a button, then a confirmation that restates the evidence, then
  the same validation and write the rule sheet's Save makes. Nothing switches a rule
  by itself, and nothing appears to suggest it. `agentbar rules` shows the same
  numbers, counted the same way.

### Fixed

- **A rule saved while `rules.json` has a mistake in it no longer replaces the
  file.** A file that does not load is read as no rules, and saving a new rule from
  the sheet wrote that empty list plus the new rule over the person's own text.
  AgentBar now refuses the save, leaves the file exactly as it is, and says why.

## 1.32.0 - 2026-10-02

### Added

- **Any agent shows up as itself.** AgentBar knew nine agents, and everything else
  quietly became the first of them: a row written as `"agent": "aider"` showed
  Claude's crab in Claude's orange, a banner said *"Claude needs approval"*, and a
  click opened Claude Desktop. An agent AgentBar has no entry for now gets its own
  mark — its initial knocked out of a rounded square, in a muted colour worked out
  from its id, the same in Color and System mode — and the name it gives in a new
  optional `agent_name` field, everywhere a name appears: the island, the menu,
  Today, history, notifications. It opens the terminal it runs in and is never
  sent a keystroke: typing into a terminal AgentBar has never seen is not an
  answer anybody gave.
- **`agentbar report` — bring your own agent in a few lines.** A wrapper script or
  a vendor hook can now put any tool in the bar without writing JSON:
  `agentbar report --agent aider --name Aider --state tool --label "Editing" --pid $$`,
  and `--state end` when it stops. It is status only on purpose: `permission` is
  refused, because an approval needs a hook that waits for the answer and a report
  has none. *Bring your own agent* in `docs/protocol.md` has the eight-line
  wrapper and the raw-file form.
- **Choose which agents AgentBar wires.** It used to wire every agent it found, on
  every launch. **Settings ▸ Diagnostics** now lists each one with a switch, and
  turning one off first shows exactly what will be taken out of its settings, then
  removes only AgentBar's own entries — backed up beside the file and recorded like
  every other write. Launches respect the choice, Diagnostics reports the agent as
  turned off rather than broken, and sessions already running keep their hooks
  until they end. The choice lives in `~/.agentbar/wire-disabled`, which the Linux
  CLI shares: `agentbar unwire cursor`, `agentbar wire cursor`, and
  `install-hooks --skip`/`--only`.
- **Clawd says hello** *(with "Let the mascot react" on)*. Once, as the island comes
  up at launch, he raises a claw — twice, in about a second. Never on a later peek,
  never while an agent is working, never under Reduce Motion, and without a sound.
- **The tour as a video.** `Scripts/demo/make-gifs.sh` now writes the tour as an
  H.264 MP4 and a poster next to the GIF, from the same frames the app's own views
  draw.

### Changed

- **Usage quota matches agents by their exact id.** A third-party id that merely
  started with `codex` or `claude` could claim that vendor's quota line.
- **`agentbar status` shows a row that has no `started` field,** as the app always
  did; only an explicit `"started": false` hides one.
- **Contributors are credited.** `CONTRIBUTING.md` has a first-contribution path —
  a bridge built on `agentbar report` — and every change from outside the repo ends
  its changelog entry with a thank-you; 1.13.0's cloud agents now carry theirs.

## 1.31.1 - 2026-10-01

### Fixed

- **A rule that approves now refuses more of what it cannot read.** The refused
  flags were matched as exact words, so `rm -Rf .`, `rm -rfv .` and `chmod 4755
  ./tool` slipped past an approving `bash:rm` or `bash:chmod` rule that `rm -r .`
  could not. Short-flag clusters, unambiguous prefixes of long flags and chmod modes
  that grant setuid, setgid, sticky or world-write are now refused too. The path
  clause read the word as typed, so `cat $HOME/.config/gh/hosts.yml` looked like a
  file inside the repo: a command with `$`, `\`, braces or a glob now goes to you,
  `.` and `..` count as paths, and the value after `--opt=` is checked as one.
- **Rule firings are written down even with "Remember what I decided" off.** That
  switch also silenced the ledger rows rules write, so a rule could answer with no
  record and a watching rule could never be judged. Rows from rules no longer depend
  on it, and the Approvals page says so.
- **A deny rule on a folder now catches large edits too.** The hook cuts the request
  text at 4 KB, which broke the JSON the edit's file path was read from, so a big
  Write fell back to `tool:Edit` and missed an `edit:<dir>/*.ext` rule. The hook now
  sends the path as its own `filePath` field (see `docs/protocol.md`).
- **Codex keeps a config.toml it can load.** The check for a `notify` of your own
  only looked at the first line, so one further down got a second `notify` appended
  beside it, and TOML refuses duplicate keys. AgentBar's own `notify` was also
  appended after your tables, where TOML reads it as part of the last one; it now
  goes above the first table, and a misplaced one is moved there. A config.toml that
  cannot be read or is not UTF-8 is now left alone instead of being rewritten from
  empty. The Linux CLI places `notify` the same way.
- **The Linux CLI keeps a settings file's permissions.** `install-hooks` rewrote a
  0600 `settings.json` or `config.toml` as 0644; it now keeps the original mode.
  `agentbar doctor` no longer reports that nothing is listening right after a
  `waybar` poll, and it now refuses a rules file with a duplicate id or a relative
  `cwd`, as the app does, instead of calling it healthy.
- **Recording the launcher shortcut can no longer swallow your keyboard.** Clicking
  away from Settings mid-capture left that recorder listening and every global
  shortcut switched off until it ended.
- **Two sheets at once no longer leave one stuck.** Opening the changes sheet from
  both Welcome and Settings, or a second rule sheet from the menu, released the first
  sheet's controller, and its buttons stopped working until AgentBar quit.
- **A denied or allowed request no longer leaves its session "waiting on you".** The
  hook answered and went, but the row it had set to *permission* stayed there until
  the agent's next event. A deny now moves it on to *thinking* — the agent reads the
  refusal and carries on — and an allow back to the tool it was about to run; a row
  something newer already rewrote is left alone.
- **A banner can't answer the request that replaced it.** Prompt ids repeat within a
  turn, so a stale Allow on a notification could reach a new request filed under the
  same name. The banner now carries the request's identity and only focuses the
  session when it no longer matches.
- **A rule's folder has to be written plainly.** `/x/repo/` never matched sessions in
  `/x/repo`, and `/x/repo/../other` named a different folder than it read as. The
  rules file now refuses a `cwd` with a trailing `/`, `//`, `.` or `..` and says what
  to write instead; the sheet writes the plain form itself, and the CLI refuses the
  same.
- **A symlinked settings file stays a symlink.** The atomic write replaced a
  dotfiles-managed `settings.json` link with a regular file. AgentBar now writes
  through the link to its target and keeps the backup beside the link.
- **`agentbar watch -i` longer than a minute keeps remote approval working.** The
  presence heartbeat was refreshed only when the screen redrew, so a slow interval
  let it lapse and hooks stopped waiting on the watcher. It now beats on its own
  every 20 seconds.
- **`agentbar doctor` checks every Claude config install-hooks wires**, including
  `CLAUDE_CONFIG_DIR` and the hint file, and the CLI leaves an unreadable or non-UTF-8
  `config.toml` untouched instead of rewriting it from empty.
- **Smaller things.** A label made only of colons no longer crashes the island; a
  re-shown launcher keeps the double-Return guard a link set; the git branch is read
  for submodules whose `.git` file points at a relative path; closing the claude.ai
  sign-in window stops its poll; a hand-edited timestamp no longer traps at launch;
  the launcher reads the session list on the main thread.
- **The test suites no longer touch your own data.** One test wrote watch rows into
  the real `~/.agentbar/decisions.jsonl` on every run and another read the real
  `rules.json`; the shell suites now also drop an inherited `COPILOT_HOME` and
  `CODEX_HOME`.

## 1.31.0 - 2026-10-01

### Added

- **AgentBar keeps a copy before it touches an agent's settings, and shows you the
  change.** Every launch rewires the hooks, and until now the only record of what
  that did to `~/.claude/settings.json` or `~/.codex/config.toml` was the file
  itself. Now each write first copies the file as it was to
  `settings.json.agentbar-bak-20261001-142233` (local time) beside it, keeps the
  newest three of those per file, and appends the change as a unified diff to
  `~/.agentbar/config-changes.json` (the last twenty writes, readable only by you,
  because a diff quotes settings lines). A write that would change nothing does
  nothing — no backup, no record, not even a new modified time — so a quiet launch
  leaves no trail. **Settings ▸ Diagnostics ▸ Show changes…**, and **See what
  changed…** in the welcome window once something has been written, open a sheet
  with both halves: what a re-install would change right now, worked out by the
  installer's own code without writing a byte, with **Write it now**; and every past
  write with its diff, where the copy went and **Show in Finder**. The backup name
  ends in a timestamp, never `.json`, so an agent that loads every `*.json` in a
  folder never picks one up; rotation removes only names it wrote itself, so a
  `settings.json.agentbar-bak-mine` of yours is left alone. The diff is stored
  rather than worked out later because the agent may edit its own settings in
  between, and then it would no longer be AgentBar's change. On a first install into
  a hand-formatted JSON file the diff shows the whole file rewritten: that has always
  happened, it is only visible now, and the copy keeps your formatting. The Linux
  CLI's `install-hooks` prints the same diff before each write and keeps the same
  three copies. The OpenCode plugin is AgentBar's own file and is not copied.
- **The island can step aside — and you can always get it back.** Two switches on
  **Settings ▸ General**, both off: **Hide the island when nothing is running**, and
  the new **Hide the island while you're away**, which hides it after three minutes
  without keyboard or mouse, even with agents working, and brings it back on the
  first touch. Three minutes, not the two the notifier waits, because a pill that
  vanishes while it is still being read looks like a bug. What makes hiding safe is
  the **peek**: push the pointer up to the notch and a hidden pill comes back, a
  moment longer opens it as usual, and moving away lets it slip off again. A pointer
  already parked there summons nothing — it has to arrive. Anything waiting on you —
  an approval, a question, a plan — keeps the pill up whatever the switches say, and
  it still never opens by itself; so does an open panel, a note half typed, and the
  **✓ Allowed** flash.
- **A mascot with a little life in it** *(off by default)*. On the island only, never
  in the menu bar: at rest Clawd's eyes follow the pointer as it comes within reach
  and blink now and then; a mark clicked in the open panel squishes, three quick
  clicks make it dizzy; and a long task finishing gets a one-second sparkle in the
  pill. The sparkle is throttled the way the notifications learned to be — only
  after ninety seconds of work, at most once per session every fifteen minutes, one
  for two sessions finishing together — because Claude Code finishes after every
  turn and a conversation of quick turns must not glitter. No sound of its own. It is
  opt-in because both of its edges change what you already had: a pill that blinks
  all day is a wobble in the corner of your eye, and with it on, a click on a row's
  mark pokes it instead of jumping (the rest of the row still jumps). **Settings ▸
  General ▸ Let the mascot react**; Reduce Motion keeps it off whatever the switch
  says. The eyes are found in the artwork rather than at fixed pixels, so a redrawn
  sprite switches the gaze off instead of drawing eyes in the wrong place.

### Changed

- **Hide the island when nothing is running now works in Island-only mode.** It was
  shown there and did nothing, because without a menu bar item a hidden island left
  no way back to Settings. The peek is that way back: the pill, then the panel, then
  its **⋯**. If you are in Island-only mode and ticked the switch back when it did
  nothing, the tick is cleared once on the first launch, so your only surface does
  not disappear after the update; set it again and it stays.
- **The island moves like it belongs to the notch.** On a notched display the open
  panel curves into the edge it hangs from — two small concave ears at its top
  corners — instead of meeting it with square shoulders; the rows keep their width,
  clicks in the ears' strips reach whatever is underneath, and the collapsed pill
  has none. The ears grow with the panel's height, so they unfurl and fold with the
  frame in one animation rather than snapping on. Opening has a slight overshoot,
  closing none, and the refreshes a working session causes keep the plain curve so a
  ticking panel never wobbles. Hiding and showing fade and slide a few points into
  the notch instead of blinking out; an open panel that has to hide folds back into
  the pill first and stops taking clicks the moment it starts leaving. Under Reduce
  Motion the island only fades and opens without the overshoot. Screens without a
  notch look as they did.
- **The README's first screen says what AgentBar does and what to try.** One tour
  GIF, why it exists, and a table of things to try, each checked against the app.
  The old line that nothing ever decides on your behalf is gone: it stopped being
  true when rules you write began to answer in 1.28.0.

### Fixed

- **The Linux CLI's Codex install no longer undoes its own repair.** It wrote
  `config.toml` twice, the second time from the original text, so when node had
  moved, the fixed `notify` path was overwritten by the hooks rewrite and the dead
  one came back until the next run. Both keys are now built and written once.
- **`agentbar install-hooks` no longer wires a Claude config outside your HOME.** A
  run with a borrowed HOME — a test, a sandbox, `HOME=$(mktemp -d)` — still
  inherited `CLAUDE_CONFIG_DIR`, and wrote the real config's hooks to point at the
  throwaway directory, so every session started afterwards ran them from there until
  the app repaired it. A config directory outside HOME is now skipped with a line
  saying so; `AGENTBAR_ALLOW_CONFIG_OUTSIDE_HOME=1` wires it anyway. The test scripts
  that borrow HOME now drop the inherited value too.
- **Settings files the app writes no longer escape every slash.** Hook commands came
  out as `\"\/opt\/homebrew\/bin\/node\"`, valid but unreadable, and now that every
  write shows a diff, the noise was the whole diff. The first launch after updating
  rewrites the file once without them, and keeps the usual backup.

## 1.30.0 - 2026-09-24

### Added

- **Deny with a note — refuse, and say what to do instead.** A permission hook has
  exactly one way to steer an agent rather than stop it: the reason that goes with a
  denial, which the agent reads as the tool's result. AgentBar never used it, so every
  Deny said *no* and left the agent to guess, usually by trying the next thing. Now
  **Deny with a note…** on the island card opens one line — *"use pnpm here, not npm"*,
  *"not on main"* — and **Deny & tell it** (or Return) sends it. The notification
  banner carries the same field, and the CLI takes `agentbar deny --note "…"`. On a
  plan review the link reads **Say what to change…** and the note is the feedback the
  plan goes back with; Claude keeps planning. The note is flattened to one line and
  capped at 500 characters by the hook itself; a blank one is no note, and a bare
  Deny goes out exactly as it always did. Claude Code and Copilot CLI document the
  field; Codex shares Claude's envelope and has not been checked against a live
  prompt.

  **Rules can say it too.** A denying rule gains **Tell it** in its sheet — `tell` in
  `rules.json` — and every refusal it makes carries that line. It is a new field on
  purpose rather than the existing *Note*: that one was always your private memo, and
  a reminder written to yourself must not start arriving in an agent's context
  because the format grew. An approving rule that carries one voids the file; an
  approval has nothing to explain.
- **Jump back into tmux, kitty, Ghostty and your editor.** A row click selected the
  exact tab in iTerm2, Terminal and WezTerm and only brought everything else forward
  by name. Now:
  - **tmux** — the pane whose tty is the agent's is selected, its window too, the
    client that should show it is switched to it, and the terminal running that
    client comes forward with its own tab selected. iTerm2's `-CC` gateway is never
    taken for a screen.
  - **kitty** (with remote control switched on), **Ghostty** (when exactly one of its
    terminals sits in the session's folder) and **VS Code, Cursor and Zed** (handed the
    session's folder, which focuses the window that has it open) get a best effort.
  - **Everything else** comes forward as the app the agent really runs in, found by
    walking its parent processes, instead of the one `TERM_PROGRAM` names — which for
    Cursor's terminal was VS Code.

  Keystroke approvals reach tmux as well, but only when both the pane select and the
  outer tab select report a hit; kitty, Ghostty and the editors are never typed into.
- **Agents on your own machines, over ssh.** The cloud poller gains an `ssh` adapter:
  list hosts in `~/.agentbar/cloud.json` and their sessions — written there by the
  Linux CLI's hooks — appear in the bar as `gpu: my-repo`, a click opening
  `ssh://gpu`. Every host is read with `BatchMode=yes`, only rows whose agent is still
  alive on that host come back, a host that is asleep costs its own rows and nobody
  else's, and a host name that could be read as an ssh option never reaches `ssh`.
  Read-only on purpose: a remote session waiting on permission says *Waiting on you
  on gpu* and is answered where it runs, because no hook on this Mac is blocked
  behind it. Off until you switch it on and list hosts. A remote host is not
  trusted with a number either: its times are clamped, its rows capped at fifty, and
  a host that misses a poll keeps its rows for a minute before they go.
- **`agentbar://` links, for Shortcuts, Raycast, Alfred and scripts.** `focus` jumps
  to the session that needs you (or `?session=<id>`), `new-task?cwd=…&agent=…&prompt=…`
  fills the launcher in and waits for your Return, `settings/<page>` and `welcome`
  open those windows. Any web page can open a link, so the scheme is a list of what it
  may *show*: no host approves, denies, answers, defers, writes a rule, changes a
  setting or runs anything, a `cwd` must be a plain absolute directory, and an
  over-long prompt refuses the link rather than being cut. A link-filled launcher
  takes Return twice (a page can say "press Enter"), and `focus` never jumps to a
  cloud or ssh row, whose click would open a URL somebody else wrote. See
  `docs/url-scheme.md`.
- **A row with an impossible time can no longer crash the app.** Anybody may write
  `state.d`, and a `started_at` of `1e300` reached an `Int(_:)` that traps on it —
  on every poll, so a relaunch did not help. Times are checked where a row is read.
- **Your own sounds.** Put `permission`, `question`, `done` or `ack` — `.aiff`, `.wav`,
  `.caf`, `.mp3` or `.m4a` — in `~/.agentbar/sounds/` and it replaces that cue, at
  the same volume and with the same rules about when anything plays. A file over
  2 MB or 3 seconds is skipped and the built-in cue plays instead. **Settings ▸
  General ▸ Open folder…** makes the folder and says which cues are yours.

## 1.29.0 - 2026-09-23

### Added

- **"Compacting…" while Claude summarises its context.** Compaction used to look
  like more thinking, or like nothing at all after a manual `/compact`. The row now
  says *Compacting…*, the bar and the island pill hold that one word instead of
  rotating verbs, and when it ends the row goes back to what it said before: a
  `/compact` after a finished turn lands on *done* again, recap and all. No new
  state and no protocol change — it is a label on a working row, the same channel
  approvals and questions already use for their detail. Takes effect in sessions
  started after the update.
- **The download can answer for itself.** CI has attested its build since 1.27.0,
  but the release is that build signed again here, so `gh attestation verify` on a
  downloaded zip found nothing. Now, when a release is published, a workflow checks
  the asset against the CI build of the tagged commit — every file outside the
  signature byte-identical, each architecture's code the same — and only then
  attests the asset itself. 1.28.1 has been attested the same way. The signing
  certificate still never leaves this machine. See *Verifying a download* in
  `SECURITY.md`.

### Changed

- **Session rows in the menu are drawn, not typeset.** The time and the agent now
  sit in aligned columns on the right instead of wherever a name happened to end, a
  long recap is what gives way before the project name does, and the row draws its
  own highlight. An open menu still refreshes in place and never shrinks.
- **A first run that says what is going on.** An empty list on a fresh install reads
  *Waiting for your first session* and says why sessions already open are missing:
  they began before the hooks. The welcome window and the installer's last lines say
  the same. An ordinary quiet moment still reads *No active sessions*.
- **The folder-access prompt explains itself.** When your projects live in
  Documents, Desktop or Downloads, macOS asks once whether AgentBar may read them; the
  dialog now says why (the git branch and changes on each row) and that nothing
  leaves the Mac.
- **The Gatekeeper warning, as macOS 15 shows it.** The README's troubleshooting now
  walks through *Open Anyway* in Privacy & Security instead of the right-click that
  no longer bypasses it, and no longer calls the app ad-hoc signed.

## 1.28.1 - 2026-09-23

### Changed

- **New app icon.** The prompt chevron is gone. The island is now the object: a
  glossy charcoal slab with four glass lamps, one per agent, and Claude's is lit,
  set on a screen washed in the same four colours inside the ivory frame. The
  README, the social banner, the demo GIFs and video, and the welcome screenshot
  all carry it. The runner-up, the island opened on an Allow/Deny question, is
  kept in `docs/archive/2026-09-23-app-icon-concepts/`.

## 1.28.0 - 2026-09-21

### Added

- **Rules you wrote — the first thing AgentBar will answer without asking.** For
  six releases the rule was absolute: every decision came from a click, and the
  code said so in three places. It is amended on purpose, not quietly. A rule you
  typed yourself, in **Settings ▸ Approvals**, may answer a permission request the
  way you would have — and four things earn that.

  **You wrote it.** A rule is never derived from the "Always allow" Claude Code
  suggests: that suggestion is produced by the thing being guarded. When you have
  answered the same prompt the same way five times and never once the other way,
  the card offers to write it down — *Always allow this here…* — and the offer
  opens a sheet, which is where the rule is actually made. The sheet spends most
  of its room saying what the rule will **not** answer.

  **It names one place.** A rule that refuses may cover every repository on the
  machine; refusing more than you meant costs a prompt. A rule that approves names
  one directory, because approving more than you meant is the failure this feature
  has to not have.

  **The command is read again before it is approved.** A rule matches on the same
  key the repeat count uses — `git push`, never `git push origin feature/PR-4113`,
  because arguments never repeat and are where a secret would be. That key is a
  true description and still not enough to say yes with, so every approval is
  checked a second time against the command as it will actually run. It comes back
  to you if the line holds more than one command, a pipe, a redirect or a
  substitution — `git status && …` carries the shape of its head, so this one is
  the whole design; if it runs under `sudo`; if it is a destructive or
  history-rewriting git, an `rm` that recurses or forces, a `chmod 777`, a `find`
  that deletes what it finds; if it is a shell, or an interpreter handed a snippet
  — `sh -c …`, `node -e …` — because those describe one act in their name and carry
  out another in their arguments; if it reaches off this Mac; if it names a path
  outside the rule's directory, **including the path the command itself is run
  from**, so a rule written for `npm test` does not cover `/tmp/somewhere/npm test`;
  or if it touches how permission itself is configured — `~/.agentbar`, an agent's
  settings, `.git/hooks`, an `.env` or a private key, named with a path or without
  one. **No setting turns that list off**, and anything the engine cannot read is a
  refusal.

  **You can see what it did.** Every firing writes a row naming the rule, so the
  rules list says *"Allowed 12× · last today"* under each one and `agentbar rules`
  says it in a terminal. The rules file itself holds no counters: intent lives in
  `~/.agentbar/rules.json` — plain JSON, yours to edit — and the record lives in the
  ledger, so the two can never disagree.

  **And you can watch it before you trust it.** A rule has three states, not two.
  A new one starts out **watching**: it matches, works out the answer, writes down
  what it *would* have done — and answers nothing. The prompt still comes to you.
  A week of *"would have allowed 14×"* is how somebody finds out whether an
  approving rule matches what they pictured, and it is the only way to find that
  out that costs nothing when the answer is no. Everything that enforces anything
  gets an audit mode before an enforce mode; this is AgentBar's.

  **Rules have their own page** in Settings, with an editor that spends most of its
  room on the rule's edges: what it will never answer, and a field where you type a
  real command — `git push --force origin main` — and are told on the spot whether
  this rule would have taken it, and which clause stopped it. A rule can be changed
  after it is written, not only removed and typed again. On a Mac where nothing has
  been decided yet the field still offers the ordinary shapes — `git status`,
  `npm test`, `swift build` — because the day AgentBar is installed is exactly when
  somebody is working out what to put in it.

  Nothing in the file applies while any of it is wrong. One malformed rule voids the
  whole file rather than leaving three of your four running with nothing on screen
  saying which, and **Diagnostics reports it** — a rule that quietly stopped working
  looks exactly like AgentBar working normally, which is the one failure here that
  hides itself.

- **Codex joins the queue — properly.** Codex CLI grew a hooks engine shaped like
  Claude Code's: the same event names, the same payload, the same decision envelope.
  So the same scripts serve it, the way they already serve Copilot CLI and Qwen Code,
  and two things change at once.

  **A Codex session is now live.** It appears the moment it starts rather than after
  its first finished turn, and carries what it is doing, which tool, the prompt you
  typed, the model, a recap when it stops, and an ending — all of it, for the first
  time. Until now Codex had one event upstream, `agent-turn-complete`, and a row
  that could only say *done*. A failed turn even looked like a clean green tick.

  **And a Codex approval is a real decision.** It arrives as a card with buttons,
  it goes into `decisions.jsonl`, and the rules you wrote apply to it — because
  Codex sends Claude's own tool vocabulary (`Bash`, `{"command": …}`), a rule
  written for `bash:git status` covers both agents without knowing there are two.
  No **✓ Always**, though: Codex has no channel for a standing rule, so an "always"
  would quietly be a one-shot allow and the button is not offered — the same
  honesty Copilot gets.

  **Codex asks you once before it will run any of this.** A hook it has not been
  told to trust is skipped in silence, and AgentBar does not sign that acceptance
  on your behalf — it could, the API is right there, and an installer that trusts
  its own blocking hook is exactly what rule 3 exists to prevent. So Diagnostics
  carries a row saying the hooks are written and waiting, and the old `notify`
  bridge keeps reporting sessions until you answer. Everything measured against
  codex-cli 0.155.0 and written down in `Scripts/hooks/codex/README.md` — including
  the two that matter most, checked against a live session rather than read off a
  schema: a **deny** reaches the agent with its reason intact, and **silence falls
  through** to Codex's own prompt, which is what every failure path in the hook
  depends on meaning.

- **Diagnostics can now do the thing it tells you to do.** Every check has carried
  its fix in words since 1.21.0, and for three of them the words were "relaunch
  AgentBar" — so those rows grew a button that does it: re-install the hooks,
  create the directories, clear the leftovers. Only where the repair is AgentBar's
  own to make. A `chmod` on a path in your home stays a sentence, because a button
  that quietly changed permissions there would be the worse product.
- **And it can prove the approval path works, by using it.** *Test an approval*
  raises a real request through the real hook — not a simulation, not a
  special case — and waits for you to answer it. If it works, remote approval works
  on this Mac; if it does not, the line underneath says which end broke. Every other
  check reads a file and reasons about it, which means every other check can pass
  while the feature the product is built on has never once run. That is not
  hypothetical: on the machine this was written on it never had (issue #1).

- **Export the record.** *Settings ▸ Approvals ▸ Export…* and
  `agentbar approvals --export` write every decision out as a spreadsheet: when,
  which agent, which directory, what was asked, who answered, which rule, and how
  long the agent waited. A record you cannot show anybody is half a record. A
  watching rule's rows are in it and say what they *would* have done, because a
  week of that is exactly what somebody would be asked for. A field that starts
  with `=`, `+`, `-` or `@` is defused on the way out — the export carries commands
  an agent wanted to run, and a spreadsheet would read one as a formula to evaluate.
- **The fall-through guarantee is published as a contract.** *Every failure
  degrades to the agent's own prompt, never to an approval* used to be one sentence
  in `SECURITY.md`. It is now eighteen numbered clauses — no frontend, unparseable
  stdin, a junk answer, another hook's answer, a timeout, a SIGTERM, a rules file
  that will not parse, a mode that cannot be read — and each one is a test that
  runs on every release, named by its number so a clause nobody checks reads as a
  gap instead of hiding inside a scenario.
- **An SBOM rides every build**, beside CodeQL and the signed provenance that
  landed in 1.27.0. It is short, and that is the claim: no third-party Swift
  packages, no npm dependencies in the hooks. Now anybody can check it rather than
  take it.
- **Which agents will let somebody else decide, measured** —
  [`docs/permission-surfaces.md`](docs/permission-surfaces.md). Being *called*
  before a tool runs is not the same as being able to approve it, and three
  vendors sit on each side of that line. Claude Code, Codex and Copilot take an
  allow; **Cursor and Gemini take only a refusal** — Cursor validates `allow` and
  then compares against `"deny"` and nothing else, Gemini's `BeforeTool` has
  `block`, `deny` and `ask` and no `allow` at all. That is why neither gets a card:
  you would press Allow, the agent would discard it, and it would ask you again in
  its own terminal. Every row names the version it was measured against and whether
  it was read or run.

- **Today says how much of the day you answered and how much a rule did**:
  *"18 answered · 3 by your rules · they waited 34m on you"*. Kept apart rather than
  added up — a rule answers in milliseconds and nobody was asked, so folding its
  rows in would overstate what you did and understate the wait. `agentbar approvals`
  does the same.
- **`agentbar rules`** lists what you wrote, which mode each rule is in, and what
  it has done — or, while it is watching, what it would have done. It lists
  them; only the app answers from one, and it says so. The check that makes an
  approving rule safe is one table in one language, and a second copy of it in the
  CLI would be a second thing to keep identical in the one place where drifting
  apart means approving something nobody meant to.

### Changed

- **The permission hook now carries the session's directory** on the request. Every
  reader was joining back through `state.d` to learn something the hook had in hand,
  and a rule that says "in this repository" cannot be evaluated without it. A host
  that does not send one leaves the field out rather than empty: empty compares equal
  to nothing and is indistinguishable from `/` in a prefix test, which would make a
  rule scoped to one repository match every one.

### Fixed

- **A decision made with the global chord was not always counted.** When the chord
  answered a request whose session the app had not seen yet, the answer was written
  straight to disk and the ledger was skipped — so it never appeared in
  "Allowed 23× here", and now that the same count is what a rule is offered from,
  a silent gap there is worse than a wrong number.

- **The island's quota line ran off the side of the island.** It is handed
  whatever width is left beside the ⋯ button, and it was drawing at full length
  regardless — through the button and out past the panel's rounded edge — so a
  provider whose whole truth is a sentence (Claude, while it has no percentage)
  pushed the numbers off the screen. Text drawn at a point ignores the view it is
  in, and since macOS 14 so does AppKit: nothing clips a view's drawing to its own
  bounds any more. The line now places every piece inside the width it was given,
  and the reading that runs out of room ends in an ellipsis; the whole of it is
  still one hover away.

- **One silly number in a Codex rollout could take the whole app down.** A window's
  reset time is read straight out of a file AgentBar does not write, and `1e19` is
  an ordinary JSON number — finite, parseable, and past `Int.max`, so converting it
  is not a wrong answer but a crash. It travelled from the file into a date and back
  out through the redraw signature, which runs on every usage refresh. A reset after
  the year 2100 is not a reset, and is now read as no reset time at all. The same
  reading applies to a wait in the decision ledger, which is a file you are invited
  to keep and other tools can append to.

- **One broken character could hide a whole session.** A lone half of a surrogate
  pair — from a pasted prompt, a trim somewhere upstream, a single corrupted byte —
  went into the session file as written. Swift refuses to decode a file containing
  one, so the session disappeared from the menu bar and the island until its next
  clean write. In a permission request it was worse: the card never appeared and the
  agent sat there for the full ten minutes waiting for an answer nobody could give.
  Every value now passes through the check on the way out, in all eight writers.

- **On Linux, three things the app knew and the `agentbar` CLI did not.** A quiet
  Antigravity session never ended there — Antigravity sends no terminal event, and
  only the app had the watchdog that turns a session quiet for 90 seconds into
  *done* — so it animated for ever and never reached `agentbar history`. A decision
  answered after its session row was gone lost the directory it was made in, which
  is what scopes "allowed 23× here". And `agentbar doctor` said nothing about a
  rules file that will not parse, which is the one failure that looks exactly like
  everything working. All three now match the app, and the two halves are compared
  by their own tables rather than by reading them side by side.

- **A cloud row cannot ask for permission.** `docs/protocol.md` has always said a
  cloud writer must use *question* rather than *permission*, so that nothing offers
  an Allow with no waiting hook behind it. The code trusted every writer to have
  read that; now the poller rewrites it where the row is built and the app checks
  before it types anything. Codex made it real — it has both keystroke approval and
  cloud tasks, so an Allow on such a row would have sent a Return to whatever window
  happened to be in front.

## 1.27.2 - 2026-09-17

### Fixed

- **AgentBar crashed every few minutes once you were signed in to Claude.**
  WebKit initialises itself the first time anything touches it, and it traps if
  that happens off the main thread. The five-minute usage refresh runs on its own
  serial queue, and from there it reached the cookie store — which took the whole
  app down inside `WebKit::InitializeWebKit2()`, over and over, because the hooks
  bring AgentBar back up again.

  It could only happen to somebody signed in: until 1.27.0 there was no session
  to reach for, and the refresh stopped before it got that far. Every WebKit
  touch now goes through one hop to the main thread — immediate when it is
  already there, because the sign-in window acts on what it gets back.
- **The quota line stopped appearing on the island at all, on and off.** It sits
  in a row beside the ⋯ button, where nothing stretches it — and it never stated
  a width of its own, so the layout was ambiguous and the solver was free to
  resolve it either way. When it resolved against the line, the line was given
  zero width and drew nothing. It came back on the next rebuild, which is what
  made it look random; what actually changed was the number of providers on the
  line. It now states exactly the width it draws, measured the same way, and a
  line too narrow for even its first reading draws that one clipped rather than
  drawing nothing.

## 1.27.1 - 2026-09-17

### Fixed

- **The floating page title is gone.** AppKit centres a window's title across
  the whole window, and a third of the Settings window is sidebar — so "Usage"
  and "Approvals" sat a third of the way into the content, lined up with nothing.
  Rather than align it, it is removed: the sidebar's selected row names the page,
  which is how System Settings has always done it, and the band at the top is
  left clear for the traffic lights. Nothing in that window is placed by anything
  but a rule now.
- The window's height allowed 48 points for what sits above and below a page and
  needed 76, so the tallest page could get a scroller for no visible reason.
- **Sign out now empties the whole site record**, not just the session cookie.
  People press that button to sign back in as somebody else, and a site that
  still holds its local storage can put you straight back into the account you
  were trying to leave.

## 1.27.0 - 2026-09-17

### Added

- **Sign in to Claude, and the percentages appear.** One button in
  **Settings ▸ Usage** opens claude.ai's own login page in a window of AgentBar's,
  and from then on Claude gets the same meters Codex has: the 5-hour window, the
  weekly one, the reset times. No terminal, no token to paste, nothing to grant.

  It exists because the other route ran out. `ClaudeQuota` borrows the login
  Claude Code stored in the Keychain, which is right whenever the CLI keeps one
  there — and on a Mac whose sessions run under their own `CLAUDE_CONFIG_DIR`
  that record is empty, so there was nothing to borrow.

  What this does **not** do is read your browser. The usual answer to this problem
  is to open Chrome's cookie database (decrypting it with a key out of *its*
  Keychain item) or Safari's (behind Full Disk Access). Both work; both are this
  app reading another application's credential store; and both still end in a
  permission dialog, so they buy nothing a sign-in does not. The session lives in
  AgentBar's own cookie store, WebKit renews it, and **Sign out** empties it.

  The numbers come from the two calls the site itself makes — the account, then
  its usage — and the body has the same shape the OAuth endpoint uses, so both
  doors go through one parser rather than two.

### Fixed

- **The macOS password prompt no longer arrives on a clock.** Reading the login
  Claude Code keeps in the Keychain means reading another application's item, and
  macOS guards that with its own "enter your password" dialog. AgentBar asked for
  it from the five-minute refresh, which made it appear at no particular moment
  and made a **Deny** worth nothing: the answer was not remembered, so the same
  dialog came back five minutes later, and again, and the dialog also returns
  after every reinstall — anyone shipping a handful of builds in a day met it
  once per build.

  Now only **Settings ▸ Usage ▸ Check now** opens that door. An Allow is
  remembered and the refresh reads quietly from then on; a Deny closes it until
  the button is pressed again; and the switch itself raises nothing. The two
  credentials that cost nobody a dialog — a signed-in claude.ai session and a
  token pasted in on purpose — are read on the clock as before, so on a Mac that
  has either, no prompt ever appears at all. A signed-in session also stands the
  Keychain path down entirely rather than asking Anthropic the same question
  twice.
- The settings row holding the quota status is sized from the label it holds
  rather than from a measurement taken of it once: that sentence changes while
  the window is open, and a longer one had the separator drawn through its
  second line.
- Diagnostics' last line — the fix under a check — was cut off at the card's
  edge: that view starts as the word "Checking…" and ends as a list, and its row
  had been sized once, at the start. Everything in that window which can change
  size now follows the thing that changes, rather than a number copied from it.
- The sign-in window presents itself the way a browser does. WebKit's own user
  agent leaves off the `Version/… Safari/…` tail, and claude.ai answered the
  first attempt with "there was an error logging you in" before a character had
  been typed.

## 1.26.1 - 2026-09-17

### Fixed

- The settings sidebar, measured against the system's own rather than eyeballed:
  the tile and the word were touching, because an `NSButton` gives no say over
  the gap between its image and its title and the first cut padded it with spaces
  in the string. Each entry is laid out by hand now — a 20 pt tile, ten points, the
  label — and the rows have the height and spacing a source list has.
- Cards were a concrete-coloured slab: one flat grey used for both appearances,
  which on a white page is far too dark. A card is a tint on the page now — black
  at four and a half percent on white, white at eight on dark.

## 1.26.0 - 2026-09-17

### Changed

- **Settings is a window again, not a document.** Six pages behind a sidebar —
  General, Notifications, Shortcuts, Usage, Approvals, Diagnostics — each a short
  column of grouped rows with the control on the right, the way a Mac settings
  window has looked for years.

  The old one stacked every section down a single scroll, which has two faults that
  compound: everything is visible at once, so nothing is findable, and each switch
  carried a paragraph, so the window grew until Diagnostics sat off the bottom of
  the screen. Every explanation is now one sentence under its own row; the rest was
  always in the README.

- **A missing meter says why on the island too.** A bar that is simply absent reads
  as a broken app — it was read exactly that way — so when the quota is switched on
  and cannot be read, the island's line carries the short reason after the number.
  It disappears the moment there is a number to show.

### Fixed

- **Today counted sessions nobody ran.** Six "Antigravity · <1m" rows on a Mac
  where Antigravity has never been opened — they were the watcher's own
  integration tests. That suite has to drive the *live* app, so unlike every other
  suite it writes into the real `~/.agentbar`, and the app dutifully recorded each
  synthetic session in the day's history. It now takes its own rows back out, and
  so does the Cowork suite, which had the same shape. A test that leaves rows
  behind is a test that lies about your day.

  Those two suites are also opt-in now (`AGENTBAR_LIVE_TESTS=1`), because while
  they run their synthetic sessions are *live*: an agent you never started,
  appearing on your island, on your screen, while you work. A test has no
  business being visible.

- Three layout faults in that new window, each found by looking at a picture of
  it rather than at the code: a subtitle measured two points short of what its
  own field wanted, so its second line was clipped out of existence; rows whose
  vertical padding collapsed to nothing, because a stack aligned on centreY does
  not pin its views to its edges; and every card, hairline and page background
  assigned as a `CGColor`, which is a dynamic colour flattened against whichever
  appearance happened to be current — the whole window would have kept its
  light-mode greys in dark mode.

### Added

- `--render-settings` writes every settings page to one PNG. Same idea as
  `--render-sounds` and `--render-usage`, and the same reason: this window opens
  over the work being done to it, so nobody looks at it while changing it.

## 1.25.0 - 2026-09-17

### Added

- **A way to get Claude's percentages on a Mac whose login AgentBar cannot read.**
  1.24.0 could finally say *why* there was no bar, and on the machine it was written
  on the answer turned out to be: Claude Code's Keychain record is empty. Sessions
  running under their own `CLAUDE_CONFIG_DIR` keep their login elsewhere, and no
  amount of asking politely reaches it.

  **Settings ▸ Usage ▸ Use a token…** takes one from `claude setup-token` instead. It
  is kept in AgentBar's own Keychain item — the only secret this app has ever stored,
  never in a file, never logged, used for nothing but the five-minute request for your
  quota, and removed by the same button. Nothing is stored unless you paste it in, and
  a token given this way outranks whatever the CLI left behind, because pasting one is
  a deliberate act with a deliberate meaning.

  The file's standing promise — *the token is borrowed, never kept* — now carries that
  exception in the same breath, rather than being quietly broken.

## 1.24.0 - 2026-09-17

### Fixed

- **The Claude quota read could send another service's OAuth token to Anthropic.**
  To find its bearer token it searched Claude Code's Keychain record for any field
  called `accessToken`, at any depth. That record does not hold one login — it holds
  Claude's *and* an entry for every MCP server you have ever authorised, each with an
  `accessToken` of its own. A Swift dictionary has no order, so which one came back
  was luck, and it went out in the `Authorization` header of a request to
  `api.anthropic.com`.

  It now reads `claudeAiOauth.accessToken` and nothing else: the field is named, never
  searched for, and an unrecognised record means no reading rather than a guess. The
  regression test asserts fifty times over that a record with three third-party tokens
  and no Claude one yields nothing.

  Present in 1.19.0–1.23.0, and only while **Settings ▸ Usage** was ticked, which is
  off by default. If you had it on, rotating the MCP logins you had authorised is the
  cautious move.

- **The same search decided whether the token had expired**, so a neighbour's
  timestamp could rule Claude's login out — and a `0`, which is how "no expiry" is
  written, was read as 1970 and meant *permanently expired*. Between the two, the
  feature could sit switched on and never make a single call. Expiry is now Claude's
  own field, a zero is no expiry, and a value in seconds is not read as milliseconds.

### Added

- **The switch says what happened.** Everywhere else a failed reading is silent —
  an error message where a number belongs is worse than an empty space — but beside
  the switch that caused it, silence is indistinguishable from a broken switch. So
  **Settings ▸ Usage** carries a sentence naming the cause: no login stored, a login
  that is empty, a Keychain refusal (with the code), an expiry, Anthropic's own
  message for a 401, a rate limit and when it lifts, or when the last good reading
  came in and for which account. **Check now** asks again on the spot, which is also
  the only way to raise the macOS Keychain prompt deliberately rather than waiting up
  to five minutes for one that may be behind another window.
- The menu's usage block repeats the short form under Claude's row, so the answer to
  "why is there no bar here" is where the bar isn't.
- `--quota-status` on the app's binary prints that sentence from the command line,
  for the same question asked while the app isn't running.

### Changed

- **The island's line carries what you are running.** It is one line, shared with the
  ⋯ button, and a quota you are not spending is true but not news: the providers with
  a live session come first and the rest stay in the menu, which is where the full
  block has always lived. Two exceptions keep that honest — a provider at 80 % or more
  stays whether or not it is running, because that is exactly the moment worth
  hearing about unasked, and when nothing is running the last thing that was stays,
  so the line doesn't blink out between sessions. Hovering it still names every
  provider.
- A row that is a sentence rather than a value now starts at the margin and takes the
  width. Held in the numbers column, "~654k tok this 5h block · resets 12:00" arrived
  as "~654k tok this 5h block…", losing the half that answers the question.

## 1.23.0 - 2026-09-17

### Changed

- **The island shows the meters, not a sentence about them.** 1.19.0 put the usage
  block in the menu, which on an island-only setup is behind the ⋯ and therefore
  nowhere anyone would find it. The island's footer already spent one line on
  quota; that line is now drawn instead of written — a small bar per provider and
  what is left of it, at exactly the height the sentence had. The reset times and
  the second window stay one tooltip and one ⋯ away.

  The number says **"3% left"** rather than "3%": a bar that is nearly full beside
  a bare number reads as a contradiction, because the bar says what is gone and the
  number says what is left.

## 1.22.0 - 2026-09-17

### Added

- **Start a task, not just an agent.** The menu could always bring an agent
  forward; it could never put one in a particular repository with a particular job.
  **New task…** — or ⌥⌘N once you switch the chord on — opens a small panel: a
  project you have worked in, an agent, and a line of what you want. The agent opens
  in a terminal, in that directory, with the prompt already given.

  It is the app's third surface and the first one summoned by a keystroke, so it
  earns that the same way the banners do, and rule 2 now says so: it takes no space
  until asked, it appears only on a deliberate press or click, and it closes the
  instant it loses focus.

  Two refusals are the feature:

  - **The prompt is never typed as keystrokes.** It goes in as an argument, through
    one escaper — checked against a real `/bin/sh`, not against the shape of a
    string. Synthesizing arbitrary text into whatever happens to be in front, with
    somebody's shell on the other end, is not a thing this app will do.
  - **Only agents whose CLI documents a prompt argument get one**: Claude, Codex,
    Cursor and Gemini, each read out of the tool's own `--help`. Copilot, OpenCode
    and Qwen document a prompt *flag* for their non-interactive modes, which is a
    different thing — guessing would start a session that runs once and exits with
    the work half done. They open in the right directory and wait for you to type,
    and the panel says so before you press return.

  Terminals it can hand a command to: Terminal.app and iTerm2 (AppleScript, the
  consent macOS already asks for), Ghostty, WezTerm, kitty and Alacritty (their own
  CLIs). Warp has no documented way in, so the command goes to the clipboard and the
  panel says that out loud — a half-started session is worse than an unstarted one.

### Changed

- Global shortcuts are registered as one list rather than one pair, because two
  features now own chords and anything that starts by clearing the table would
  silently drop the other one's.

### Fixed

- **A one-in-three-hundred flake in the test suites.** Every suite named its
  throwaway home `home.$$.$RANDOM`, and two draws out of 32768 collide often
  enough: a "fresh" home that is really a previous one still holds its files, and
  the checks that assert a directory is empty fail on a machine nobody is watching.
  Caught in CI on Linux — *"codex non-complete event ignored"* — and now a counter.

## 1.21.0 - 2026-09-17

### Fixed

- **The mini-diff showed the wrong lines.** It printed the first three lines of the
  old text followed by the first three of the new, so an edit in the middle of a
  function came out as three identical lines of context printed twice, with the
  change itself off the bottom. You were approving something you could not see.

  It is a real diff now: the two sides are aligned, only what moved is shown, with a
  line of context either side and a marker wherever untouched lines were skipped.

- **`+N −M` counted the window, not the change.** A one-character edit inside an
  eight-line context read as *"+8 −8"* — a number somebody would repeat. It counts
  the lines that actually moved.

- **`git` had no deadline.** The comment said a slow repository "must not pin a queue
  forever" and the code then called `waitUntilExit` with nothing to end it: a
  repository on a stalled network mount, or a `git` waiting on a lock somebody else
  held, took the utility queue with it, and a full pipe could deadlock the pair
  before the wait even began. It drains on another thread and kills the child at the
  deadline.

### Added

- **The characters that changed stay lit.** When one line was edited rather than
  replaced, the part that differs keeps full strength and the shared ends fade, so a
  renamed variable or a flipped comparison is one bright word instead of two lines
  that look identical.
- **A change past the right edge slides into view.** A ninety-character line whose
  only difference sits at column seventy used to truncate before it — emphasis on a
  part of the line nobody could see. Text is dropped from the front, where both
  versions agree, and the `−`/`+` pair is slid by the **same** amount so the columns
  still line up under each other.

## 1.20.0 - 2026-09-17

### Added

- **The approval card remembers what you decided.** AgentBar sits in the permission
  path — the blocking hook is its own — so it is the only thing on the machine that
  can know how often you have answered the same prompt. Until now it threw every
  decision away the moment it was made.

  Now the card says it, where you are deciding again: *"Allowed 23× here · last
  Tue"*, or *"Allowed 12×, denied 2× here"*. Counted **per repo**, because a command
  that is routine in one checkout is the opposite in another, and never shown for a
  single past decision — "allowed 1× here" is the thing you just did.

  When a prompt has been allowed five times and **never once refused**, and Claude
  Code supplied a rule for it, the existing **✓ Always** is pointed at: a heavier
  weight and a line saying it would stop the asking. Pointed at, not pressed. A count
  is not consent, and nothing here answers anything by itself.

- **How long agents waited on you.** Every decision records the seconds the agent sat
  blocked, and **Today** gains the other half of the day: *"18 answered · they waited
  34m on you"*. The history says how long the machine worked; this says how long it
  waited, which nothing else is standing in the right place to measure.

- `agentbar approvals` lists the prompts you answer most, with both verdicts and the
  day's waiting; `agentbar forget` empties the ledger and says how much it removed.

### Changed

- New protocol file `~/.agentbar/decisions.jsonl`, documented in `docs/protocol.md`.
  The shape a repeat is counted by is normalised on purpose and **carries no
  arguments** — `git push`, never `git push origin feature/PR-4113`. Arguments never
  repeat, and they are where a path, a URL or an accidentally typed secret would be.
- **Settings ▸ Approvals** can turn the ledger off; it stops new rows and deletes
  nothing, because silently destroying something somebody might want is not what a
  checkbox does.

### Fixed

- The CLI test suite failed for the first hour of every day, CI included. Two blocks
  seeded fixtures as "an hour ago", which means today at 14:00 and *yesterday* at
  00:30. The clock is now pinnable with `AGENTBAR_NOW` and those blocks pin it.

## 1.19.0 - 2026-09-17

### Added

- **What's left, not just what was spent.** The menu carries one small meter per
  provider now, answering one question and no other: how much of the window is gone
  and how much is left, with the time it starts over. No forecast, no history graph,
  no per-model table — those are different questions.

  **Codex** was already exact and is now complete. A rollout file carries more than
  one bucket — the account's windows and a `premium` one holding the credit balance —
  and which of them is written *last* is arbitrary. Reading only the newest matching
  line was enough when there was one bucket; with two, a 97 % window could read as
  nothing at all. It now walks back once and keeps the newest entry per bucket, which
  also brings the credit balance along for accounts that have one.

  **Copilot** is new here. Its own database prices every request it makes, so its line
  is what it actually charged today in its own AIU. It gets **no bar**: the
  entitlement lives on github.com, not on this machine, and a meter drawn against a
  ceiling nobody stated would be a picture of a number that does not exist. A plain
  number beside two bars says "this one has no known limit", which is the truth.

- **Claude's real windows, if you ask for them.** Claude keeps its 5-hour and weekly
  percentages on its own servers — no file under any `~/.claude*` carries them, which
  was checked twice before this was written. **Settings ▸ Usage** now has one switch
  that lets AgentBar ask for them, using the login Claude Code already stored.

  It is off until you turn it on, and it is the second network call the app can make
  — the README says so next to the first one. The token is borrowed for the length of
  one request and never kept, never logged, and never refreshed (that is Claude Code's
  job; two processes racing on one refresh token is how people get logged out). macOS
  raises its own Keychain consent dialog the first time, and a refusal, an expired
  login, a rate limit or no network all end the same way: no reading, nothing on
  screen, and the local token line stays where it was. Leave the switch off and
  nothing changes at all.

- `agentbar usage` says the same in a terminal, from the same local files. Copilot's
  ledger needs the `sqlite3` binary, and when it isn't there the command says so
  rather than leaving a gap that looks like a zero.

### Changed

- A quota window whose reset has passed now carries **no meter and no percentage**,
  only the words. Nobody has written a number since it rolled over: a full bar would
  be the last window's news, and an empty one a zero nobody measured.
- Claude Code's config directories are discovered in one place for everything that
  lives beside the transcripts, not just the transcripts themselves — the credential
  and the version marker sit in `~/.claude*` next to `projects/`, not inside it.

## 1.18.0 - 2026-09-16

### Fixed

- **Notifications stop firing after every reply.** 1.17.0 shipped a switch called
  *When an agent finishes*, and it meant something much narrower than it sounded:
  it fired on a session reaching `done`, which Claude Code does at the end of
  **every turn**. A fifty-turn conversation posted fifty banners. That switch is
  gone, and nothing is announced for merely finishing any more.

  What replaced it is a rule rather than a setting, written into the project's own
  second rule: a banner has to be something that wants an answer, or something that
  happened while you were not there to see it. Anyone who had the old switch on gets
  both of the new ones, once.

### Added

- **Three notification channels, each answering a different question.** *An agent
  needs approval* is unchanged — Allow and Deny on the banner itself. *A session
  failed* is new and rare enough to be worth interrupting for. *Everything went
  quiet* is one banner for a whole batch: it waits for nothing to be running for two
  minutes **and** for you to have been away from the keyboard for two minutes (or
  the screen to be locked), then says what the batch came to — "3 sessions · 42m ·
  1 failed". If you are sitting at the machine, the island has been telling you all
  along and a banner would only be noise on top of it.

- **The day's account has weight.** Every finished session now records what it cost,
  read out of the agent's own local files: Claude Code's transcript, Codex's rollout
  file, Copilot CLI's session store. Nothing leaves the machine and no API is called.
  The digest becomes *"12 sessions · 3h 40m · 4.1M tokens"* and a row becomes
  *"AgentBar · 34m · 1.2M · 7 files +210 −80"*.

  The seven agents that publish no such number show nothing rather than a zero, and a
  day where only some sessions could be measured says *"4.1M tokens across 8"* rather
  than passing a partial sum off as the day's spend. The four token categories are
  stored separately because the agents genuinely disagree about what a token is —
  Claude reports cache reads alongside the rest, Codex folds cached input into its
  input count — and what is *shown* leaves cache reads out. On one real session that
  choice is the difference between 2.1 M and 222.9 M.

- **What moved in the repo.** A session's record now carries how many files differ and
  by how many lines, measured from a git baseline taken when the session was first
  seen and with whatever was already uncommitted subtracted back out. It is worded as
  *changed in the repo*, everywhere, and never as what the agent did: you edit in the
  same working tree, two sessions can share one checkout, and nothing on disk can
  separate those. No baseline, no repository, or a history rewritten underneath it,
  and the row simply carries no numbers.

- **The island can carry the day along its bottom** — two switches in **Appearance…**,
  next to where the island's display and marks are chosen, and both off until you ask.
  *The day's total* is the one line the menu already shows. *A bar per session* draws
  today's finished sessions pinned above the quota line, oldest on the left, in the
  agent's own colour, red for what failed and half-lit for one nobody could time.
  They are separate because they cost different things: the line is a row of small
  text, the strip is taller and only pays for itself on a day spread across several
  sessions. The widths are square-rooted rather than drawn to scale — a real
  day is one eight-hour session and a handful of two-minute ones, and to scale the
  long one takes the whole strip and the rest vanish. Point at one for its project, duration,
  tokens and changes. The menu bar's **Today** row and `agentbar history` carry the
  same numbers as text.

### Changed

- `agentbar history` gained the two new columns and computes them itself for Claude
  and Codex, so a Linux machine with no AgentBar app still gets a full day's account.
  Copilot's numbers live in a SQLite database the dependency-free CLI cannot open, so
  a Copilot row there carries no weight — which is said out loud rather than left as
  a mystery.
- Claude transcript discovery now finds **any** `~/.claude*` directory with a
  `projects/` folder instead of the three it knew by name. The machine this was
  written on had a fourth, and every token in it was invisible to the island's usage
  line.

## 1.17.0 - 2026-09-16

### Added
- **Notifications, with Allow and Deny on the banner itself.** Off by default and
  they stay off until you switch them on — a status app must not start
  interrupting people after an update — and the surface belongs to macOS, which
  applies your own Focus rules to it. AgentBar draws nothing of its own.

  This is a deliberate exception to the project's own second rule ("nothing that
  unfolds over the screen on its own"), and what earned it was the display picker
  shipped in 1.15.0: pin the island to one screen, work on another, and there is
  no longer anywhere a pending approval can appear. The hole is new, and a banner
  is what fills it.

  The buttons land in exactly the seam the menu, the island and the global
  shortcut already use, and the request is looked up again when the button is
  pressed rather than trusted from the banner — request file names repeat across
  the tools of one turn, so by then the name may belong to a *successor* asking
  for something else. A banner is taken back down the moment its request is
  answered elsewhere or times out: two live buttons that do nothing are worse than
  no banner at all. Questions get a banner without buttons, because their answer
  is a list or free text, and tapping one jumps to the session. macOS is asked for
  permission when you tick the box, never at launch — and when macOS refuses, the
  setting says so and says where to change it. Once macOS has an app down as
  denied it never prompts again, so a checkbox that quietly sprang back would be
  indistinguishable from a dead control; that was the first version of it, and it
  was reported within a minute of being looked at. When macOS does refuse, the
  setting says so **and opens System Settings for you** — telling someone where a
  switch lives is not the same as taking them there. **Send a test** posts a
  harmless one, because a delivered notification and a *visible* one are different
  things: a Focus suppresses the banner and files it in Notification Center
  instead, which from the outside is indistinguishable from broken.

### Fixed
- **`LSUIElement` is gone from the bundle, and that is what made notifications
  possible at all.** It is the obvious thing for a menu bar app to declare, and it
  was silently costing the entire feature: macOS refuses notification
  authorization outright to a bundle that carries it — no prompt, no error worth
  reading (`UNErrorDomain Code=1`), and no entry in System Settings ▸
  Notifications to switch on. The app was invisible to the notification system and
  nothing said so.

  It bought nothing either way. `main.swift` has always called
  `setActivationPolicy(.accessory)` before the app runs, which keeps the dock icon
  away by itself — verified: the app still reports `accessory`, no icon, no menu
  bar of its own. CI now fails the build if `LSUIElement` comes back, because it
  is exactly the line someone adds in good faith.
- **A Today row in the menu, and `agentbar history`.** What finished, how long it
  took, and what failed — the question you have at the end of a day, which nothing
  in AgentBar could answer before, because live status deletes a session the
  moment its process dies. The writer has been running quietly since 1.16.0, so
  there is already something to look at.

  It stays a menu row rather than becoming a window: the project allows two
  surfaces and a dashboard is not one of them. Reachable from **both** of them —
  the menu bar dropdown and the island's **⋯** — because in island-only mode there
  is no menu bar item at all, and a digest only half the users can open is half a
  feature. Numbers are reported only as far as
  they are true — `started_at` is optional in the protocol, so a day where only
  some sessions could be timed says "30m across 1" rather than presenting a
  partial sum as the day's work, and a session a watchdog *guessed* was over is
  not counted as a clean finish.

## 1.16.0 - 2026-09-16

### Added
- **Copilot CLI answers approvals from the bar, like Claude does.** AgentBar's
  flagship trick — decide from the menu or the island and the terminal prompt
  never appears — worked for exactly one agent out of ten. Copilot's
  `permissionRequest` hook can block and decide, and was left unwired only
  because GitHub documents the output contract but not the input payload, and a
  blocking hook should not be wired on faith. The payload was logged off a live
  1.0.85 session, and it holds two traps: that event alone speaks camelCase while
  every other Copilot event arrives in the snake_case Claude dialect, and its
  `toolName` is the raw id (`bash`) rather than the remapped one. So
  `permission.js` serves both — the same file, the same wait, the same guards,
  with a decoder on the way in and a differently spelled decision on the way out.
  Every one of the 125 existing checks still passes unchanged, which is the point:
  the shared path did not move.

  There is no **Always** for Copilot, and `permissionSuggestions` is not the
  reason. GitHub's documented output is `{behavior, message, interrupt}` — no
  channel for a standing rule at all — so a rule has nowhere to go whatever that
  field contains. It degrades to a one-shot allow, and both surfaces already hide
  the button for a request that carries no rule, so nothing had to change to make
  that honest. Keystroke approval stays as the fallback for sessions started
  before the hook existed, and for ones running inside VS Code: Copilot reads hook
  config only at startup, so remote approval begins with the next session.

  Closes [#16](https://github.com/michalstrnadel/AgentBar/issues/16).
- **`agentbar doctor`, and a Diagnostics section in Settings.** Every integration
  AgentBar has fails the same way: silently. A hook that is not wired is an
  absence, not an error. A hook pointing at an interpreter that has moved never
  runs, so it never complains. A config the installer refuses to touch — it is
  your file — is skipped with one line in Console.app. Hook config is read once at
  session start, so a fix never reaches a session already running. In every case
  the symptom is "this agent doesn't appear" and there was nowhere to look.

  Both surfaces re-derive the installation from disk and answer in the words of
  the fix: node found and at a path that survives an upgrade, the protocol folders
  present *and actually writable*, hook scripts copied and their shebangs pinned,
  and per agent whether it is installed, wired, parseable, pointing at a node that
  still exists, and when it last reported. The menu row carries the verdict —
  "Diagnostics — 2 problems" — because a silent failure that waits to be looked
  for is still silent. **Copy report** puts every check on the clipboard for an
  issue. The catalogue of check ids is `docs/diagnostics.md`.
- **Sessions leave a record behind them.** `~/.agentbar/history.jsonl` keeps one
  line per ended session, because `state.d` cannot answer "when did this agent
  last report anything" — it is a live set, and a row is deleted when its process
  dies. Nothing is drawn from it yet; `doctor` reads it, and the daily digest
  will.

### Fixed
- **An approval answered the instant it appears is no longer thrown away.** The
  permission hook clears any stale answer left under its request's file name —
  the orphan of a crashed twin — but it did that *after* publishing the request.
  The app watches `requests.d` by filesystem event rather than by poll, so it can
  answer within microseconds of the request becoming visible, and an answer that
  landed inside that window was deleted by the hook's own cleanup. The hook then
  waited out its full ten minutes for a decision it had already been given, and
  the session finally fell through to the terminal prompt. Nobody can answer a
  request that does not exist yet, so the clear now happens first and the window
  is closed rather than narrowed. Caught by CI, which lost the race for real.
- **A `node` that moves no longer silently kills every hook.** The path to the
  interpreter is written into each agent's config, and that config outlives the
  next `node` upgrade — so after `nvm install 22` or a Homebrew Cellar bump the
  interpreter named in every config is simply gone. Nothing reports it: the
  hooks never run, so they never fail, and the rows just stop appearing. The
  Linux CLI has resolved a stable alias since 5d5316c; the macOS installer never
  got the same treatment and fell back to asking the login shell, which under a
  version manager answers with the version's own bin directory. It now maps that
  answer onto a stable alias whenever one names the same binary, and leaves it
  alone when none does — an nvm-only machine genuinely has no alias, and writing
  a path that isn't there would be worse than reporting the situation.
- **Codex's interpreter is re-checked instead of trusted forever.** Every other
  agent's config is rewritten whenever its content differs, so a moved `node`
  heals on the next launch. Codex was the exception: the installer stopped as
  soon as it saw its own marker, which made a stale interpreter there
  *permanent* — relaunching AgentBar, reinstalling it, re-running
  `install-hooks`, none of it rewrote that line, and only hand-editing
  `~/.codex/config.toml` brought Codex back. The marker is now read properly:
  if the interpreter inside it no longer exists, the line is repaired in place.
  A working one is still left untouched, so the install stays idempotent, and
  a `notify` key that belongs to someone else is still never taken over.

## 1.15.1 - 2026-09-16

### Fixed
- **The display row no longer runs off the window at four displays.** The tiles
  are a fixed 104pt, so five of them (four displays plus *Follow pointer*) came
  to 560pt against 480pt of window and the last one was simply cut off — on the
  setups most likely to want this feature. The row now **wraps to a second line**
  rather than shrinking the tiles: a tile small enough to fit six across is a
  tile you can't read, and that would trade a legible picker on a crowded desk
  for a tidy one-liner. Three displays and fewer look exactly as before, and no
  display is ever dropped, because one you can't see is one you can't pin the
  island to. The geometry is a pure function with tests behind it rather than
  arithmetic done on paper.

### Internal
- **The permission suite stops racing its own hook.** Sixteen tests answer the
  hook and assert what it did with the answer, but gave it only 5s to wait — so
  on a loaded CI runner it could stop waiting before the test managed to write
  the answer, and the result read as if the rule matching were broken. Those
  tests are not about the timeout and the hook exits the moment an answer lands,
  so they now wait 30s; the one test that exercises the timeout deliberately
  keeps its own short value. `wait_req` also failed silently into an empty
  variable, turning "the request never appeared" into a confusing assertion
  failure three lines later.

### Documentation
- The README shows the **Appearance** window — the display picker draws your desk
  rather than listing it, which prose is the wrong medium for. Captured from the
  running app, so the icon, the live mascot preview and the wired agent list are
  the real thing.

## 1.15.0 - 2026-09-16

### Added
- **Pick which display the island lives on.** It followed the pointer, full stop
  — right for a laptop, wrong for a fixed multi-monitor desk, where the island
  jumped to whichever screen the mouse wandered onto and a status surface that
  moves is one you have to go looking for. The welcome window now has an **Island
  on:** row that draws your displays the way System Settings does — a laptop for
  the built-in one, notch and all, a monitor on a stand for the rest, proportioned
  from each screen's real aspect ratio — and one click pins the island to any of
  them. Identity is the display's UUID, not its display ID, so a monitor unplugged
  and plugged back in is still recognised as the same one. A pinned display that
  is currently missing falls back to the pointer and says so, keeping the
  preference for when it returns: unplugging a monitor must never make AgentBar
  invisible. The row shows with a single display too, so the setting is findable
  while undocked rather than only once a second screen is attached.

### Fixed
- **The Linux CLI no longer pins hooks to a node that will move.** `install-hooks`
  wrote `process.execPath`, which has symlinks resolved — on Homebrew, nvm and fnm
  that is a version-pinned path like `/opt/homebrew/Cellar/node/25.2.1/bin/node`.
  A hook config outlives the next `node` upgrade, so the interpreter it named
  simply stopped existing and every hook silently stopped firing, which looks
  exactly like an agent that isn't reporting. It now prefers a stable path that
  resolves to the *same* binary, using the same candidate list the macOS
  installer does; where no stable alias exists it keeps `execPath`, as before.
  On macOS the app repaired this on its next launch — on Linux the CLI *is*
  AgentBar, so nothing repaired it.

### Documentation
- The README's uninstall list never mentioned Copilot, which is the easiest one
  to remove — AgentBar owns that whole file, so it is a single `rm`. The Linux
  quick start still listed the pre-Copilot agent set.
- The Linux section says how the CLI updates (`git pull`, then re-run
  `install-hooks`; nothing refreshes the hook copies behind your back the way the
  macOS app does) and which `node` path gets pinned into the configs, and why.

## 1.14.0 - 2026-09-16

### Added
- **GitHub Copilot CLI reports live status.** The long-standing blocker is gone:
  Copilot has had hooks since 0.0.396 and personal ones (`~/.copilot/hooks/`)
  since 0.0.422. Its PascalCase events deliver the Claude payload shape — tool
  ids remapped and all — so the existing `claude/` scripts serve it unchanged
  under `AGENTBAR_AGENT=copilot`, the same reuse Qwen Code gets. AgentBar writes
  its own `~/.copilot/hooks/agentbar.json` and owns only that file; Copilot loads
  every `*.json` in the directory, so your own hooks are never touched. Wired:
  session start/end, prompt, pre/post tool, tool failure, stop, and
  `ErrorOccurred` — whose `recoverable` flag is read, so an error Copilot means
  to retry no longer ends the turn early. Needs CLI 1.0.67+ and a fresh session
  (Copilot reads hook config once, at startup). Verified end to end against a
  real 1.0.85 CLI, not just the documentation: all eight events fire, the hook's
  parent really is the `copilot` process (which is what rows are pruned by), and
  a session appears and is cleaned up correctly. Remote approval stays unwired
  for now, but no longer for lack of information — the `permissionRequest`
  payload was logged from a live session and is written down in
  [`Scripts/hooks/copilot/`](Scripts/hooks/copilot/), including a
  `permissionSuggestions` field that GitHub does not document, which is what an
  "Always allow" would pin.

### Fixed
- **A failed update can no longer leave you with no AgentBar.** The relaunch
  script deleted the backup unconditionally — the three commands were separated
  by `;`, so the cleanup ran whether or not the new bundle actually opened,
  contradicting the comment right above it. It now opens the new bundle, and only
  on success removes the backup; if the new one refuses to open, the old bundle
  is moved back and launched instead, with the staging directory kept for
  inspection. Covered by the first Swift unit tests in the repo, hostile bundle
  path included.
- **Codex no longer stacks up one row per turn.** Codex has no session-end event
  and builds its row id from the thread/turn id, so every finished turn left its
  own row behind — and because a `codex` that stays open keeps its pid alive,
  the pid sweep (which is what normally retires a row) never reached them. They
  sat in the bar until the 24-hour staleness cut, several deep for a single
  session. A completed turn now retires the earlier rows belonging to the same
  `codex` process; other agents, and a second `codex` in another tab, are left
  alone.
- **The Antigravity bridge can no longer deny a tool call.** `agy` is fail-closed
  on `PreToolUse`: a non-zero exit, a crash, or stdout that isn't a valid
  decision all read as *deny*. Our bridge wrote nothing at all — one parser
  change away from blocking every tool call in the CLI. It now answers
  `{"decision":"allow"}` synchronously before doing any work, and can no longer
  exit non-zero.
- **Keystroke approval aims at the session's own tab.** Approving a Codex,
  Copilot or Antigravity prompt brought the terminal *app* forward and typed,
  which on iTerm2/Terminal.app/WezTerm could land the key in whichever tab
  happened to be open. It now waits for the tty match first and sends nothing if
  the session's tab can't be found — the same discipline plan approval has
  followed since 1.12.0. Terminals with no tab targeting (Warp, Ghostty, kitty)
  keep the app-level behaviour.
- **A session that opens mid-prompt no longer seeds itself hidden.** Copilot
  fires `SessionStart` and `UserPromptSubmit` concurrently, and `SessionStart`
  can land second — measured ~100 ms behind. The seed then overwrote a working
  row with `idle`/`started:false`, and `started:false` hides a row from every
  frontend: the session vanished from the bar at the moment it began working.
  A session that opens with a prompt already in flight is working the instant it
  exists, so it is no longer seeded as "not started yet". Claude is unaffected —
  it never sends the field this keys on.

### Build
- **`./Scripts/build.sh --native`** builds for this Mac alone. Recent Command
  Line Tools ship `libswiftCompatibility*.a` for arm64 only, so a machine
  without a full Xcode can no longer link the x86_64 half of the universal
  build — which left a developer unable to produce a bundle they could run, and
  the hook scripts are refreshed from the app bundle on every launch, so a hook
  fix cannot be exercised until the app is rebuilt. Releases stay universal.
- **CI keeps the universal bundle it already builds.** A release asset has to be
  universal *and* signed with the identity that lives in one keychain, and those
  two requirements no longer fit on one machine. CI now publishes the verified
  bundle as an artifact; the release is cut by signing it locally.

### Documentation
- The README claimed the island steps aside for fullscreen windows; it has
  deliberately done the opposite since the island shipped — a fullscreen terminal
  is exactly where the agents run.
- The cloud poller's README said Devin had no per-session deep link, while the
  adapter has always built one (`devin://acp/session`), and omitted `orgId`,
  which `cog_` keys require for the org-scoped v3 API.
- `docs/testing.md` covers the new Swift suite, why it uses swift-testing rather
  than XCTest (it runs without a full Xcode), and the two local build caveats.

## 1.13.0 - 2026-09-06

### Added
- **Cloud agents in the bar.** Cursor cloud agents, Devin sessions, and Codex
  cloud tasks — runs with no local pid, tty, or hook — now appear as first-class
  rows via the optional [`Scripts/cloud/`](Scripts/cloud/) poller (zero-dep
  Node, launchd, `install.sh`). The protocol grows two additive fields:
  `entrypoint: "cloud"` and `url` — a cloud row's click opens the run where it
  lives (the `cursor://` run deep link; the exact thread in Devin Desktop via
  its ACP URL handler, which itself falls back to the web thread; the task on
  chatgpt.com), never a terminal, and cloud rows never grow approval
  affordances. Vendors fail independently: a broken key collapses to one
  clickable "check API key" row without touching the other vendors' rows.
  Finished runs linger briefly and age out (`retentionMinutes`); Devin's
  auto-suspended threads show as idle within their own window. A row click only
  follows web and vendor schemes — any state file can name a `url`, and opening
  an arbitrary local path with its default app is not what a row click is for.
  Devin joins the agent roster with an original D letterform mark. — thanks
  @emigal (#14)
- **Activity feed.** The island hero shows the turn's recent tool steps as a
  quiet breadcrumb ("Reading · Searching · Editing") while the session works —
  the last item of the island plan's content-parity phase. Carried as the
  optional, additive `activity` field in the state protocol (≤ 5 short labels,
  consecutive duplicates collapsed, reset on each new prompt like `recap`).
- **Menu rows say who and how long.** Each session row in the dropdown carries
  its agent's mark (the same glyphs the Open submenu uses) and the session's
  elapsed time next to the state text.
- **Test coverage and a testing guide.** A new `opencode-plugin-test.sh` drives
  the OpenCode plugin through its event bus (23 checks); the bridge, CLI and
  permission suites gained lifecycle, plan, waybar and hookPid coverage —
  227 checks in all, on Linux and macOS in CI. `docs/testing.md` explains what
  each suite covers, the env knobs, and how to add a test.
- **The Linux CLI wires Qwen Code and OpenCode.** `agentbar install-hooks` now
  covers the same seven tools the macOS installer does: Qwen's Claude-style
  hooks land in `~/.qwen/settings.json` (failure events included) and the
  OpenCode plugin is copied to `~/.config/opencode/plugins/agentbar.js`.
- **waybar shows questions.** A session waiting on an `AskUserQuestion` gets its
  own module class (`question`) and `❓ n` text instead of hiding inside "idle".
- **Answers name their hook.** Answer files may carry the request's `hookPid`,
  and the hook ignores an answer aimed at an earlier request that shared the
  file name; frontends that omit the field keep working (`docs/protocol.md`).

### Fixed

Found by an adversarial review pass over the whole repository; every hook fix
is covered by a test that fails on the old code.

- **Starting Cursor could wipe other agents' live sessions.** Its bridge's
  stale-file sweep deleted every state file whenever no frontend was running,
  instead of probing each file's pid the way the Claude and Gemini bridges
  already did.
- **The Antigravity bridge's app-launch condition was inverted** — it launched
  AgentBar only when one was already running (the two-copies LaunchServices
  hazard) and never when it was down. The Cursor and Gemini bridges also
  launched unconditionally on every session start; all three now launch only
  when nothing is running.
- **An emoji at a cut point could hide a session or block an approval.** The
  permission hook's 4 KB input preview and the codex/cursor/gemini/opencode
  one-liners truncated mid-surrogate-pair; Swift's `JSONSerialization` then
  rejected the whole file — an unreadable request blocks the approval until its
  600 s timeout. Every cut is surrogate-safe now, and Codex state file names
  respect the protocol's 64-char cap.
- **Resume, /clear and auto-compact no longer reset a session.** SessionStart
  merges over the existing state file (the protocol's own rule): `started_at`
  stops jumping (elapsed time survives), prompt/model/recap ride along, and a
  compact mid-turn no longer hides a live row behind `started: false`.
- **The open dropdown could answer a request it wasn't showing.** Request file
  names repeat across the tools of one turn, and the menu keyed strips by name
  alone — a replaced request looked like "no change", so the displayed Allow
  answered the new request while showing the old command. Strips are keyed by
  request identity now, with the `hookPid` echo above as the protocol-level
  second lock.
- **A poisoned state file can't crash-loop the app.** `pid`/`hookPid` decode
  via `Int32(exactly:)` instead of a trapping conversion — an out-of-range pid
  from a third-party writer used to crash every refresh, relaunch included.
- **No celebration for a guess.** The mascot's finish hop now skips
  watchdog-decayed Antigravity sessions, as the sound cue always did; the
  welcome window's preview stops its animation timers when it closes (they used
  to tick at 12.5 fps forever); and the island notices prompt/model changes
  that land mid-state, so a queued prompt renames its row immediately.
- **Antigravity desktop rows die with the app.** The watcher stamps the app's
  pid, so quitting Antigravity clears its sessions instead of waiting out the
  24 h prune. The installer's wired-hooks list also stopped racing the welcome
  window (main-queue only), and the CLI writes `~/.codex/config.toml`
  atomically.
- **The docs tell the truth again.** The installer's consent summary, the
  README's two install-footprint blocks and Uninstall all agree with what is
  actually installed (Antigravity/Qwen/OpenCode included);
  `THIRD_PARTY_NOTICES.md` covers all eight agents; and the design docs'
  status notes match the shipped app instead of contradicting it.
- **A dropped folder watch comes back.** If re-opening `state.d`/`requests.d`
  failed at the moment the directory was replaced, fs-event responsiveness
  silently degraded to the 2 s poll forever; the poll now re-arms the watch.
- **The global Allow chord can't tick success over a plan.** With the session
  gone from the store, a hotkey "allow" on an `ExitPlanMode` request used to
  play the confirm tick while the hook (per protocol) swallowed the answer.
- **Bridge hooks keep the project across events.** An Antigravity, Cursor or
  Gemini event that carries no workspace/cwd (PostToolUse, Stop, AfterAgent)
  used to blank the row's project; they merge the previous value now, per the
  protocol's merge rule. Found by the new bridge lifecycle tests.
- **Update fallback URL respects the release's real tag.** The downloader no
  longer hardcodes a `v` prefix when a release lacks the `AgentBar.app.zip`
  asset — a release tagged without one used to 404 as "Download failed".

## 1.12.0 - 2026-08-18

### Added
- **Plan review on the island.** When Claude finishes planning (`ExitPlanMode`),
  the request card now carries the whole plan, rendered as formatted Markdown —
  headings, bullets, inline and fenced code — in a box that scrolls when the
  plan is long. **Keep planning** answers through the hook as an explicit
  keep-planning message (a bare denial reads as "stop" and ends the turn —
  found out the hard way, live). **⌨ Approve plan** is honest about its
  mechanics: Claude Code ignores a hook allow at the plan dialog (the approval
  also picks the next permission mode), so the button focuses the session's
  exact tab and selects "manually approve edits" in the dialog itself, the way
  Codex approvals already work. Answering the dialog in the terminal retires
  the card within ~2 s. The menu gets the same buttons plus an 8-line preview,
  and the CLI prints the plan under `agentbar requests`.
- **Multi-question calls became a wizard.** A 4-question card used to stack
  everything at once and run past the screen edge. The island now shows one
  question at a time with a quiet "2/4" mark: tapping a single-select answer
  records it and slides to the next question, the last answer submits the whole
  set (four questions = four taps), multiSelect steps toggle and move on with
  **Next**, and **‹ Back** revisits earlier steps — recorded choices stay
  checked. Option descriptions are always visible now, since one question at a
  time has the room.
- **The island scrolls when it must.** Content taller than the screen used to
  clip at the bottom edge; the panel now sizes to its content as before, but
  past the screen limit the rows scroll (overlay scroller, wheel and trackpad).
- **Usage at a glance.** A quiet line in the island footer and the menu shows
  provider quota, read from the CLIs' own local files — no network, no
  keychain, nothing leaves the machine. Codex rollouts carry exact
  `used_percent` for the 5-hour and weekly windows plus reset times; Claude
  transcripts yield the token count of the current 5-hour block. Stale data
  (agent not run for a day) silently disappears rather than showing a
  months-old window as current.
- **Precise jump-back.** Clicking a session row now selects the exact terminal
  tab or split pane the session runs in — iTerm2 (window ▸ tab ▸ pane),
  Terminal.app (tab), and WezTerm (pane), matched by the session's tty. The
  app-level focus still fires instantly; the tab selection follows as soon as
  the terminal answers (first use asks for Automation permission). Warp,
  Ghostty, and kitty stay app-level — they expose no tab targeting.
- **A failed turn now says so.** The protocol gained an `error` state beside
  `done`: same "the turn is over" meaning, but rendered red and named ("failed
  — provider returned 429") instead of a green tick, and it never plays the
  done chime. It sorts above the clean "Done" rows so a failure can't be buried
  under them, and below live work so it can never take the mascot from an agent
  that is still going. Qwen's `StopFailure` and OpenCode's
  `session.error` report through it; writers that can't tell success from
  failure keep using `done`, and frontends that predate `error` read it as
  idle.
- **Two new agents: Qwen Code and OpenCode.** Qwen Code speaks Claude-style
  hooks, so AgentBar wires its existing scripts into `~/.qwen/settings.json`
  (status only for now — remote approval waits until Qwen's decision contract
  is verified). OpenCode gets a native plugin in `~/.config/opencode/plugins/`
  that mirrors its event bus: working, waiting for approval, done, and the
  session title as the row's task line. Both install automatically when the
  tool is present, and both get original marks drawn for AgentBar — a Q ring
  with a tail, and a terminal chevron with a block cursor.

### Fixed

Everything below was found by adversarial review passes over this release's
own work and reproduced before being fixed.

- **A lingering hook could delete the next request of the same turn.** Request
  files are named `<session>-<prompt>`, and prompt ids repeat across the tools
  of one turn. That was harmless while every hook exited the moment it got an
  answer — but the plan and question hooks now outlive theirs by up to ~2s, and
  in that window Claude's next tool writes the same path. The old hook's exit
  deleted it, stranding the session on a prompt nobody could answer. Every
  destructive move now checks the file is still the hook's own.
- **A stalled stdin could freeze a tool call for a minute.** `update.js` did all
  its work in the stdin `end` handler with no error listener and no self-timeout,
  so a pipe that never reached EOF parked it until Claude Code's 60s hook
  timeout. Its sibling hooks have carried those guards all along.
- **SessionStart deleted other agents' live sessions.** With AgentBar down it
  wiped `state.d` wholesale as "stale from a prior crash" — but the app being
  down is the normal path there (that hook is what launches it), and a Codex or
  OpenCode session outlives an AgentBar restart. It now probes each file's pid.
- **Approving a plan could answer the wrong one.** The keystroke was posted as
  soon as the terminal came forward (~50ms), while the tab select takes
  hundreds — so it landed in whatever tab was already open, which in the worst
  case was a second Claude session at its own plan dialog. The keystroke now
  waits for the tab select to confirm it found the session, and terminals with
  no tab targeting hand the dialog over instead.
- **The quota line was wrong twice over.** Split configs are commonly symlinked
  to one another, so transcripts were enumerated twice and every token counted
  twice; meanwhile a 2 MB tail read never reached the start of a long block.
  Reads are now incremental over append-only transcripts, and the figure matches
  an independent full-file count exactly.
- Truncation never ends on a lone surrogate any more: `JSON.stringify` escapes
  one happily, but Swift's `JSONSerialization` rejects the whole file, which hid
  the session from every frontend for the rest of the turn.
- The global Allow shortcut routes plans through the same path the buttons use,
  instead of writing an allow the hook must swallow and ticking success anyway.

## 1.11.0 - 2026-08-18

### Added
- **Claude's questions are answerable from the island, the menu and the CLI.**
  When Claude asks a multiple-choice question (`AskUserQuestion`), the row used
  to say "Claude asks" and the only move was jumping to the terminal. The
  permission hook now carries the question's options in the request file and
  waits alongside the terminal wizard: the island shows the actual options as
  tappable cards (multiSelect and multi-question calls get toggles and an
  Answer button), the menu answers single-choice questions inline, and
  `agentbar watch` answers them with a digit key. Whoever answers first —
  terminal or AgentBar — wins; the other side's answer is ignored cleanly
  (verified both directions on Claude Code 2.1.234). A remote answer can only
  say things the request itself offered: forged labels degrade to the terminal
  wizard, never to a made-up answer.
- **Done rows say what finished.** The Stop hook stores one line of the agent's
  closing words in the state file, taken from the Stop payload's
  `last_assistant_message` (the transcript flushes the final text only at
  session end, far too late to read back); a bounded 64 KB transcript tail
  stays as the fallback for versions that don't carry the field. The island hero shows it under the
  green "Done" — "You: …" asks, "Claude: …" answers — menu rows carry a
  60-char snippet plus the full line in the tooltip, and a new prompt clears
  it so a working session never advertises the previous turn's result.
- **Sound cues, off by default.** Four tiny synthesized retro-console motifs —
  a falling knock for *needs approval*, a rising "hm?" for *questions*, a
  rising arpeggio for *done*, and a click when an answer reaches disk. No
  audio files: the waveforms are generated in code, band-limited so they stay
  soft. Edges only (a burst of sessions finishing plays once), silent while
  the screen is locked, and the whole thing stays off until you enable it in
  Settings or the one-click **Sounds** menu toggle.
- **Settings grew into three quiet sections** — Sounds (enable, volume with an
  audition on release, Test), Shortcuts (as before), and Island: an opt-in
  **Hide island when no sessions** that lets the pill slip away when nothing
  runs and return with the next session (honored alongside the menu bar mark,
  so island-only mode never loses its only surface).
- **Cowork sessions get recaps too.** The desktop app's audit log carries the
  turn's closing words in its result event; the watcher now writes the same
  `recap` field the Claude hook does, so a finished Cowork row also says what
  it finished — link text kept, since Cowork results end with a link whose
  text names the deliverable.
- `agentbar answer [n] <label|num>…` answers a pending question from a plain
  shell — labels case-insensitively or by option number, several for
  multiSelect, and a wrong label lists the real choices. `agentbar watch`
  gained `A` for *always*, `f` for *defer* and digit keys for question
  options, alongside the existing allow/deny; session lines show elapsed
  time. A question at the head of the queue never shadows a pending
  permission: letters answer the newest permission, digits the newest
  question.
- The open island's elapsed labels keep counting (a slow 30s tick) instead of
  freezing at the moment the panel was built.

### Fixed
- **An approval that fails to reach disk no longer looks like it worked.**
  Writing your Allow/Deny answer was fire-and-forget: if the write failed —
  unwritable `~/.agentbar/answers.d`, full disk — the row cleared as if the
  click had landed, while the hook went on polling for the full ten-minute
  timeout before falling back to the terminal prompt. The write now reports
  success, the island only flashes "✓ Allowed" once the answer is actually on
  disk, a dropped answer beeps and leaves the request pending and answerable,
  and *Approve in terminal* only jumps you to the prompt once the hook can
  really see the hand-off.
- **Keystroke approvals can no longer land in the wrong app.** The Codex /
  Copilot / Antigravity keystroke path used to bring the target forward, wait a
  fixed 0.7 s, and then type regardless of what was actually frontmost — so a
  slow cold start, or an app that never launched, sent Return into whatever you
  happened to be looking at. It now polls for activation up to 2 s, verifies the
  intended app owns the keyboard before *every* key, and abandons the attempt
  rather than typing blind. Modifier flags are cleared on each event, so a held
  Cmd can't turn Return into Cmd+Return, and multi-key mappings are staggered so
  Copilot's "y" + Return doesn't drop the Return.
- **A config that exists but can't be read is no longer treated as absent.**
  `HookInstaller` collapsed every read failure into "fresh install", so a
  momentarily unreadable `settings.json` — a permission glitch, another process
  holding it — could be rewritten with only AgentBar's hooks in it. Unreadable
  now gets the same protection unparseable already had: skip, log, never
  overwrite.
- **One failing hook installer no longer skips the rest.** All six ran in a
  single block, so a throw while wiring Claude silently left Codex, Cursor,
  Gemini and Antigravity unwired for that launch, behind one generic log line.
  Each step is isolated and named in its log now. Missing-Node also stopped
  being silent for Codex, Gemini, Cursor and Antigravity — only Claude used to
  say so.
- **Malformed hook input exits immediately instead of blocking for ten minutes.**
  `permission.js` short-circuited only on completely empty stdin; anything
  present but unparseable became `{}` and still opened a request, showing a
  garbled "unknown" row and holding the session for the full timeout.
- **Update installs stop littering, and failures say why.** Staging directories
  and the backup bundle survived every update, quietly accumulating a full app
  copy each time; they're now swept once the new bundle has opened — after the
  rollback window, never before. Check and download failures log the underlying
  reason (offline, TLS, rate limit) instead of only showing "Update check
  failed".
- **Sessions whose state file can't be parsed are logged.** A torn or corrupt
  JSON write used to make a session simply invisible, indistinguishable from
  "nothing running". Logged once per file, not once per poll.
- **Hooks report a broken state directory.** Every state write swallowed its
  error, so an unwritable `~/.agentbar/state.d/` produced silence and no
  diagnostics anywhere. Each hook now warns once per process, on stderr only.
  Clearing stale state on start says how many files it removed.
- **The Linux CLI wires Antigravity.** `agentbar install-hooks` copied the
  Antigravity hook script but never referenced it from any config, so it sat
  there doing nothing while macOS wired it properly.

- **The menu bar mark keeps its place across island↔bar switches.** macOS
  deletes a status item's remembered position the moment the item is hidden
  (verified on macOS 26), so every return to the menu bar re-inserted the mark
  at the far left — which is the *hidden* section under menu bar managers like
  Ice. AgentBar now stashes the slot before hiding and restores it before
  showing, so the mark comes back exactly where you left it.
- **Only one AgentBar runs at a time.** A dev build launched next to the
  /Applications install used to fight it over the same island — two panels in
  the same spot, and whichever happened to be stacked on top won, so fixes
  appeared and disappeared at random. A newly launched copy now asks any other
  running AgentBar to quit and takes over.
- **The Color choice is reachable without the menu bar.** System/Color used to
  live only in the status item dropdown, so Island-only mode had no way to
  switch it. It now sits in the island's ⋯ menu and in the Appearance window
  (with the live preview showing what each mode looks like), and changing it
  anywhere repaints every surface immediately.

### Changed
- Every island row carries its agent's mark now, not just the hero — the mark
  says *who*, the coloured dot keeps saying *what state*, and all row text sits
  on the hero's column.

## 1.10.2 - 2026-07-29

### Fixed
- **The island opens on arrival, not on presence.** Opening now requires the
  pointer to actually *travel* into the notch zone — a pointer that was already
  parked there (reading a tab title, left behind by a Space switch) opens
  nothing. Push up → 0.3 s dwell → open; leave → 0.35 s grace → close. The pill
  itself is a hover target again too, which is what makes the floating pill on
  notch-less displays openable at all.
- **The pill tucks fully inside the physical island.** Drawn a hair narrower
  than the notch (its width − 10 pt), so its corners no longer poke out past
  the notch's curved bottom edge. Every size still comes from the screen's own
  reported geometry at runtime — each MacBook's notch, any scaling mode, gets
  its own numbers, and displays without a notch keep the centred floating pill.
- **Rows never wrap.** A long task name used to wrap to a second line inside
  the fixed row height, shoving the mascot half out of view and tearing the
  panel apart. Every row label is a single truncating line now.

### Changed
- **Builds sign with a stable identity, so macOS finally remembers.** TCC keys
  permission grants to the code-signing identity, and an ad-hoc signature is a
  brand-new identity every build — that is why the "Documents access" dialog
  kept coming back. `build.sh` now signs with a local `AgentBar Local Signing`
  certificate when one exists (ad-hoc fallback without it), release builds
  share that certificate, and grants survive rebuilds and cask upgrades alike
  (#9). CONTRIBUTING shows the one-time cert setup.

## 1.10.1 - 2026-07-29

### Added
- The README shows both surfaces now: a second demo GIF walks the Dynamic Island
  flow — the pill under the notch says *approve?*, the panel inflates out of the
  notch with the mini-diff, one click on Allow, and the pill flashes ✓ Allowed.
  Generator checked in as `Scripts/demo/demo-island-gif.swift`, reading mascot
  frames from the shipped sprite sources like the menu-bar one.

### Fixed
- **The pill has one width — the notch's own — and never resizes.** Sizing it
  to its content made it reshape with every rotating verb and every
  working↔done flip, an animated wobble in the corner of the eye that read as
  the island opening and closing all day. Text now swaps in place inside the
  fixed shape and truncates when long.
- **The island opens from the notch now, and the pill is click-through.** The
  pill floats exactly where a maximized window keeps its tab strip, so opening
  on pill-hover flapped the panel open and shut the whole time the pointer
  worked a browser's tabs — and the pill ate clicks meant for them. Opening now
  means pushing the pointer up into the notch strip itself (the menu-bar band,
  where no app content ever lives; the screen edge makes it the easiest target
  there is), and the collapsed pill passes clicks straight through to whatever
  is under it. Hover truth comes from a lightweight pointer poll, which also
  cures two staleness bugs: state-file ticks bypassing the open-dwell and
  close-grace timers, and a Space switch landing the panel on the new desktop
  fully open because no enter/exit event ever fired.

## 1.10.0 - 2026-07-29

### Added
- **The protocol now carries the task, its age, and the model.** Three new
  optional `state.d` fields — `started_at` (unix seconds, set once and preserved
  on every merge), `prompt` (the latest user prompt, one line, ≤ 120 chars) and
  `model` — written by the Claude, Codex, Cursor and Gemini hooks and both
  watchers where each can know them. Optional means optional: old state files,
  the Linux CLI, the Windows port and third-party writers stay valid unchanged.
  On the island this turns into what the reference panels show: the hero row
  gains a "You: fix the auth bug in middleware" line, compact rows are named by
  their task instead of just the repo (repo stays in the tooltip), and the chips
  gain the model and a quiet elapsed "28m". System-injected turns and slash
  commands never become the task name — only real prompts do. Running sessions
  pick the fields up on their next event.
- **AgentBar can live as a Dynamic Island.** A small pill under the notch showing
  the working agent's mark and what it is doing, with a count once two or more
  sessions are live. Point at it and it opens into the full session list, with any
  waiting approval answerable in place — same mini-diff as the menu, Allow and Deny
  in front. It never opens on its own, follows the screen your pointer is on,
  falls back to a floating bar on displays without a notch, steps aside for
  fullscreen windows, and never takes focus from your editor. In Island-only mode
  the panel's `⋯` button carries Appearance, the Allow/Deny shortcut, updates and
  Quit, so the app is always reachable.
- **The island panel reads like a proper agent panel now.** Whatever needs you
  leads as a boxed hero row — mark, bold project name, a coloured status line
  ("needs approval", "Claude asks", "Done — click to jump") — with the other
  sessions as quiet one-liners below, attention-first. A waiting approval is a
  full *Permission Request* card: tool and target line, the mini-diff with
  +N −N counts, Deny / Allow in front. An AskUserQuestion gets a *Claude asks*
  card naming the question. Answering flashes the choice back in the pill —
  "✓ Allowed" — as the panel folds away, and every open, close and resize is one
  slow spring instead of a snap: the shape inflates from the notch's centre and
  reveals the rows as it grows, with the drop shadow recut by the window. Opening
  takes a short hover dwell, so a cursor merely crossing the pill — a Cmd-Tab
  flick, a click on a window title bar — doesn't unfold it. The panel is solid
  black: translucency read as the window behind showing through the notch.
- **A welcome window on first launch**, with the surface picker — Menu bar,
  Dynamic Island, or Both — over a live preview drawn by the real mascot renderer,
  and a line naming the agents whose hooks were just wired. Reachable afterwards as
  **Appearance…**; switching modes takes effect immediately, no relaunch.
- Real screenshot of the remote approval menu in the README (#6).
- The README demo GIF generator is checked in as `Scripts/demo/demo-gif.swift`
  (#10); it reads mascot frames from the shipped sprite sources, so the GIF can
  be regenerated after any sprite change.
- **Claude Cowork sessions now show up.** Cowork (the agent mode in the Claude
  desktop app) is watched directly instead of through hooks: `CoworkWatcher`
  reads the audit log the app writes for every session and reports working,
  "needs approval" (with the tool being asked about), AskUserQuestion and done.
  Rows are anchored to the Claude app's pid, so quitting Claude clears them, and
  a click focuses the app where the prompt lives. **Caveat, found after the fact:
  newer desktop builds run Cowork inside a VM whose session files never touch the
  host, and those sessions cannot be shown** — this covers the older host-side
  "local mode" only. Documented in the README; nothing to fix on AgentBar's side
  until the app exposes session state to the host again.
- Integration test for the Antigravity liveness watcher
  (`Scripts/test/antigravity-watcher-test.sh`): synthetic turn transcript walks
  thinking → permission → done against the running app, now for both the
  desktop and the CLI brain root.
- Integration test for the Cowork watcher
  (`Scripts/test/cowork-watcher-test.sh`): a staged session walks thinking →
  permission → thinking → question → done against the running app, including a
  multi-megabyte audit line.
- README troubleshooting entry for the Homebrew version drift: updating through
  the in-app updater leaves brew's install record on the old version until
  `brew upgrade --cask agentbar` re-syncs it. The tap's own README now documents
  install, upgrade, the quarantine postflight, and how the cask tracks releases;
  the CONTRIBUTING release checklist spells out the cask bump (sha256 +
  `brew audit`).

### Fixed
- The island is visible over fullscreen apps. It was originally meant to step
  aside there; that was the wrong call — a fullscreen terminal or editor is where
  the agents actually run, so it is the last place the island should vanish from.
- An approval row for an agent that writes no request file used to say "Can't
  show the request" and offer "Open in terminal" even when the session lives in
  an app. It now names the tool being asked about and offers "Answer in
  Claude" / "Answer in Antigravity" for app-hosted sessions.
- Antigravity CLI (`agy`) sessions never appeared in the menu. The liveness
  watcher only scanned the desktop app's `~/.gemini/antigravity/brain`, while
  the CLI keeps its own tree under `~/.gemini/antigravity-cli/brain` — and the
  CLI loads `hooks.json` but never runs the handlers, so there was no second
  source of state either. Both roots are scanned now. CLI rows resolve their
  project from the CLI's `history.jsonl`, and their terminal and pid from the
  live `agy` process, so a row click focuses the hosting terminal instead of
  the desktop app and the row disappears when `agy` exits.

## 1.9.0 - 2026-07-24

### Added
- Antigravity approval flow (#2): a session waiting on Antigravity's own
  permission dialog flips to "needs approval" (amber dot) within ~6 s — the
  turn transcript's last entry is an unexecuted tool request while the dialog
  is up. The session row carries the same inline button strip as Claude:
  Allow brings the app forward and submits the dialog's preselected option
  (Return); Codex/Copilot permission rows get the identical strip instead of
  the old keystroke submenu. Requires the Accessibility permission.
- Instant end-of-turn detection for Antigravity: the final model response in
  the turn transcript flips the session to done immediately; the 90 s decay
  stays as a fallback for cancelled turns.
- Antigravity liveness watcher: the desktop engine fires no hook at all for
  chat-only turns, so the app also watches conversation-database mtimes under
  `~/.gemini/antigravity/conversations/` and upserts the same state files the
  hooks write (hooks stay authoritative; quiet sessions decay to done).
- Google Antigravity live status (#7, #2): an observe-only hook bridge
  (`Scripts/hooks/antigravity/antigravity.js`) auto-wired into
  `~/.gemini/antigravity/hooks.json` and `~/.gemini/antigravity-cli/hooks.json`
  under a dedicated `"agentbar"` rule group. Verified against desktop 2.3.1:
  the payload carries no event name (passed as an argument instead), only
  per-workspace `.agents/hooks.json` is honored, and only `PostToolUse` fires —
  so working sessions with no events for 90 s decay to done.
- Multi-agent menu bar: when two or more agents have live sessions, the bar
  shows their marks side by side (no status words) — working agents animate,
  a waiting one carries the amber/blue dot. Single-agent behavior unchanged.
- Antigravity mascot now matches the Codex layout language: the official pixel
  arch plus a twinkling braille-style dot cluster in Google blue.
- Settings window (the app's only window) for the global Allow/Deny shortcut:
  enable it and record custom key combos for Allow and Deny (defaults stay
  ⌥⌘A / ⌥⌘D). The menu row now opens Settings instead of blind-toggling; its
  tooltip shows the active combos. Recording temporarily suspends the live
  hotkeys so the current combo can be re-recorded, Esc cancels, and a combo
  must include ⌘/⌥/⌃; Allow and Deny can't share one combo.

### Fixed
- Antigravity liveness reads the per-turn transcript, not the conversation
  databases — background housekeeping kept idle sessions animating forever.
- Open dropdown no longer grows a blank band at the bottom when a session ends
  or an approval resolves while the menu is showing. Root cause: an open
  NSMenu window never shrinks, and the live refresh rebuilt the menu from
  scratch on every change. The refresh now reconciles rows in place — surviving
  rows update, vanished sessions dim to an "ended" row, resolved approval
  strips fade with their buttons disarmed — and a full rebuild happens only
  for growth (new session / request), which an open menu renders fine. Rebuilds
  are also skipped while any submenu is showing (replacing items would orphan
  it) and when nothing visible changed, so the menu never flickers for a no-op.

### Changed
- Rotating thinking verbs (Pondering…, Cooking…) appear only next to Clawd —
  the other agents' dot clusters carry the working signal on their own.
- Antigravity desktop session rows (and their approval strip) focus the
  Antigravity app instead of a terminal.
- Cursor and Gemini menu bar marks replaced with the current official app icons
  (Cursor's cube from cursor.com, Gemini CLI's gradient "&gt;" from
  geminicli.com), shown full-color with the bob animation instead of a
  flat-tinted glyph. In System (template) mode the Cursor icon renders as a
  knockout — ink plate with the cube cut out — via a new `appIconMark` artwork
  style. Menu dot colors follow: Gemini uses the icon's blue (#1A80FD), Cursor
  adapts to the menu appearance.
- Menu polish: `Open` and `Color` rows carry icons so the section shares one
  icon gutter, and the Open submenu's agent marks are drawn centered on one
  shared canvas at full resolution — identical bounds, no per-row jitter, and
  the Cursor/Gemini marks now match the mascots' solid weight.

### Fixed
- The CLI test suite no longer inherits `CLAUDE_CONFIG_DIR` from the runner's
  shell — it used to wire the runner's real Claude config to the suite's
  throwaway temp dir, breaking hooks after the temp dir was cleaned up. The env
  is sanitized and a contained `CLAUDE_CONFIG_DIR` regression test was added.

## 1.8.0 - 2026-07-24

### Added
- Linux support via the `agentbar` CLI (`Scripts/cli/agentbar`, plain Node, no
  dependencies): `status`, `requests` (with the inline mini-diff / full command),
  `approve [--always]` / `deny`, `watch` (live view with a/d/q keys), `waybar`
  (JSON for waybar/polybar modules), and `install-hooks` — the Linux counterpart
  of the macOS hook installer, with the same safety rules (never touches an
  unparseable config, writes only on change, pins the Cursor shebang to an
  absolute node).
- Remote Allow/Deny without the macOS app: hooks now also block when a CLI
  watcher heartbeat (`~/.agentbar/watcher.json`, refreshed by `watch`/`waybar`,
  60 s TTL) is fresh — so `agentbar watch` on Linux answers Claude Code
  permission prompts exactly like the menu bar does on macOS.
- `docs/protocol.md`: the `~/.agentbar` file protocol as a normative, OS-neutral
  contract (schemas, atomicity, pruning rules, presence) — any frontend or agent
  bridge can be written against it.
- Test suite for the CLI (`Scripts/test/cli-test.sh`, 17 checks) covering
  listing, pruning, answers, the heartbeat→blocking-hook flow end-to-end, and
  installer safety.

### Changed
- Hook bridge scripts are platform-clean: macOS-only bits (`open`,
  `pgrep -x AgentBar`) are guarded by platform checks; everything else already
  ran on Linux unchanged.

## 1.7.1 - 2026-07-24

### Fixed
- Hook installer: a config file that exists but is not parseable JSON (comments,
  trailing comma, torn write) is now left untouched and logged, instead of being
  silently replaced with only AgentBar's hooks. Applies to Claude `settings.json`,
  `~/.cursor/hooks.json`, and `~/.gemini/settings.json`.
- Cursor hook: the bridge script's shebang is pinned to the resolved absolute
  `node` path at install time. A GUI-launched Cursor inherits the launchd PATH
  (often without `/opt/homebrew/bin`), so `#!/usr/bin/env node` could silently
  never fire.
- Installer consent: `curl … | bash` now really asks "Continue? [Y/n]" by reading
  from the controlling terminal (stdin is the script itself in that mode). With no
  terminal at all (CI), it proceeds as before; `AGENTBAR_YES=1` still skips.
- Gemini: `BeforeAgent` is now registered, so a turn that uses no tools shows
  "thinking" instead of jumping straight to done.
- Re-running the installer without `CLAUDE_CONFIG_DIR` set clears a previously
  recorded custom dir, so hooks stop being wired into a stale location.
- A branch checkout now refreshes the session row while the menu is open (the
  change-detection snapshot ignored project/branch).

### Changed
- Agent configs are only rewritten when their content actually changes — no more
  mtime churn on every launch for tools that watch their config files.
- `node` is resolved once per launch instead of once per agent (up to 4 login-shell
  probes on nvm/fnm setups).
- Cursor now also registers `afterAgentResponse`, so "done" shows right after a
  response, not only at the end of the agent loop. The bridge's event map matches
  exactly what gets registered; permission-gating `before*` hooks stay untouched.

## 1.7.0 - 2026-07-23

### Added
- Live-updating menu: the open dropdown now reflects state as it changes — a
  finished command clears its spinner, a new permission request makes the
  Allow/Deny strip appear, answered requests disappear — without reopening.
- Richer approval context: Claude Code permission rows show what you're approving
  inline — a −old/+new mini-diff for Edit/MultiEdit, the full command for Bash, a
  preview for Write — instead of only a hover tooltip.
- Global Allow/Deny shortcut (opt-in): ⌥⌘A allows and ⌥⌘D denies the newest pending
  request without opening the menu. Off by default; toggle in the menu. No
  Accessibility permission required.
- Cursor CLI and Gemini CLI support: live working/done status via their hook
  systems (`~/.cursor/hooks.json`, `~/.gemini/settings.json`), auto-wired at
  launch (idempotently) for the tools you have. Each gets its own menu mark
  (pointer, spark).
- Mascot micro-animations: idle is calm, working walks, and a task finishing gives
  a brief celebratory hop.

### Changed
- The installer now honors a custom `CLAUDE_CONFIG_DIR` (previously it only wired
  `~/.claude`, so custom-config users silently got no hooks — issue #4).
- The installer prints exactly what it will change before doing anything, and the
  README leads with that footprint. Nothing is touched for tools you don't use.

## 1.6.1 - 2026-07-23

### Fixed
- Open menu: the Codex and Copilot launcher icons now show the clean mascot glyph
  (the knot; the pixel head) without the trailing braille dot-matrix. The animated
  dots belong only in the menu bar; the picker stays crisp.

## 1.6.0 - 2026-07-23

### Added
- Built-in updates: a quiet daily check against GitHub Releases plus a
  "Check for Updates…" row in the menu (current version shown as its badge —
  the separate Version line is gone). One click on "Update to X — Install &
  Relaunch" downloads the release, verifies the bundle version, swaps the app
  in place (with automatic rollback on failure), and relaunches. No Sparkle,
  no windows, no extra processes.

### Fixed
- Menu: the bottom section no longer shows ragged indentation on macOS 26 —
  the update row carries an icon so the section keeps one consistent gutter.

## 1.5.0 - 2026-07-23

### Added
- Animated mascots for the other agents, built from each tool's real visual
  identity: Codex = OpenAI knot + a braille dot-matrix that spells "codex"
  (echo of the Codex CLI thinking indicator); Copilot = GitHub's official
  pixel-art mascot head (traced pixel-by-pixel) + a purple dot-matrix spelling
  "copilot"; Antigravity = the official pixel rainbow arch with a traveling
  color wave. All three animate through the same sprite pipeline as Clawd and
  work in both Color and System (monochrome) modes.
- `Scripts/mascots/`: self-contained generators for the mascot frame sets.
- `docs/archive/2026-07-23-mascot-concepts/`: the original character concepts
  (walking terminal robot, paper plane, astronaut) kept as ready alternatives —
  the paper plane especially is on deck as a reserve Copilot look.

## 1.4.0 - 2026-07-23

### Changed
- New app icon: light ivory squircle with the charcoal prompt chevron and a
  menu-bar-item pill holding the four agent status dots — one lit, three dimmed
  (the session that needs you). Replaces the dark terminal-style icon.

## 1.3.0 - 2026-07-23

### Added
- New "question" state: when Claude asks you something (AskUserQuestion — option
  pickers, plan questions), the session shows a blue dot with the question text
  instead of a false "needs approval"; clicking the row jumps to the session to
  answer. Clears automatically once you reply.
- docs/claude-code-states.md: authoritative mapping of Claude Code hook events to
  AgentBar states, including what's deliberately not consumed and why.

## 1.2.1 - 2026-07-23

### Fixed
- Sessions no longer get stuck on "needs approval": the legacy Notification hook
  could land late (including after the upstream dialog-flash race) and overwrite
  newer state with a stale permission flag. Permission state is now written solely
  by permission.js; the Notification hook is no longer installed and old
  registrations are cleaned up on next launch.
- The permission-dot icon now adapts to the menu bar appearance in System mode
  instead of rendering a hard-black glyph.

## 1.2.0 - 2026-07-23

### Changed
- Approval UI: inline ✓ Allow / ✓ Always / ✕ Deny button strip directly under the
  session row replaces the second-level submenu; the fourth button adapts to the
  session surface (⌨ Terminal for CLI, ⧉ Claude app for desktop). Clicking the
  session row hands the prompt back to that surface.
- "Always allow" now shows the rule as readable text (e.g. `Bash(git push:*)`)
  instead of raw JSON.

### Added
- One-line installer (`Scripts/install.sh`) that fetches the prebuilt universal
  app from the latest GitHub release, plus a Homebrew tap
  (`brew install --cask michalstrnadel/tap/agentbar`).
- README: requirements, uninstall, troubleshooting; SECURITY.md; CI hardening.

## 1.1.0 - 2026-07-23

### Added
- Remote Allow/Deny: answer Claude Code permission prompts from the menu bar —
  see the exact command, then allow once, always-allow with the Claude-suggested
  rule, deny, or defer to the terminal prompt. Every failure mode (app not
  running, timeout, kill) falls back to the normal terminal prompt.
- Best-effort keystroke approval for Codex and Copilot sessions (requires the
  Accessibility permission; clearly labeled in the menu).
- Preferred terminal picker: Open ▸ Terminal lists installed terminals; the
  checkmarked one is remembered and used for Open actions.

## 1.0.0 - 2026-07-23

First release. A clean-room rewrite of the AI Status Notifier concept as a
multi-agent menu bar app.

### Added
- Menu bar mascot animation per agent while it works: Clawd the crab (Claude),
  OpenAI mark (Codex), Copilot goggles, Antigravity mark.
- Amber permission dot the moment any agent waits for approval; permission
  outranks working, working outranks idle when picking what the bar shows.
- Sessions menu: one row per live session with project name, git branch, live
  state and agent tag; click to focus that app or terminal.
- Open submenu: Claude app, Codex, Copilot, Antigravity, or a terminal.
- Color modes: Color (each agent in its brand color) and System (adaptive
  monochrome that matches the menu bar).
- Rotating thinking verbs next to the mascot while an agent works.
- Claude Code hooks (full fidelity: prompt, tool use, permission, stop,
  session lifecycle) and a Codex `notify` adapter; hook install is automatic
  and idempotent on first launch.
