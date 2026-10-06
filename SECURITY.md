# Security Policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting on this repository
(Security ▸ Report a vulnerability) rather than a public issue. You should get a
response within a few days.

## Scope notes

AgentBar's remote-approval feature is security-relevant by nature. Design
guarantees worth knowing when auditing:

- Everything is same-user, local filesystem — the app ↔ hook protocol is JSON
  files under `~/.agentbar/`, and nothing about a session ever leaves the machine.
- Three destinations exist, all in the app and none on the approval path: the
  daily update check against GitHub Releases (and the download of a newer release,
  installed automatically only if its signature matches the running app's — see
  "Verifying a download"); and — **only** while
  **Settings ▸ Usage** is ticked, off by default — Claude's own quota, either a `GET`
  to `api.anthropic.com/api/oauth/usage` or, after **Sign in to Claude…**, `claude.ai`
  (described below). That one reads the
  OAuth token Claude Code stored (Keychain item `Claude Code-credentials`, so macOS
  raises its own consent dialog the first time — and **only ever in answer to
  *Check now***: that record belongs to another application, its dialog returns
  after every reinstall, and nothing on a timer is allowed to raise it. An Allow is
  remembered and the five-minute refresh reads quietly from then on; a Deny shuts
  the door until somebody presses the button again), sends it to Anthropic and nowhere
  else, keeps it only for the duration of the request, never logs it, and never
  refreshes it — an expired token simply means no reading until the CLI renews it.
  It reads exactly one field, `claudeAiOauth.accessToken`, and never searches that
  record for a token by name: **the same Keychain record holds an `accessToken` for
  every MCP server you have authorised**, and 1.19.0–1.23.0 could pick one of those
  and send it to Anthropic. Fixed in 1.24.0; if you had the switch on in those
  versions, rotating any MCP OAuth login you had authorised is the cautious move.
  Where Claude Code signs in under its own `CLAUDE_CONFIG_DIR`, that login is kept
  where AgentBar cannot read it; **Settings ▸ Usage ▸ Use a token…** takes one from
  `claude setup-token` instead. That token *is* stored — in AgentBar's own Keychain
  item (`AgentBar-claude-quota`), never in a file, never logged, used for nothing but
  that one request, and removed by the same button. It is the only secret this app
  stores, and nothing is stored unless somebody pastes it in.
  The third way in is **Settings ▸ Usage ▸ Sign in to Claude…**, which opens
  claude.ai's login page in a WebKit window and leaves the session cookie in
  AgentBar's own cookie store. Two GETs to `claude.ai/api/organizations` and
  `…/usage` carry it, with `httpShouldSetCookies` off so the shared storage never
  acquires a session as a side effect. AgentBar does **not** read any browser's
  cookie store, nor any other application's credentials, for this or anything
  else. **Sign out** empties the store.
  See `Sources/AgentBar/ClaudeQuota.swift` and `ClaudeWeb.swift`.
- "Always allow" can only persist a rule that Claude Code itself suggested for
  that request: the hook structurally compares the answer's rule against the
  received `permission_suggestions` and downgrades anything else to a one-shot
  allow (`Scripts/hooks/claude/permission.js`).
- **Rules (1.28.0 and later) are the only thing that answers without a click**, and
  every property below is load-bearing. A rule is created only by the user, in
  Settings ▸ Rules or by editing `~/.agentbar/rules.json`; it is never derived
  from a `ruleSuggestion`, because that is produced by the agent being guarded. A
  rule that **denies** may be broad. A rule that **approves** must name one
  directory, and matching its `shape` is not enough on its own — `RuleEngine.refusal`
  re-reads the live command and falls through to the human on a chained, piped,
  redirected or substituted line (the shape of a chain is the shape of its head, so
  this one is not optional), on `sudo` and friends, on a shell or an interpreter
  handed a snippet (`sh -c`, `node -e`: the name describes one act and the arguments
  perform another), on wrappers such as `env` and `command` — read through, not
  around, because the shape was taken from the word underneath them — on destructive
  or history-rewriting subcommands, on anything reaching off the machine, on a path
  outside the rule's directory **including the command's own path**, and on any path
  that configures permission itself, whether or not it is written with a separator —
  `~/.agentbar`, an agent's settings directory, `.git/hooks`, `.git/config`. A path
  is checked twice — as written, and with its symbolic links followed — so a link
  inside the directory that leads out of it is outside. An option in front of a
  tool's subcommand (`git -c …`, `git --config-env=…`) and an option that hands git
  a program to run (`grep -O`, `--ext-diff`, `--textconv`) are refused, and so is a
  command long enough to have been cut by the hook (F21). No
  setting disables that table, and anything the engine cannot parse is a refusal.
  A rule also has a **watching** mode, which new rules start in: it matches and
  works out the answer, writes down what it would have done, and answers nothing,
  so an approving rule can be judged on a week of evidence before it speaks.
  Every firing appends a `decisions.jsonl` row carrying `via:"rule"` and the rule's
  id (a watching rule's row says `decision:"watch"`, which is not a verdict and is
  counted by nothing as one); one invalid rule voids the whole file and Diagnostics reports it, because a
  rule that quietly stopped applying looks identical to AgentBar behaving normally.
  See `Sources/AgentBar/RuleEngine.swift`.
