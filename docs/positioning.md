# Positioning

What people evaluating AgentBar compare it with, what only AgentBar does, and the
sentence that sets it apart. Researched 2026-10-16 for issue #26. Facts about other
tools come from their own sites, repos and docs and are linked per row; anything not
read at the source is marked *unverified*. Star counts and dates are as of
2026-10-16 and will drift.

House rule: this is a factual comparison. AgentBar does not credit, cite or claim
inspiration from any of these projects, in this file or in launch copy.

## The short version

The space filled up in 2026. At least five other macOS apps now show coding-agent
sessions in the notch or the menu bar **and** answer permission requests from there,
across more than one vendor — two of them open source with thousands of stars
(Coucou, CodeIsland), two paid (Vibe Island, Perch). "One approval queue for every
agent" is therefore no longer a difference on its own. A commenter who knows the
space will name CodeIsland or Coucou within the first hour.

What is still AgentBar's alone, and backed by code, is **what happens to an answer**:
rules the person typed that start out *watching*, a live re-check of the actual
command before any rule approves, a written record of every answer and who gave it,
the per-repo memory of how you decided before, and a deny that carries a note back
to the agent. The pitch has to lead with that, not with the notch.

## The comparison

Legend for **Permission path**: *Approves* = the tool answers a blocking
permission request (allow and deny) for at least one agent; *Notifies* = tells you a
request exists, the answer stays in the agent's own UI; *No* = not involved.
**Cross-vendor** = more than one agent vendor.

### Notch and menu-bar apps for coding agents

