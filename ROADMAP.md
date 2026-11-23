# Roadmap

Where AgentBar is going, what is being found out before it is built, and what is
being built. Updated 2026-11-23. Every item links to its issue; the
[`roadmap`](https://github.com/michalstrnadel/AgentBar/issues?q=label%3Aroadmap)
label shows them all.

## Direction

Agents are given rights to your machine. AgentBar is where *you* grant them —
visible, confirmed, and on record. Three properties keep that true, and nothing on
this page may trade one away:

- **Across vendors.** No agent gets a better AgentBar than another.
- **Local first.** Nothing leaves the Mac unless you switch it on.
- **It does not decide for you.** Only a click, or a rule you wrote and can audit.

Status is why people install it. Approvals are why they keep it.

## How this roadmap works

- **Two tracks.** *Discovery* answers a question before anything is built: what is
  true, what people do, what would change our mind. *Delivery* builds and ships.
  An item starts in discovery when we can't yet say what "done" looks like.
- **Horizons, not dates.** *Now* is this cycle. *Next* starts when Now's outcome is
  met. *Later* is parked behind a gate and is not being worked on.
- **Outcomes over output.** A cycle is judged by its outcome, not by how many
  releases it shipped.

## Now — get AgentBar in front of the people it is for

**Outcome:** people who don't know the author install AgentBar and keep it.

| Signal | 2026-10-16 | 2026-11-23 | Target |
|---|---|---|---|
| GitHub stars | 9 | 15 | 100 |
| Installs (release downloads + brew) | tens | ~790 downloads, all releases (brew not counted) | 1 000 |
| Issues opened by people we don't know | 0 | 0 | 10 |

Downloads count every update an installed copy fetches, so they overstate people;
the one cycle-over-cycle number that cannot be inflated by our own releases is
stars.

### Discovery

- **Positioning** — what AgentBar is compared with, and the one claim only it can
  back with code. [#26](https://github.com/michalstrnadel/AgentBar/issues/26)

### Delivery — distribution

- **Social kit** — an approvals film, single-feature clips, post copy per network.
  [#22](https://github.com/michalstrnadel/AgentBar/issues/22)
- **Curated lists** that accept tools like this one.
  [#24](https://github.com/michalstrnadel/AgentBar/issues/24)
- **Community launch** — one rules-checked post per community, Hacker News last.
  [#25](https://github.com/michalstrnadel/AgentBar/issues/25)

### Delivery — keeping up with the agents

- Each agent's release can add a hook event AgentBar does not hear yet. Checked
  against the installed builds on 2026-11-23 (Claude Code 2.1.330, codex-cli
  0.157.0, Gemini CLI 0.50.0, Copilot CLI 1.0.85); codex-cli 0.171.0 is out and
  not yet checked.

### Done this cycle

- Claude Code's MCP input requests, API-error turn ends and subagent start/stop
  are on the row (1.65.0).
- Keystroke approval for Codex verified at a real prompt; Copilot answers by its
  hook (1.65.0). [#1](https://github.com/michalstrnadel/AgentBar/issues/1)
- 1.57.0–1.64.0: the approval card's blast radius and queue, MCP rules, task
  progress, the away recap, Over the shoulder, a living Clawd, the Office, Replay
  and the Trust Receipt.
- Where users come from: a traffic archive and UTM links. [#21](https://github.com/michalstrnadel/AgentBar/issues/21)
- README images that match today's app. [#23](https://github.com/michalstrnadel/AgentBar/issues/23)
- "Never an implicit approval" as a tested contract, run on every release (1.56.0). [#31](https://github.com/michalstrnadel/AgentBar/issues/31)
- One file lock for the app and the Linux CLI (1.56.0). [#28](https://github.com/michalstrnadel/AgentBar/issues/28)
- Diagnostics checks wiring by event (1.56.0). [#29](https://github.com/michalstrnadel/AgentBar/issues/29)
- Rules may approve `git -C <dir>` (1.56.0). [#30](https://github.com/michalstrnadel/AgentBar/issues/30)

## Next

- **Landing page conversion and SEO.** [#27](https://github.com/michalstrnadel/AgentBar/issues/27) *(discovery)*
- **Cowork in VM mode** — blocked upstream; re-checked on each Claude desktop
  release. [#13](https://github.com/michalstrnadel/AgentBar/issues/13) *(discovery)*
- **Native Allow/Deny for Antigravity** once its `PreToolUse` decision hook fires.
  [#8](https://github.com/michalstrnadel/AgentBar/issues/8) *(discovery)*

## Later — parked behind a gate

- **Opt-in activation measurement** that keeps AgentBar local-first.
  [#32](https://github.com/michalstrnadel/AgentBar/issues/32) *(discovery)*
- **Apple notarization.** Today the app is unsigned by Apple and the install step
  explains the Gatekeeper prompt. Revisited once distribution shows people want it.
- **Pro** — one-time or yearly, for local value only (longer history, a rule
  library). Not before the Now outcome is met.
- **Team features** — only once a server does real work (shared history, routing
  approvals to a team). Per seat, never speculative.

## What AgentBar won't do

- Its own model, or AI that decides for you.
- An IDE, or worktree orchestration.
- Reselling tokens, or routing your sessions through a cloud.
- Resuming agents on its own.
- Telemetry without opt-in.

## Suggesting something

Open an issue. Say what you were doing when you missed it — the situation helps
more than the feature.