- **The `agentbar://` URL scheme shows things and decides nothing.** Any web page
  can open such a link, so there is no command that approves, denies, answers, writes
  a rule, changes a setting or runs anything — only `focus`, `new-task`, `settings`
  and `welcome`. `new-task` opens the launcher filled in and still waits for Return,
  with the hint line saying the contents came from a link. Anything the parser does
  not recognise exactly is dropped without a sound or a dialog; `cwd` must be an
  absolute, existing, plainly spelled directory and a prompt is capped at 2,000
  characters, with control and invisible formatting characters taken out. See
  `Sources/AgentBar/URLCommands.swift` and `docs/url-scheme.md`.
- **Every failure degrades to the agent's own prompt, never to an approval.** This
  is the one guarantee the rest of the product is built on, so it is written out
  below as a numbered contract rather than a sentence, and each clause is a test
  that runs on every release.

### The fall-through contract

`permission.js` writes a decision to stdout, and **writing nothing means "no
decision"** — the host falls back to asking at its own terminal. Every clause below
is a path that must write nothing, and each is a test that runs on every release:
F1–F14 in `Scripts/test/permission-hook-test.sh`, which names them by number and
runs in CI on macOS and Linux; F15–F18 in `RuleEngineTests` and `RulesStoreTests`,
which carry the same numbers in their doc comments. `grep -rn "F17"` finds the
clause and the test that holds it to, which is the point of numbering them: a
clause whose test nobody can find is a clause somebody can delete.

| # | When | Why it cannot be an approval |
|---|---|---|
| F1 | No frontend is running | Nobody could have looked at it |
| F2 | stdin never closes within 1 s | The hook has no request to show |
| F3 | stdin is empty | as F2 |
| F4 | stdin is not valid JSON | as F2 |
| F5 | The payload is not an object | as F2 |
| F6 | Anything throws — setting up, or in a poll tick | The wait ended without an answer being read |
| F7 | The answer file is unreadable or junk | An answer nobody can parse is not an answer |
| F8 | The answer says `defer`, or a verb we do not know | Deferring is explicitly not deciding |
| F9 | The answer carries another hook's `hookPid` | It answers a request this hook is not showing |
| F10 | The request file stopped being ours | A successor hook owns it now |
| F11 | The frontend quit mid-wait | Nobody is there to have answered |
| F12 | The wait times out (600 s, `AGENTBAR_APPROVAL_TIMEOUT`) | Silence is not consent |
| F13 | SIGTERM or SIGINT | The host is taking the prompt back |
| F14 | A question's answer is malformed, or answers something that was not asked | as F7 |
| F15 | No rule matches | Nothing is written to `answers.d` at all |
| F16 | The rules file is malformed, or its version is newer than this build | The whole file is void, never partly applied |
| F17 | A rule's `mode` cannot be read | Void — never read as "answering" |
| F18 | The live command trips the refusal table | Falls through, and no setting turns that table off |
| F19 | The request file carries a string starting with U+FEFF, which the app's JSON reader drops | The command the engine would check is not the one that runs |
| F20 | The rules file repeats a key, has a trailing comma, or a field of the wrong type | as F16 — the app and the CLI used to read such a file differently |
| F21 | The command is 2,000 units or longer — where the hook cuts it | The tail, where a second command would sit, was never read |
| F22 | The rule's ledger row cannot be written | An answer nobody clicked may only exist with the row naming its rule |

