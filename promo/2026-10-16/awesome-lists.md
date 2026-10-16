# Awesome lists — where AgentBar can be listed

Issue #24. Researched 2026-10-16 with `gh` and the lists' own CONTRIBUTING files.
Nothing has been submitted, starred, forked or commented on. Stars and dates are as of
2026-10-16.

**AgentBar facts the rules check against:** repo created 2026-07-23 (85 days old),
9 stars, MIT, active. That clears every "14 days old OR 100 stars" rule; none of the
lists asks for notarization.

**Before submitting anywhere**

- Submit **by hand**, one list at a time, in the browser. Several lists ban bot or
  CLI submissions outright (awesome-claude-code: "It is **not** possible to submit a
  resource recommendation using the `gh` CLI"; "resource recommendations must be
  created by human beings").
- Never claim Allow/Deny for Cursor or Gemini CLI: their hooks can only refuse
  (`docs/permission-surfaces.md`). Every entry below says *status* for those and
  *approve* only for Claude Code, Codex and Copilot CLI.
- **Name collision:** a different app called **so-agentbar** (sotthang) is already
  listed in awesome-claude-code. Make clear this is a different project if asked.
- **Already there / already tried:**
  - jaywcjlove/awesome-swift-macos-apps — AgentBar is **already listed** under `## AI`
    (description out of date).
  - jaywcjlove/awesome-mac — PR #2393 (2026-07-23) is **still open**, untouched for 85
    days; README.md only, missing the zh/ja/ko files.
  - iCHAIT/awesome-macOS — PR #943 **closed** the same day by the maintainer with
    "You "AI" dudes have a real problem with understanding consent, have you?". Do not
    go back.

## Ranked: submit

### 1. hesreallyhim/awesome-claude-code
- URL: https://github.com/hesreallyhim/awesome-claude-code — 55.8k stars
- Last merged: 2026-10-15 (daily; a bot turns accepted issue forms into PRs, resources
  are from outside authors)
- Self-submission: **yes** — "I'm very grateful to everyone who shares their amazing work."
- Rules, quoted: "Any resource that is recommended must either: (i) Be at least 14 days
  old … AND show signs of active development … OR (ii) Have at least 100 stars." /
  "ALL RECOMMENDATIONS MUST BE MADE USING THE WEB UI ISSUE FORM TEMPLATE, OR YOU RISK
  BEING RESTRICTED" / "Do not open a PR" / "It is **not** possible to submit a resource
  recommendation using the `gh` CLI" / "resource recommendations must be created by
  human beings."
- How: fill in https://github.com/hesreallyhim/awesome-claude-code/issues/new?template=recommend-resource.yml
  yourself. **Leave the last checkbox unchecked** — it is a trap.
- Section: *Observability & Monitoring › Session Monitors* (peers: Claude Status,
  claude-status-bar, c9watch, so-agentbar). Alternative: *Remote Control,
  Notifications & Voice I/O*.
- Existing entry, verbatim: `- [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) by [mick](https://github.com/m1ckc3s) - A tiny, hook-driven macOS menu-bar indicator of Claude Code's live turn status — …`
- Form values:
  - Display name: `AgentBar`
  - Link: `https://github.com/michalstrnadel/AgentBar`
  - Author: `Michal Strnadel` / `https://github.com/michalstrnadel`
  - Description:
    `A native macOS menu-bar app and notch panel that shows the live status of Claude Code sessions alongside Codex, Cursor, Gemini CLI, Copilot CLI and other agents, and answers Claude Code permission requests through a blocking PermissionRequest hook that falls back to the terminal prompt on timeout. Swift/AppKit with Node.js hook scripts; a Linux CLI reads the same state files.`

### 2. serhii-londar/open-source-mac-os-apps
- URL: https://github.com/serhii-londar/open-source-mac-os-apps — 50.8k stars
- Last merged: 2026-10-16 (7 outside PRs that day)
- Self-submission: **yes** (no rule against it, no star minimum)
- Rules, quoted: "Edit applications.json instead of README.md." / "Projects are
  ineligible if: Lack recent commit; README is not clear or not written in English."
- Format: one PR per app, using the PR template (Project URL, Category, Description,
  Checklist); append to the end of the `applications` array.
- Existing entry, verbatim: `{"title": "Notch So Good", "short_description": "A pixel-art crab lives in your MacBook notch and monitors Claude Code sessions with 13 animations, smart notifications, and multi-session support.", "categories": ["utilities","menubar"], …}`
- Entry:
  ```json
  {
    "title": "AgentBar",
    "short_description": "Menu bar and notch status for AI coding agents (Claude Code, Codex, Cursor, Gemini CLI, Copilot CLI and others), with Allow and Deny for Claude Code, Codex and Copilot permission requests.",
    "categories": ["menubar", "development"],
    "repo_url": "https://github.com/michalstrnadel/AgentBar",
    "icon_url": "",
    "screenshots": [],
    "official_site": "https://github.com/michalstrnadel/AgentBar",
    "languages": ["swift", "javascript"]
  }
  ```

### 3. jaywcjlove/awesome-mac — update PR #2393, don't open a new one
- URL: https://github.com/jaywcjlove/awesome-mac — 116k stars
- Last merged: 2026-10-16 (daily, outsiders)
- Self-submission: **yes**
- Rules, quoted: "Link additions should be added in alphabetical order in the relevant
  category." / AI-assisted contributions: "sync entries across `README.md`,
  `README-zh.md`, `README-ja.md`, and `README-ko.md`". Recent merged PR titles end in
  "(EN/ZH/JA/KO)".
- Action: push to PR #2393 so it adds the line to all four READMEs and refreshes the
  description; retitle it `Add AgentBar to Menu Bar Tools (EN/ZH/JA/KO)`.
- Section: `### Menu Bar Tools`, after "Agent Island", before "AirPoise".
- Existing entry, verbatim: `* [cctop](https://cctop.app) - Open-source menu bar monitor that shows live status for AI coding sessions (Claude Code, Codex, opencode, pi) and jumps to the right terminal pane or editor window. [![Open-Source Software][OSS Icon]](https://github.com/st0012/cctop) ![Freeware][Freeware Icon]`
- Entry (EN):
  `* [AgentBar](https://github.com/michalstrnadel/AgentBar) - Menu bar and notch status for AI coding agents (Claude Code, Codex, Cursor, Gemini CLI, Copilot CLI), with one-click Allow or Deny for Claude Code, Codex and Copilot permission requests. [![Open-Source Software][OSS Icon]](https://github.com/michalstrnadel/AgentBar) ![Freeware][Freeware Icon]`
  (zh/ja/ko: translate the description only; keep the badges.)

### 4. milisp/awesome-codex-cli
- URL: https://github.com/milisp/awesome-codex-cli — 122 stars
- Last merged/added: 2026-10-15 (outside resources)
- Self-submission: **yes**, via issue (the form asks "Your relationship to the project")
- Rules, quoted: "External contributions are welcome through **issues only**." / "A
  resource with fewer than 100 stars is listed only if it passes the requirements and
  clearly meets at least two quality points. The submission must give the reason in
  the issue." Quality points: Distinct, Real use, Active, Accurate.
- Reason to give: *Active* (release 1.55.1 on 2026-10-12, 50+ releases since July) and
  *Distinct* (answers Codex's `PermissionRequest` hook, `Scripts/hooks/codex/`;
  watching rules with a decision log). *Real use*: listed in awesome-swift-macos-apps.
- Section: `### Session Managers` (next to cctop). Alternative: `### Usage & Monitoring`.
- Existing entry, verbatim: `- [Crest](https://crestnotch.app/claude-code-notch) - macOS notch app that shows Codex and Claude Code permission requests in the MacBook notch.`
- Entry:
  `- [AgentBar](https://github.com/michalstrnadel/AgentBar) - macOS menu bar and notch app that shows which Codex CLI sessions are working or waiting and answers Codex permission requests through its hooks, alongside Claude Code, Copilot CLI and other agents.`

### 5. Piebald-AI/awesome-gemini-cli
- URL: https://github.com/Piebald-AI/awesome-gemini-cli — 517 stars
- Last merged: 2026-10-15 (8 outside PRs that day)
- Self-submission: **yes** — "No need to disclose affiliation, if any. Most people
  submit their own projects anyway."
- Rules, quoted: "Entries should be related to Gemini CLI." / "Add your item to the
  bottom of the appropriate section." (Their CONTRIBUTING asks agents to ask the user to
  star the repo — your call, not done.)
