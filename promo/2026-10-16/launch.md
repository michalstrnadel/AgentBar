# Community launch — rules-checked drafts and a calendar

Issue #25. Researched 2026-10-16. Nothing here has been posted.

**How the Reddit rules were read.** Reddit blocked every direct fetch, so the rules
quoted below are verbatim from Wayback Machine snapshots of
`old.reddit.com/r/NAME/about/rules/` taken July–August 2026 (snapshot date per
community). **Open the live rules page the day before each post** — mods change them.
Flairs listed are the ones seen on archived front pages, not the full list. Member
counts are approximate (gummysearch.com).

**Repo facts the rules check against:** created 2026-07-23, 9 stars, 4 forks, MIT.

**Unknown that decides half the calendar:** the Reddit account's karma and age.
Check it before 2026-10-20. Several subs need karma earned *in that sub*.

## Ground rules for every draft

- Short. First person. Say what it does and one honest limit. No adjectives
  ("powerful", "seamless", "beautiful"), no feature list, no emoji, **no em dashes**
  (r/macapps auto-removes text with them as AI-written; easier to avoid everywhere).
- Edit each draft in your own words before posting. The first Show HN was flagged
  partly for long, polished text. The drafts are deliberately plain; make them yours.
- Never the same text twice. Each draft below has its own angle.
- One GIF per post. Suggested per post below, all in `docs/assets/`.
- Say up front that you built it, and that it was built with Claude Code (true for
  this repo; r/ClaudeAI requires the disclosure).
- Be there for the first two hours to answer comments. Have
  `docs/positioning.md` ▸ "What to say when a commenter names a tool" open.
- Expect "why not CodeIsland / Vibe Island?" and "not notarized?". Answer plainly.
- Never ask anyone to upvote. r/ClaudeAI: "immediate permanent ban offence… This
  subreddit has bots in place."

## Hacker News

**Status of the first Show HN** (checked 2026-10-16):

- API `https://hacker-news.firebaseio.com/v0/item/49933357.json` →
  `{"by":"MichalStrnadel","dead":true,"id":49933357,"score":1,"time":1790948079,"type":"story"}`
  (posted 2026-10-02 13:34 UTC). Title, url and comments are not returned for a
  dead item.
- Page `https://news.ycombinator.com/item?id=49933357` shows **[flagged]**, no title.
- User `MichalStrnadel`: created 2024-01-11 (not a "green" new account), **karma 1**,
  this story is the only submission. The likely trigger is a zero-history account
  whose first act was self-promotion, plus the long polished text (inference).

So it is still flagged and dead; nobody unflagged it in two weeks.