The asymmetry in F16 and F17 is deliberate: an unreadable policy file must fail
towards asking, never towards allowing.
- Keystroke approval for non-Claude agents requires the user to grant the
  Accessibility permission and a per-prompt click on an explicitly labeled item.

### The Claude Code mod

`Scripts/mods/claude` runs **inside** Claude Code's process when the person turns it
on (off by default; Settings ▸ Agents ▸ Claude Code mod, or `agentbar wire
claude-mod`), with the person's permissions — as every mod does. What keeps it a
witness and nothing more:

- Every hook calls `next` and returns exactly what it returned. It never answers a
  `tool.check`, never refuses a `tool.call`, never rewrites a prompt, and writes no
  file in `answers.d`. A failure in its own bookkeeping is caught and the result is
  passed through regardless.
- What it may call is pinned. `Scripts/test/mod-test.sh` runs `claude plugin validate
  --json --strict` in CI and fails if its hooks or calls leave this list:
  hooks `session.start`, `session.end`, `session.measure`, `turn.complete`,
  `agent.spawn`, `tool.check`, `tool.call`, `ui.render` (the `AbovePrompt` band);
  calls `env.get` (`AGENTBAR_HOME`, `HOME`), `fs.read/write/list/exists/stat`,
  `session.id/cwd/usage`, `clock.now/after/every`, `ui.resolve/invalidate`, and
  `process.run` — only `/usr/bin/open agentbar://focus?…`, from the band's Jump
  button, which can focus a terminal and nothing else (CLAUDE.md rule 2). No network.
- What it reads is AgentBar's own folder: `state.d/` (its own session's row, to know
  AgentBar's hooks are there, and the others' for the band), other sessions' sidecars
  in `mods.d/` (a held call, for the band), `mods.d/.prompted-<session>` (the time of
  the newest prompt, written by AgentBar's permission hook — how auto mode is told
  apart from you) and `mods/config.json`.
- It writes only into `~/.agentbar/mods.d/` (or `$AGENTBAR_HOME`). Turning it off
  removes AgentBar's entry from `env.CLAUDE_CODE_PLUGIN_DIRS` and nothing else,
  backed up and shown as a diff first, like every other settings write.

Reports that break any of these guarantees are exactly what we want to hear about.

## Verifying a download

The app is signed with the project's own certificate, not Apple's, so its
signature proves the bundle was not changed after signing and nothing about where
it came from — on its own. The in-app updater, which installs without a click,
leans on it differently: before a downloaded bundle replaces the running one, its
signature must be valid for every architecture under strict validation and must
satisfy the **running app's designated requirement** — for a release, its bundle
identifier and the hash of the certificate that signed it. Only a bundle signed with
the same key passes; trust is placed in whichever copy was installed first, and
pinned from then on. The check runs once when the update is staged and again right
before the swap, on top of TLS to GitHub and a check that the bundle is the version
the release named. A bundle that fails is deleted, nothing is installed, the reason
goes to Console, and the download is retried at most once a day. A build signed
ad-hoc (a dev build without the local identity) has a requirement only it can
satisfy, so it never installs an update by itself; its **Install & Relaunch** is
the unchecked click it always was. Replacing the release certificate would make
every installed copy refuse the next update, which would then have to be installed
by hand. Provenance answers the part a signature cannot. From 1.28.1 on, every release asset is
attested after a check that it is exactly the bundle CI built from the tagged
commit, with the signature replaced and nothing else:

```bash
gh release download -R michalstrnadel/AgentBar -p AgentBar.app.zip   # latest; or name a tag
gh attestation verify AgentBar.app.zip -R michalstrnadel/AgentBar
```

A passing check says this zip is the one `release-provenance.yml` verified against
the CI build of that tag — which files, which commit, which run — and that anyone
can read that code. It does not say the code is safe; that is what reading it, and
the CodeQL and SBOM results beside it, are for. The comparison itself is
`Scripts/dev/verify-release.sh`, and it can be run by hand on a CI artifact and a
release asset.