- Section: `## Development Tools & Utilities`, at the bottom.
- Existing entry, verbatim: `- [aisw](https://github.com/burakdede/aisw) - Saves Gemini CLI logins and API keys as named profiles and switches the live `~/.gemini` state in one command, alongside Claude Code, Codex CLI and Antigravity CLI. Docs: [aiswitcher.dev](https://aiswitcher.dev).`
- Entry (status only for Gemini, on purpose):
  `- [AgentBar](https://github.com/michalstrnadel/AgentBar) - macOS menu bar and notch app that shows live Gemini CLI and Antigravity CLI session status through their hooks, alongside Claude Code, Codex and Copilot CLI, whose permission requests it can also answer.`

### 6. bradAGI/awesome-cli-coding-agents
- URL: https://github.com/bradAGI/awesome-cli-coding-agents — 1.36k stars
- Last merged: 2026-09-22 (maintainer batch-merges the PR queue: 25 entries that day,
  33 on 2026-09-13; 109 PRs open)
- Self-submission: **yes** — "PRs welcome!"; no ban
- Rules: inclusion requirements target agents ("Must have a CLI or terminal
  interface"), but the Harnesses sections list tools around agents. "Entries are sorted
  by GitHub stars within each section."
- Section: `### Session managers & parallel runners`, by stars — just above `tring` (⭐ 2).
- Existing entry, verbatim: `- **[postmortemthis](https://github.com/Softeria/postmortemthis)** `⭐ 1` — Runs every coding-agent CLI you have (Claude Code, Codex, Gemini, Qwen, Vibe) in parallel and read-only over your diff, …`
- Entry:
  ``- **[AgentBar](https://github.com/michalstrnadel/AgentBar)** `⭐ 9` — macOS menu bar and notch app, plus a Linux CLI, that shows live status for Claude Code, Codex, Cursor CLI, Gemini CLI, Copilot CLI, OpenCode and other agent sessions and answers Claude Code, Codex and Copilot permission requests from one queue. Swift, MIT.``

### 7. karanb192/awesome-claude-code-mods — for the mod, not the app
- URL: https://github.com/karanb192/awesome-claude-code-mods — 606 stars, active (automated)
- Fits the Claude Code mod in `Scripts/mods/claude`, not the app.
- Rules, quoted: "Add your `owner/repo` to `data/seeds.txt`, one per line, in
  alphabetical order ignoring case." / "A catalogue submission only needs the seed; do
  not add a README entry." / Featured: "Self-nominations are welcome; disclose your
  relationship to the mod."
- Zero-PR route: add the GitHub topic `claude-code-mod` to the repo — "With the
  `claude-code-mod` topic, a scan usually picks up a mod within a few hours of its next
  push." *Unverified* whether the scanner finds a mod nested at `Scripts/mods/claude/`.
- Seed line: `michalstrnadel/AgentBar`

### 8. jaywcjlove/awesome-swift-macos-apps — refresh the existing entry
- URL: https://github.com/jaywcjlove/awesome-swift-macos-apps — 1.75k stars, very active
- **Already listed** under `## AI`: "Monitor all your AI coding sessions from a single
  menu bar item — Claude Code, Codex, Cursor, and more."
- Rule, quoted: corrections allowed — "Updating existing listings in both files"
  (README.md and README.zh.md).
- Optional PR: move to `## AI Usage/Status` (amtrino, AgentPet, Agent Beacon, Ambient)
  and change the description to
  `Shows live status of AI coding agents in the menu bar or notch and answers their permission requests from one queue.` (keep the existing `<img>` badge format).

### 9. ai-for-developers/awesome-ai-coding-tools — weaker fit
- URL: https://github.com/ai-for-developers/awesome-ai-coding-tools — 2.17k stars
- Last merged: 2026-09-18 (batch, mostly outsiders; 300+ PRs open)
- Rules, quoted: "Are **AI-powered** or **AI-enhanced** … at least a **free tier**." /
  "Add your tool to the **end of the relevant section**." AgentBar is not itself
  AI-powered; low odds.
- Section: `## Developer Productivity Tools`, at the end.
- Entry:
  `- **[AgentBar](https://github.com/michalstrnadel/AgentBar)** – macOS menu bar and notch app that shows live status for Claude Code, Codex, Cursor, Gemini CLI and Copilot CLI sessions and answers Claude Code, Codex and Copilot permission requests from one queue.`

### 10. RoggeOhta/awesome-codex-cli — low odds
- URL: https://github.com/RoggeOhta/awesome-codex-cli — 551 stars
- Last activity: maintainer batch on 2026-09-06, before that April; **no PR ever
  merged**, 300+ open.
- Rule, quoted: "[Open an issue] with the link and a brief description" / "What We
  Won't Accept – Self-promotion without substance — your project needs real users or a
  clear unique value."
- Section: `## GUI & Desktop Apps`.
- Entry:
  `- [michalstrnadel/AgentBar](https://github.com/michalstrnadel/AgentBar) - macOS menu bar and notch app that shows Codex CLI session status and answers Codex permission requests, alongside Claude Code, Copilot CLI and other agents. ![GitHub stars](https://img.shields.io/github/stars/michalstrnadel/AgentBar?style=flat-square)`

### 11. jqueryscript/awesome-claude-code — very low odds
- URL: https://github.com/jqueryscript/awesome-claude-code — 531 stars
- Maintainer adds entries himself in batches (last 2026-10-15); outside PRs are closed
  unmerged (10 of 10 checked). Contribution guidelines: "**Under Construction**". An
  issue is the only plausible route (*unverified*).
- Section: `## 🖥️ Clients & GUIs` (next to Coucou).
- Entry:
  `- [**AgentBar**](https://github.com/michalstrnadel/AgentBar) - (9 ⭐) - macOS menu bar and notch app for watching Claude Code and other coding agents and answering their permission requests.`

## SKIP

| List | Reason |
|---|---|
| iCHAIT/awesome-macOS (19.3k) | Rules forbid it: "No AI prompt wrappers or software whose main purpose is interfacing with generative tools like LLMs, chatbots, code generation APIs and similar, including agents." PR #943 already closed with a hostile comment |
| awesome-opencode/awesome-opencode (10.6k) | Dead: last merge 2026-07-02 (>90 days), 300 open PRs |
| jamesmurdza/awesome-ai-devtools (3.96k) | Dead: last merge 2026-06-29 |
| filipecalegario/awesome-vibe-coding (5.3k) | Dead: last merge 2026-04-11 |
| e2b-dev/awesome-ai-agents (30k) | Wrong scope (autonomous agents); only maintainer merges |
| rohitg00/awesome-claude-code-toolkit (2.7k) | Last push 2026-05-12 |
| VoltAgent/awesome-claude-code-subagents, awesome-codex-subagents, composio-community/awesome-codex-skills, ComposioHQ/awesome-claude-skills | Subagents / skills only |
| ComposioHQ/awesome-claude-code-tools | Does not exist |
| jordanbaird/awesome-menubar (4 stars), ymengsea-dev/awesome-notch (1 star) | Dead / negligible. No live menu-bar or notch awesome list found; the Menubar / Notch sections of awesome-swift-macos-apps are the closest |

## Suggested order

1. awesome-claude-code (issue form, by hand)
2. open-source-mac-os-apps (PR, applications.json)
3. awesome-mac (update PR #2393 to EN/ZH/JA/KO)
4. milisp/awesome-codex-cli (issue, with the two quality points)
5. awesome-gemini-cli (PR)
6. awesome-cli-coding-agents (PR)
7. The rest when there is time: the mod topic, the awesome-swift-macos-apps refresh,
   then the low-odds three.

Space them out — a few a day — so each one gets your own wording and attention.