**Rules** (https://news.ycombinator.com/showhn.html):
> "Show HN is for something you've made that other people can play with."
> "The project must be something you've worked on personally and which you're around to discuss."
> "Please make it easy for users to try your thing out, ideally without barriers such as signups or emails."
> "Please don't ask friends to upvote or comment. That's not ok on HN."

Guidelines (https://news.ycombinator.com/newsguidelines.html):
> "Please don't use HN primarily for promotion. It's ok to post your own stuff part of the time, but the primary use of the site should be for curiosity."

Reposts (https://news.ycombinator.com/newsfaq.html):
> "If a story has not had significant attention in the last year or so, a small number of reposts is ok. Otherwise we bury reposts as duplicates. Please don't delete and repost the same story."

Second-chance pool (dang, https://news.ycombinator.com/item?id=26998308):
> "If you see a submission that didn't get attention and which you think is particularly good for HN, please tell us at hn@ycombinator.com! … It's fine if it's your own article…"

Unverified: in March 2026 dang discussed throttling Show HN from new accounts
(https://keydiscussions.com/2026/03/09/hacker-news-moves-toward-restricting-show-hn-posts-amid-the-ai-slop-wave/).

**Recommended next steps**

1. **Do not repost** on your own. A flagged-then-reposted story from a karma-1 account
   is the fastest way to get the domain or account penalised.
2. **Now:** spend two to three weeks commenting normally on HN (threads you actually
   know something about: macOS, Swift, agents, hooks). Aim for some real karma and a
   comment history that is not about AgentBar.
3. **Around 2026-10-27:** email hn@ycombinator.com, plain text, short (draft below). Ask
   whether the flag can be reviewed or whether you may post a fresh Show HN. Do what
   they say.
4. **If they say yes:** post on a Tue–Thu around 13:00–14:00 UTC (8–9am US Eastern;
   Tue–Thu per https://feedbagel.com/post/optimal-posting-time-on-show-hn-revealed-through-data-analysis,
   unverified; the hour is an estimate). Earliest sensible date: 2026-11-10.
   Link the GitHub repo, not the landing page. Put the first comment up yourself
   with the text below.

**Email to hn@ycombinator.com (draft):**

> Subject: Show HN flagged: item 49933357
>
> Hi, I posted a Show HN for my app AgentBar on Oct 2 (https://news.ycombinator.com/item?id=49933357) and it was flagged within minutes. It was my first submission, and in hindsight the text was too long and too polished. The project is real: an open source Mac menu bar app I've been building since July, where Claude Code, Codex and Copilot ask for permission and you answer in one place. Repo: https://github.com/michalstrnadel/AgentBar
>
> Is it OK to post it again at some point, or would you rather put the original in the second-chance pool? I won't repost without hearing from you.
>
> Thanks, Michal

**Title (if allowed):** `Show HN: AgentBar – answer Claude Code, Codex and Copilot permission prompts from the menu bar`
(HN titles: no caps, no exclamation marks. The en dash is HN convention; a hyphen is fine too.)

**First comment (draft, keep it this short):**

> I run Claude Code and Codex in several tabs and kept missing the prompt where one of them was waiting for me. AgentBar puts those prompts in the menu bar (or under the notch) and you answer there. It uses each agent's own permission hook, so it works for Claude Code, Codex and Copilot CLI. Cursor and Gemini CLI hooks can only block, not approve, so for those it only shows status.
>
> The part I care most about: you can write rules for things you always allow, but a new rule only watches at first and writes down what it would have done. Every answer, yours or a rule's, goes into a local log.
>
> It's free, MIT, Swift. Not notarized by Apple (I sign it myself, release builds are attested, see SECURITY.md). Happy to answer anything.

## Lobsters

Rules (https://lobste.rs/about):
> "It's great to have authors participate in the community, but not to exploit it as a write-only tool for product announcements or driving traffic to their work. As a rule of thumb, self-promo should be less than a quarter of one's stories and comments."

> "Users are considered "new" for their first 70 days… New users can't … submit links to domains we haven't seen submitted before … or use tags for meta discussions or that are prone to off-topic stories (meta rant show announce satire job interview merkle-trees ask culture vibecoding)."

**Not eligible now.** Lobsters is invite-only, there is no account, and a new account
could not use `show` or `vibecoding` for 70 days. **SKIP** for this launch. If someone
who is already a member submits it on their own, the right tags are `show`, `mac`,
`vibecoding` (not `ai`: "Tag AI usage only with `vibecoding`").

## Reddit, per community

### r/ClaudeCode (~449k) — rules snapshot 2026-08-05
https://old.reddit.com/r/ClaudeCode/about/rules
> Rule 4: "No referral links, affiliate codes, account selling, shared subscriptions, disguised ads, or repeated promotion."
> Rule 5: "Simple project sharing belongs in the weekly showcase thread. Standalone Built with Claude Code posts must be detailed and explain what you built, how Claude Code was used, and what you learned."

- Where: a comment in the pinned **Weekly Showcase Thread** (no karma rule found). A
  standalone post needs the "what you learned" part; save that for later.
- Flair (standalone only): **Built with Claude**.
- When: the day after the thread is pinned, 12:00–14:00 UTC (estimate).
- GIF: `demo-island.gif`.

**Draft (showcase comment):**

> I built a small Mac app for when you have several Claude Code sessions open and one of them is stuck on a permission prompt in some tab. The prompt shows up in the menu bar or under the notch, you click Allow or Deny there. It also does Codex and Copilot CLI. Built with Claude Code, free and open source: https://github.com/michalstrnadel/AgentBar

### r/codex (~220k) — rules snapshot 2026-07-27
https://old.reddit.com/r/codex/about/rules
> Rule 1: "Posts must be directly related to Codex suite of tools."
> Rule 6: "This subreddit uses Botbouncer."

- No self-promotion rule found; keep it about Codex.
- Flair: **Showcase**.
- GIF: `demo-claude-codex.gif`.

**Draft:**

> Title: Answering Codex approval prompts from the Mac menu bar
>
> I made an open source Mac app that hooks into Codex's PermissionRequest hook, so when Codex wants to run a command you get Allow/Deny in the menu bar instead of hunting for the terminal. Codex asks you once to trust the hook before it runs. It also shows your 5h and weekly limits with reset times. Works next to Claude Code sessions too if you use both. Repo: https://github.com/michalstrnadel/AgentBar
>
> If you use the Codex desktop app rather than the CLI, it won't help yet, it's CLI only.

(Verify that last sentence before posting.)

### r/ClaudeAI (~1.2M) — rules snapshot 2026-08-23
https://old.reddit.com/r/ClaudeAI/about/rules/
> Rule 7: "Showcase your project in a way that helps educate and inspire others. Promoting your project or paid service is encouraged if it fit the following criteria: * be clear the project was built with Claude/Claude Code or specifically for Claude BY YOU * include a clear description of what was built, how Claude helped, and what it does * project must be free to try and say so (paid tiers/features OK) * promotional language minimal * do not use referral links (link to the project is ok) * no job seeking requests or resumes. **Posts on the feed now require OP karma> 50**"

- **Gate: account karma > 50.** If below, skip until it is.
- Flair: **Built with Claude**.
- GIF: `agentbar-tour.gif`.

**Draft:**

> Title: I built a menu bar app where Claude Code asks for permission, and you can write rules for it
>
> Built by me, mostly with Claude Code, over the last three months. Free and open source (MIT), no paid tier.
>
> What it does: Claude Code's permission prompts show up in the Mac menu bar or under the notch, with the exact command or a small diff. You click Allow or Deny. Deny can carry a note ("use pnpm, not npm") that Claude reads as the reason.
>
> The part I'm still figuring out is rules. If you allow the same thing five times it offers to write a rule, but the rule starts in a watching mode and just logs what it would have done. You can see after a week whether it agreed with you before letting it answer.
>
> How Claude helped: it wrote most of the Swift, and the hook scripts were tested against Claude Code itself.
>
> https://github.com/michalstrnadel/AgentBar

### r/ChatGPTCoding (~405k) — rules snapshot 2026-07-27
https://old.reddit.com/r/ChatGPTCoding/about/rules
> Rule 4: "There is a fine line between sharing your work and promoting a service. If your post falls into the latter camp, we will soon be creating a designated self-promotion thread. If you wish for you post to appear in the main sub, you can apply for a sponsorship via modmail."
> Rule 2: "Flairs are required for every post."

- Third-party sources say a **weekly self-promotion thread** now exists (unverified).
  Post there; a main-feed post is likely removed.
- GIF: `demo-claude-codex.gif`.

**Draft (self-promo thread comment):**

> AgentBar, a free Mac menu bar app for people running more than one coding agent. Claude Code, Codex and Copilot CLI permission prompts all land in one place and you answer them there. Cursor and Gemini only show status because their hooks can block but not approve. MIT: https://github.com/michalstrnadel/AgentBar

### r/cursor (~159k) — rules snapshot 2026-07-27
https://old.reddit.com/r/cursor/about/rules
> Rule 6: "Sharing your own content is acceptable if relevant and valuable. No more than 10% of your activity across Reddit should be self-promotional. Context must be provided in text posts. No promoting competing products in bad faith or spamming competitor content."
> Rule 11: "No AI generated content or low effort posting…"

- **Weak fit.** Cursor's hooks can only refuse, so AgentBar shows Cursor CLI status
  but cannot approve for it. Post only as a text post that says so, or skip. Flair:
  **Resources & Tips**.

**Draft (optional):**

> Title: What Cursor's hooks can and can't do for a third-party approval app
>
> I build an open source Mac app that answers agent permission prompts from the menu bar. For Claude Code and Codex it can approve. For Cursor CLI it can't: the hook answer is checked against "deny" and nothing else, so a third party can block a command but never allow one. So Cursor gets status only (working, waiting, done) in my app. Notes from testing are here: https://github.com/michalstrnadel/AgentBar/blob/main/docs/permission-surfaces.md
>
> Has anyone found a way around that, or is it on Cursor's roadmap?

### r/macapps (~257k) — rules snapshot 2026-08-23
https://old.reddit.com/r/macapps/about/rules/
> Rule 1: "10pt LOCAL Karma Required. Comment in r/MacApps to earn 10 karma first … Choose flair. App Devs: No main feed promotion unless you qualify + use PCP template. Flair Hierarchy: Lifetime>Subscription>Free. Free flair: not for limited app tiers. Open Source? Prefix title [OS]"
> Rule 3: "Infrequent self-promotion is permitted; however, it is not permitted more than once per developer in 30 days. This is counted from the last app post, even if it was removed. … ALWAYS disclose your relationship to your software…"
> Rule 8: "ALL who do not qualify through trust or transparency requirements must limit promotion to the monthly megathread."

Qualification (https://www.reddit.com/r/macapps/comments/1ryaeex/): Tier 1 needs an
established GitHub project (1 year and/or 100+ stars — the post says both) —
**AgentBar fails**. Tier 2 needs "a developer portfolio with a real life identity,
LinkedIn (ideal), and real contact details … A website that has a Privacy Policy and
Terms of Service". Otherwise the monthly **App Pile** megathread. Rule 9: mark the
rules as read first, or the post is likely removed and starts a 30-day cooldown.

- **Plan:** earn 10 karma in r/macapps by commenting (start now). Post in the App
  Pile megathread. Main feed only after adding a Privacy Policy and ToS to
  michalstrnadel.com/agentbar (Tier 2), and then with the PCP template.
- Flair: **Free**; title prefix **[OS]**. One post per 30 days, counted even if
  removed, so get it right once.
- GIF: `demo-island.gif`. No em dashes anywhere.

**Draft (PCP template, also fine for the megathread):**

> [OS] AgentBar: answer AI coding agent permission prompts from the menu bar or notch
>
> I'm the developer.
>
> Problem: when Claude Code, Codex or Copilot wants to run a command it waits in whatever terminal tab it's in. With a few sessions open I kept finding one that had been waiting for ten minutes.
>
> Comparison: CodeIsland and Vibe Island also put agents in the notch with Allow/Deny. AgentBar adds rules you write yourself that only watch at first, and a log of every answer. It's not notarized (self-signed, attested builds), they are.
>
> Pricing: free, MIT, no paid tier. https://github.com/michalstrnadel/AgentBar
>
> macOS 12+, menu bar, notch, or both.

### r/MacOS (~649k) — rules snapshot 2026-08-07
> Rule 7: "Self-promotion is permitted only on Saturdays (UTC). This is limited to apps available on the official Mac App Store or reputable, established GitHub repositories. All GitHub links are subject to automated security auditing via GitHub-Guard. Promotional posts made on any other day of the week will be removed."

- 9 stars, 3 months old is probably not "established". **Ask the mods by modmail
  first**; post only on a Saturday (UTC) if they say yes. Otherwise SKIP.

**Draft (if allowed):**

> Title: I made a menu bar app for answering AI coding agents' permission prompts
>
> If you use Claude Code, Codex or Copilot in the terminal: they stop and ask before running commands, and the question sits in whatever tab they're in. AgentBar shows it in the menu bar (or under the notch on MacBooks) and you answer there. Free, open source. https://github.com/michalstrnadel/AgentBar

### r/opensource (~389k) — rules snapshot 2026-07-26
> Rule 2: "Reddit recommends that <10% of your posts promote your content. We're a little more forgiving, but don't take advantage of it."
> Rule 3: "All AI-generated content is low-effort and ban worthy."
> Rule 6: "Drive-by posts from accounts where there is obviously no intention of engaging… may be removed."
> Rule 8: "Promotional is when you are sharing a project, yours or otherwise."

- Flair: **Promotional**. MIT passes Rule 4 (OSI licence). Rule 3 makes the
  write-it-yourself point non-negotiable here.

**Draft:**

> Title: AgentBar: a local-only approval queue for AI coding agents (MIT, Swift)
>
> I've been building this since July. It's a Mac menu bar app plus a Linux CLI that reads a small JSON-per-session file protocol, so any tool can report into it (`agentbar report ...`). The protocol is documented in docs/protocol.md if anyone wants to build a different front end. No telemetry, no account. https://github.com/michalstrnadel/AgentBar

### r/OpenAI (~2.9M) — rules snapshot 2026-07-28 — optional, low fit
> Rule 3: "The 1/10th rule is a good guideline: self-promotion/projects/advertising should not be more than 10% of your content here. … Self-promotional direct link posts to projects are not allowed. If you are promoting your own project, context must be provided in a text post… We want participation first for you to advertise."

r/codex is the better place for the Codex angle. **SKIP** unless the account already
participates in r/OpenAI.

### SKIP

- **r/commandline** — Rule 6: "We do not allow projects or software that interacts with generative AIs, including LLMs, unless the posts and comments are about popular projects themselves like Ollama, GGML, etc." Rule 2: "No GUI-only tools or apps."
- **r/LocalLLaMA** — Rule 2: "Posts must be related to Llama or the topic of LLMs." The audience is local models; AgentBar is about cloud agents. Off-topic.
- **r/swift** — Rule V: "If you have fewer than 5 posts/comment on the sub, or your account is less than 2 month old, self promotion is not allowed." Only if the account qualifies; then the monthly "What's everyone working on" thread.
- **r/SideProject** — no rules listed (snapshot 2026-08-28), format "[Project name] - [Short description]", but a sticky asks for "Not-AI" projects. Optional, last.

## Calendar

One community per one to two days, Tue–Thu 12:00–14:00 UTC unless noted. Times are
estimates (Olson's Reddit data study,
https://randalolson.com/2015/01/11/a-data-driven-guide-to-creating-successful-reddit-posts-redux/).

| Date | Where | What | Gate |
|---|---|---|---|
| 2026-10-16 → 19 | r/macapps, r/ClaudeAI, HN | Comment normally; earn karma. Check the Reddit account's karma | — |
| Tue 2026-10-20 | r/ClaudeCode | Comment in the Weekly Showcase Thread | Thread pinned |
| Thu 2026-10-22 | r/codex | Showcase post | — |
| Fri 2026-10-23 | r/MacOS | Modmail the mods: is a 3-month, MIT repo OK for Saturday? | — |
| Mon 2026-10-26 | r/ClaudeAI | Built with Claude post | karma > 50 |
| Tue 2026-10-27 | HN | Email hn@ycombinator.com | ~2 weeks of normal comments |
| Wed 2026-10-28 | r/ChatGPTCoding | Comment in the weekly self-promo thread | Thread exists |
| Fri 2026-10-30 | r/opensource | Promotional post | — |
| Sat 2026-10-31 | r/MacOS | Post | Mods said yes |
| Tue 2026-11-03 | r/macapps | App Pile megathread (or main feed with PCP if Tier 2 met) | 10 local karma, rules marked read |
| Thu 2026-11-05 | r/cursor | Text post about hook limits (optional) | — |
| Tue–Thu from 2026-11-10 | HN | Show HN, only if hn@ said so | Their reply |

Lobsters, r/commandline, r/LocalLLaMA, r/OpenAI: not in the calendar (see SKIP).