| Tool | What it does | Platforms | Price | Last release | Permission path | Cross-vendor | Source |
|---|---|---|---|---|---|---|---|
| **CodeIsland** (wxtsky) | Notch panel for "30+ AI coding tools": status, approve / deny / always-allow, answer questions, jump to tab, SSH hosts, push to ntfy/Slack/Telegram (pushes "answer nothing"), "auto-proceed for agents you already run in YOLO mode". 2.5k stars, MIT. **Signed and notarized**, Sparkle updates | macOS; iPhone + Apple Watch companion (App Store, free) | Free, open source | v1.0.38, 2026-10-11 | Approves (Claude Code, Codex, Gemini CLI, Qwen, OpenCode and others per its README) | Yes | [repo](https://github.com/wxtsky/CodeIsland) |
| **Coucou** (Louis-CFM) | Notch companion ("Mochi") for Claude Code, Codex, Cursor, Gemini CLI, Antigravity, Copilot CLI, OpenCode, Amp…; Allow / Deny / Always for Claude Code, Allow / Deny for Codex; plus dictation, call notetaker, chat, crypto portfolio, Spotify, Stripe… 5.3k stars, MIT code | macOS 15+, Windows, Linux, iPhone (TestFlight), Android | Free, open source | v0.4.0, 2026-10-15 | Approves (Claude Code, Codex) | Yes | [repo](https://github.com/Louis-CFM/coucou) |
| **Vibe Island** | Notch app for ~30 agents; "Monitor, approve, and jump back — right from the notch" | macOS, Apple silicon | $19.99 one-time (1 Mac), trial | v1.0.53, 2026-10-10 | Approves | Yes | [site](https://vibeisland.app/), [changelog](https://vibeisland.app/changelog) |
| **Perch** | Menu bar watcher for Claude Code, Codex, Cursor, Devin, OpenCode, Amp, Antigravity; approve / deny on the Mac and from an iPhone / Watch notification with Face ID | macOS 13+, iOS 18+, watchOS 11+ | $29 one-time; Pro $29/yr | *unverified* (site links GitHub releases) | Approves (which agents: not stated) | Yes | [site](https://perch.run/) |
| **Runnock** | Notch status for agents, dev servers, builds, git, deploys; approve / deny and answer questions | macOS 26+, Apple silicon | One-time licence, price not shown | Product Hunt launch ~2026-10-16 *unverified* | Approves | Yes | [Product Hunt](https://www.producthunt.com/products/runnock) |
| **Vibe Notch** (farouqaldori, formerly Claude Island) | Notch session manager for Claude Code; approve / deny tool calls; chat history. 2.5k stars | macOS | Free, open source | v1.3.2, 2026-04-20 | Approves (Claude Code) | No | [repo](https://github.com/farouqaldori/vibe-notch) |
| **Chimlo** | Notch app for Codex and Claude Code; deny / allow once / allow for session for Claude; "Codex approvals still run inside Codex" | macOS | Free, open source (repo not found) | *unverified* | Approves (Claude Code only) | Partly | [Product Hunt](https://www.producthunt.com/posts/chimlo) |
| **Atoll** (rutmehta) | General notch hub (media, calendar, shelf…) plus Claude Code and Codex session monitoring and approvals. 1 star | macOS 14+ | Free, open source | v0.3.3, 2026-09-29 | Approves *unverified* | Yes | [repo](https://github.com/rutmehta/Atoll) |
| **CC Status Bar** (usedhonda) | Menu bar monitor for Claude Code and Codex sessions; colour alerts, autofocus the waiting terminal. 90 stars | macOS | Free, open source | v1.10.2, 2026-09-29 | Notifies | Yes | [repo](https://github.com/usedhonda/cc-status-bar) |
| **so-agentbar** (sotthang) | Menu bar monitor for Claude Code (and Codex per its site); approval-request notifications. 22 stars. *Similar name — expect confusion* | macOS 14+ | Free, open source | v1.11.0, 2026-07-28 | Notifies | Partly | [repo](https://github.com/sotthang/so-agentbar), [site](https://sotthang.github.io/so-agentbar/) |
| **claude-status** (gmr) | Menu bar + desktop widget for Claude Code sessions. 64 stars | macOS | Free, open source | v1.4.0, 2026-07-29 | Notifies | No | [repo](https://github.com/gmr/claude-status) |
| **ai-sessions** (Cresswell-0301) | Menu bar tracker for Claude Code and Codex; notifies, jumps to the VS Code tab | macOS | Free, open source | no release | Notifies | Yes | [repo](https://github.com/Cresswell-0301/ai-sessions) |
| **cctop** (st0012) | Keyboard-first menu bar monitor for Claude Code, Codex, opencode, pi sessions; jumps to the pane. 158 stars | macOS | Free, open source | v0.21.4, 2026-09-13 | Notifies *unverified* | Yes | [repo](https://github.com/st0012/cctop) |
| **Agent Island** (two unrelated projects share the name) | tristan666666/agent-island: notch / tray status for Claude Code and Codex, macOS and Windows, 87 stars. Tiwari1999/Agent-Island: notch status for Claude Code, Codex, Cursor | macOS (+ Windows for the first) | Free, open source | *unverified* | Notifies *unverified* | Yes | [repo](https://github.com/tristan666666/agent-island), [repo](https://github.com/Tiwari1999/Agent-Island) |
| **Crest** | Notch app showing Codex and Claude Code permission requests | macOS | *unverified* | *unverified* | *unverified* | Yes | [site](https://crestnotch.app/claude-code-notch) (listing text only) |
| **cmux** (manaflow-ai) | Ghostty-based terminal with vertical tabs and notifications for coding agents. 28k stars | macOS | Free, open source | rolling pre-releases, 2026-10-16 | Notifies | Yes | [repo](https://github.com/manaflow-ai/cmux) |

### Usage and quota meters (overlap only on the quota line)

| Tool | What it does | Platforms | Price | Last release | Permission path | Cross-vendor | Source |
|---|---|---|---|---|---|---|---|
| **CodexBar** | Menu bar usage stats for Codex and Claude Code. 22.5k stars | macOS | Free, open source | v0.76.0, 2026-10-15 | No | Yes | [repo](https://github.com/steipete/CodexBar) |
| **ClaudeBar** (tddworks) | Menu bar quotas for Claude, Codex, Antigravity, Gemini. 1.5k stars | macOS | Free, open source | v0.5.16, 2026-10-16 | No | Yes | [repo](https://github.com/tddworks/ClaudeBar) |
| **ccusage** | CLI token / cost reports from local logs. 19k stars | Any (Node) | Free, open source | v20.0.34, 2026-10-15 | No | Yes | [repo](https://github.com/ccusage/ccusage) |

### Orchestrators (run many agents; a different job)

| Tool | What it does | Platforms | Price | Last release | Permission path | Cross-vendor | Source |
|---|---|---|---|---|---|---|---|
| **Conductor** | Runs Claude Code, Codex, Cursor in parallel isolated workspaces; review and merge. Changelog 0.41.0 (2026-03-19) lists "Tool Approval" | macOS | Not listed on site | 0.91.0, 2026-10-15 | Approves inside its own app *unverified detail* | Yes | [site](https://www.conductor.build/), [changelog](https://www.conductor.build/changelog) |
| **Happy** (slopus) | Mobile + web client that runs Claude Code / Codex / Grok through its CLI wrapper; push notifications and approve from the phone, encrypted relay. 24k stars | iOS, Android, web; CLI on the computer | Free, open source | CLI 1.2.6-beta.1, 2026-10-09 | Approves (sessions started through `happy`) | Yes | [repo](https://github.com/slopus/happy) |
| **Vibe Kanban** | Kanban board that runs coding agents per task. 28k stars | Cross-platform (web UI) | Free, open source | v0.1.44, 2026-04-24 | No *unverified* | Yes | [repo](https://github.com/BloopAI/vibe-kanban) |
| **Claude Squad** | TUI managing several terminal agents in tmux + worktrees. 8.6k stars | macOS, Linux | Free, open source | v1.0.20, 2026-08-20 | No (you answer in the pane) | Yes | [repo](https://github.com/smtg-ai/claude-squad) |
| **Crystal → Nimbalyst** | Parallel Claude Code / Codex sessions in worktrees, desktop app; repo says it is now Nimbalyst | macOS (desktop) | Free, open source | 0.3.5, 2026-02-26 | *unverified* | Yes | [repo](https://github.com/stravu/crystal) |
| **Omnara** | Was a mobile command centre for Claude Code; repo now describes "the open-source managed agent platform" | Server / self-host | Free, open source | omnarad v0.2.6, 2026-10-16 | *unverified* for local approvals today | Yes | [repo](https://github.com/omnara-ai/omnara) |
| **VibeTunnel** | Any browser as a terminal to command agents on the go | macOS host, browser client | Free, open source | 1.0.0 beta 18, 2026-07-11 | No (you answer in the terminal) | Yes | [repo](https://github.com/amantus-ai/vibetunnel) |

### Human-in-the-loop approval tools

| Tool | What it does | Platforms | Price | Last release | Permission path | Cross-vendor | Source |
|---|---|---|---|---|---|---|---|
| **HumanLayer** | Started as an SDK for routing agent tool calls to a human (Slack / email); the public repo now says "the code here is pretty much all deprecated" and points to a rebuild at humanlayer.com aimed at coding agents | Hosted / desktop *unverified* | *unverified* | nightly pre-release 2026-02-27 | For agents built on its SDK, not for local Claude Code / Codex prompts *unverified* | n/a | [repo](https://github.com/humanlayer/humanlayer) |
| **claude-remote-approver** | Claude Code permission prompts as ntfy pushes to the phone. 73 stars | Any (Node) + ntfy app | Free, open source | no release; last push 2026-03-02 | Approves (Claude Code) | No | [repo](https://github.com/yuuichieguchi/claude-remote-approver) |

### The agents' own features

| Feature | What it does | Platforms | Price | Permission path | Cross-vendor | Source |
|---|---|---|---|---|---|---|
| **Claude Code Remote Control** | `/remote-control`: continue a local session from claude.ai/code or the Claude mobile app, including answering prompts | Any + iOS / Android / web | Pro, Max, Team, Enterprise; not with API keys or a non-Anthropic `ANTHROPIC_BASE_URL` | Approves | No — Claude Code only | [docs](https://code.claude.com/docs/en/remote-control) |
| **Claude Code hooks** (`Notification`, `PermissionRequest`) | The surface every third-party tool above (and AgentBar) builds on; on its own, a terminal bell or a script you write | Any | Included | Approves if you write the hook | No | [docs](https://code.claude.com/docs/en/hooks) |
| **Codex CLI `notify` / `tui.notifications`** | Terminal / desktop notification on turn complete and approval requested (OSC 9 or bell, terminal-dependent); `notify` covers turn completion only *per third-party guides* | Any | Included | Notifies | No | [guide](https://codex.danielvaughan.com/2026/04/10/codex-cli-agent-notifications-desktop-alerts-monitoring/) *unverified against OpenAI docs* |
| **Cursor, Gemini CLI, Copilot CLI** | Each notifies in its own window / terminal; Cursor and Gemini CLI hooks can only refuse, not approve (measured, `docs/permission-surfaces.md`) | Any | Included | Notifies (own UI) | No | `docs/permission-surfaces.md` |

## What only AgentBar does

Each claim below is checked against the code in this repo (file named) and, as far
as the sources above show, against every tool in the tables. "As far as the sources
show" is the honest limit: a competitor may ship any of these next week, so re-check
the two closest (CodeIsland, Coucou) before each launch post.

1. **Rules the person wrote, that watch before they answer.** A rule starts in
   *watching* mode: it matches, works out what it would have said, writes it down,
   and answers nothing. Its line shows whether you agreed with it, and only after ten
   agreeing matches over three days does it offer **Let it answer**.
   `Sources/AgentBar/RuleEngine.swift`, `RulesStore.swift`, `RulesView.swift`,
   `RuleSheet.swift`; tests `Tests/AgentBarTests/RuleEngineTests.swift`,
   `RuleAgreementTests.swift`. Others have "always allow" or a YOLO pass-through
   (CodeIsland's auto-proceed), not a rule you can watch first.
2. **An approving rule is re-checked against the live command, and there is no
   setting to turn that off.** Chained, piped, redirected or substituted commands,
   `sudo`, destructive git / `rm`, anything reaching off the Mac, paths outside the
   rule's one directory, or anything touching permission config fall through to the
   human. `RuleEngine.refusal(for:)` / `refusalInCommand` / `refusalInPath` in
   `Sources/AgentBar/RuleEngine.swift`.
3. **Every answer is written down with who gave it** — you, a rule (named), the
   phone, or Claude's own UI — in a local JSONL ledger, readable in Settings and with
   `agentbar rules` / `agentbar approvals`. `Sources/AgentBar/DecisionLedger.swift`
   (`via`, rule id), `ClaudeDecisionIngest.swift`.
4. **Per-repo memory of how you decided**: "Allowed 23× here · last Tue", and the
   *Always* button is pointed at — never pressed — after five allows and no refusals.
   `DecisionLedger.swift` (history per shape, per repo).
5. **Deny with a note** that the agent reads as the reason and changes course;
   also on a rule (**Tell it**). `Sources/AgentBar/AnswerWriter.swift` (`DenyNote`),
   `Tests/AgentBarTests/DenyNoteTests.swift`.
6. **Your week of decisions**: the prompts that held agents up longest, how long they
   waited on you, and what a watching rule would have saved.
   `Sources/AgentBar/DecisionWeek.swift`, `DecisionWeekView.swift`.
7. **No Allow it can't keep.** Allow is offered only where the vendor's hook can
   approve (Claude Code, Codex, Copilot); veto-only agents (Cursor, Gemini CLI) get
   status, not a button the agent would ignore. Measured per version in
   `docs/permission-surfaces.md`. CodeIsland's README lists Gemini CLI among agents
   answerable from its island — that contradicts our measurement of Gemini CLI 0.50
   and is worth a re-check before anyone says it in public.
8. **Phone approvals that only Allow what you can read whole**: off until switched
   on, by default only while you are away, Allow only for a complete readable shell
   command, a reply answers exactly one request once.
   `Sources/AgentBar/PhoneRelay.swift`, `PhonePage.swift`, `PhoneRelayTests.swift`.
   (Coucou's Android app has a similar "too long — allow on the computer" rule; the
   difference is the narrower Allow and the self-hostable ntfy topic, not the idea.)
9. **No link can approve anything.** `agentbar://` can focus, open the launcher or
   Your Day, never approve, deny, answer or write a rule.
   `Sources/AgentBar/URLCommands.swift`, `URLCommandsTests.swift`.
10. **A Linux CLI that is a full peer** (live status, `a` / `d` Allow / Deny, waybar
    module) on the same file protocol, and a Windows tray app on it too.
    `Scripts/cli/agentbar`, `docs/protocol.md`,
    [AgentBar-Windows](https://github.com/michalstrnadel/AgentBar-Windows).
    (Coucou also runs on Windows and Linux; the difference is a terminal-native CLI
    and a published protocol any tool can write to: `agentbar report`.)
11. **Keep Mac Awake that knows when the agents are done**, with lid-closed mode that
    puts the Mac to sleep when it ends. `Sources/AgentBar/KeepAwake*.swift`,
    `LidSleep.swift`. (Perch has an opt-in "hold off idle sleep while an agent is
    running"; the lid-closed mode and the triggers are the difference.)
12. **Installer that shows its own diff and keeps backups** of every settings file
    it writes into. `Sources/AgentBar/ConfigBackup.swift`,
    `ConfigChangesSheet.swift`, `HookInstaller.swift`.

Not unique, so never claimed as such: notch / island presentation, cross-vendor
status, one-click approvals, answering multiple-choice questions, jump to the exact
tab, quota meters, a day/week recap card (Coucou has a weekly recap), sounds,
SSH-hosted sessions (CodeIsland does them too).

## Honest weaknesses

Say these before a commenter does.

- **Not notarized by Apple.** The app is signed with the project's own certificate;
  the install script and the Homebrew cask strip the quarantine flag, and a zip
  downloaded by hand meets "cannot verify AgentBar is free of malware". For a tool
  whose pitch is the permission path, this is the first objection. CodeIsland *is*
  notarized. Mitigation to cite: signed release provenance
  (`gh attestation verify`, SECURITY.md ▸ Verifying a download), CodeQL, SBOM, the
  updater pinning the first-installed certificate.
- **`curl | bash` install.** Same objection, same mitigation; Homebrew cask is the
  recommended path.
- **Fewer agents than the biggest alternatives.** Nine wired agents plus cloud
  pollers and `agentbar report` bridges, versus "30+" claimed by CodeIsland and Vibe
  Island. Approve-tier is three vendors (Claude Code, Codex, Copilot) — by measurement,
  not by choice.
- **No native phone app.** Phone approvals go through ntfy; CodeIsland, Coucou and
  Perch have iPhone apps with Lock Screen / Live Activity / Watch.
- **Tiny adoption.** 9 stars, 4 forks, one maintainer (2026-10-16). Competitors have
  2.5k–24k stars. Expect "why not CodeIsland?".
- **Needs Node.js** for the hook scripts.
- **The Windows port is a separate repo and younger** than the Mac app.
- **A lot of surface for a solo project** (games, Your Day, Keep Awake). A reviewer
  may read that as scope creep; lead with the permission story, mention the rest last.
- **Name collision** with `so-agentbar`, a small Claude Code menu bar monitor.

## What to say when a commenter names a tool

- *CodeIsland / Vibe Island / Coucou / Perch*: "Those answer the prompt; AgentBar
  also lets you write the answer down as a rule that watches for a week before it may
  speak, re-checks the actual command before any rule approves, and logs who answered
  every request. If you only want the notch, they're good."
- *Claude Code Remote Control / Happy*: "Claude-only (Remote Control) or only sessions
  started through its wrapper (Happy); AgentBar answers the sessions you already run,
  across Claude Code, Codex and Copilot, from the Mac."
- *Conductor / Claude Squad / Vibe Kanban*: "Those run agents for you. AgentBar
  doesn't run anything — it sits next to whatever you already use and is where they
  ask."
- *CodexBar / ClaudeBar / ccusage*: "Usage meters. AgentBar has one, but it is the
  footer, not the product."
- *"Just use `--dangerously-skip-permissions`"*: "Then you need none of these.
  AgentBar is for people who keep the prompts on and want them cheaper to answer."

## Headline and subtitle

**Headline:** One approval queue for your coding agents, and rules that watch before they answer.

**Subtitle:** A free, open-source menu bar and notch app for Claude Code, Codex,
Copilot and six more. Answer in one click, or write the answer down as a rule that
starts out watching — and every answer, yours or a rule's, is on record.

Short form (for a post title or a list entry): *AgentBar — approve Claude Code,
Codex and Copilot prompts from the menu bar, with rules you write and a log of every
answer.*

Why this and not "One approval queue for every AI coding agent" alone: four other
apps can now say the first half. The second half is the part they can't.
