# Contributing to AgentBar

Thanks for your interest! AgentBar is intentionally small — please keep it that way.

## Ground rules

1. **One file, one responsibility.** Keep the unit layout from
   `docs/specs/2026-07-23-agentbar-design.md`; don't grow a god-object controller.
2. **Stay out of the way.** No dock icon, no heavy dependencies, nothing that
   unfolds over the screen on its own. Two surfaces only — the menu bar item
   (`StatusItemController`) and the island (`IslandController`) — both fed from
   the same stores through `MascotDriver` / `AgentActions`; never render one from
   the other's code. Windows are the exception, not the pattern: only
   `WelcomeWindow` and `SettingsWindow`, both small, both opened by the user.
3. **Hooks must never block the host agent** — async, atomic writes, exit fast.
   Sole exception: `permission.js` (see the comment at its top).
4. **Adding an agent** = one entry in `Agents.swift`, a sprite in
   `Sources/AgentBar/Sprites/`, optionally a hook dir in `Scripts/hooks/<agent>/`
   plus its installer step in `HookInstaller.swift` and the Linux CLI's
   `install-hooks`, and the agent id in the `docs/protocol.md` list, the README
   agent table and the agent list in `CLAUDE.md`. If it gets hooks it also needs a
   row in the `Diagnostics.integrations` table and the Linux `doctor`'s, or
   diagnostics reports a clean bill of health for an integration it never looked
   at (same checklist as `CLAUDE.md` rule 5). Nothing else should need touching.
5. Third-party marks belong in `THIRD_PARTY_NOTICES.md`.

## Developing

```bash
./Scripts/build.sh                        # builds build/AgentBar.app (universal)
./Scripts/build.sh --native               # this Mac's architecture only — see below
open build/AgentBar.app
swift test                                # Swift unit tests (needs Swift 6)
./Scripts/test/permission-hook-test.sh    # Claude hook protocol tests
./Scripts/test/bridge-hooks-test.sh       # cursor/gemini/antigravity/codex bridge tests
./Scripts/test/opencode-plugin-test.sh    # OpenCode plugin driven through its event bus
./Scripts/test/cli-test.sh                # cross-platform CLI tests
node --test Scripts/cloud/test/*.test.js  # cloud poller tests
AGENTBAR_LIVE_TESTS=1 ./Scripts/test/antigravity-watcher-test.sh # live-app test: opt-in, because while it
                                          # runs its sessions are real ones on your island
AGENTBAR_LIVE_TESTS=1 ./Scripts/test/cowork-watcher-test.sh     # the same, with Claude.app running too
```

`swift build` works for quick compile checks and SourceKit-LSP; the shippable app
(bundle, Info.plist, hooks) comes from `./Scripts/build.sh`. `docs/testing.md`
says what each suite covers and how to add to it.

**If the universal build fails to link x86_64**, you are on a machine with only
the Command Line Tools. Recent versions ship `libswiftCompatibility*.a` for arm64
alone, and the error looks like this:

```
ld: warning: ignoring file libswiftCompatibility56.a: fat file missing arch 'x86_64'
Undefined symbols for architecture x86_64: "__swift_FORCE_LOAD_$_swiftCompatibility56"
```

Use `./Scripts/build.sh --native` for a bundle you can actually run. It is a dev
build only — releases stay universal, and are cut from CI (see **Releases**).

**Testing a hook change needs a rebuild.** `HookInstaller` re-copies the scripts
from the app bundle into `~/.agentbar/hooks/` on every launch, so editing the
copy in `~/.agentbar/` is overwritten the next time AgentBar starts. Edit the
repo, rebuild, relaunch.

**Quit any installed copy before testing a dev build.** Two AgentBars running at
once both watch *and write* `~/.agentbar/state.d/`, so they overwrite each other's
rows — the two live-app suites go red in ways that look like watcher bugs and
aren't. `pkill -f AgentBar` first, then launch the one you mean to test.

**`AGENTBAR_HOME` points everything at another state root.** Set to an absolute
path, it replaces `~/.agentbar` for the app, the hooks, the CLI and the cloud
poller (`docs/protocol.md`, "Where state lives"), so a sandbox or a second dev
copy never touches your real sessions, rules or ledger:
`AGENTBAR_HOME=$(mktemp -d) Scripts/cli/agentbar report --agent x --state tool`.
It does not move agent configs, which is why `install-hooks`, `wire` and `unwire`
refuse to run under it — to test wiring, borrow `HOME` instead, and always as
`env -u CLAUDE_CONFIG_DIR -u COPILOT_HOME -u CODEX_HOME HOME=$(mktemp -d) …`, or an
inherited config dir points your real agent at the throwaway hooks. A relative
value is refused by the CLI and ignored by the hooks.

**macOS re-asks for folder permissions on every rebuild** unless you sign with a
stable identity: TCC keys its grants to the signing certificate, and the ad-hoc
fallback (`-s -`) is a brand-new identity each build. Create a local cert once
and `build.sh` picks it up by name automatically:

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout k.pem -out c.pem -subj "/CN=AgentBar Local Signing" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE"
openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -out i.p12 -inkey k.pem -in c.pem -passout pass:x        # transient p12, deleted below
security import i.p12 -k ~/Library/Keychains/login.keychain-db -P x -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db c.pem           # may ask for your login password once
rm k.pem c.pem i.p12
```

A differently named cert works via `AGENTBAR_SIGN_ID="My Cert" ./Scripts/build.sh`.

Which surface you get is a `UserDefaults` key, so you can flip it without the
welcome window:

```bash
defaults write com.michalstrnadel.agentbar presentationMode -string island  # or menuBar / both
defaults delete com.michalstrnadel.agentbar showWelcomeOnLaunch             # first-run window back
defaults write com.michalstrnadel.agentbar islandExpandDebug -bool true     # hold the island open (layout work)
defaults write com.michalstrnadel.agentbar islandGameDebug -bool true       # open Take a break on launch (island)
defaults write com.michalstrnadel.agentbar islandGameDebug hunt            # open Bug Hunt on launch (island)
defaults write com.michalstrnadel.agentbar settingsOnLaunchDebug -bool true # open Settings on launch (layout work)
defaults write com.michalstrnadel.agentbar settingsPageDebug agents     # …on that page (general, agents, rules, diagnostics, …)
./build/AgentBar.app/Contents/MacOS/AgentBar --render-settings /tmp/settings.png   # every settings page as one picture
./build/AgentBar.app/Contents/MacOS/AgentBar --render-break-game /tmp/break.png   # Take a break: title, play, paused, game over — offscreen
./build/AgentBar.app/Contents/MacOS/AgentBar --render-hunt-game /tmp/hunt.png     # Bug Hunt: title, walk-in, flight, hit, catch, fly-away, game over — offscreen
/Applications/AgentBar.app/Contents/MacOS/AgentBar --quota-status                 # can Claude's quota be read here, and
                                                                           # if not, why — macOS decides Keychain access
                                                                           # on the signature, so run the *bundle's*
                                                                           # binary, not .build/debug/AgentBar
defaults write com.michalstrnadel.agentbar launcherOnLaunchDebug -bool true # open the launcher on launch — it closes
                                                                           # the instant it loses focus, which is what
                                                                           # happens when you go and look at it
defaults write com.michalstrnadel.agentbar notifyProbeDebug -bool true      # ask for notification permission at launch and
                                                                           # write the answer to ~/.agentbar/notify-probe.txt
defaults write com.michalstrnadel.agentbar notifyQuietDebug -bool true      # "all quiet" after 10s instead of 2min, and
                                                                           # without waiting for you to leave the keyboard
```

Two surfaces can be rendered offline instead of being caught on screen:

```bash
swift run AgentBar --render-sounds /tmp/cues       # the four cues, as WAVs, with assertions
swift run AgentBar --render-usage /tmp/meters.png  # the usage meters, every case at once
```

`--render-usage` draws a fixed set — a calm window, one near its limit, one past its
reset, a credit balance, a provider with no ceiling — because a drawn surface nobody
looks at ships with whatever it happens to look like. It is how the rows in that block
were caught being laid out bottom-up, and it is the same lesson 1.18.0's island strip
taught when one bar took 97 % of the width.

`notifyQuietDebug` exists because the honest version of that notification is close
to impossible to observe deliberately: it waits two minutes of nothing running
**and** two minutes of you not touching the machine (or a locked screen), which is
the whole reason it is not noise. With the default on you would have to walk away
to test it.

`notifyProbeDebug` writes to a *file* rather than only NSLog on purpose: an app
launched by LaunchServices has no stderr anyone can read, and launching the binary
by hand to get one changes the very thing being measured. It also reports
`authorizationStatus`, which is what actually explains a refusal —
`requestAuthorization` answers `UNErrorDomain Code=1` for everything it will not
ask about, and guessing a cause from that is how the first version of the
Notifications setting told people to move the app when the real answer was a
switch in System Settings. Once macOS has AgentBar down as **denied** it never
prompts again, so the only way back is System Settings ▸ Notifications ▸ AgentBar.

The whole app ↔ hook protocol is files in `~/.agentbar/` (`state.d/`, `requests.d/`,
`answers.d/`) — you can drive any app feature by writing JSON files there, no agent
needed. See `docs/specs/` for the design documents.

## Your first contribution

The smallest useful one is an agent AgentBar does not know yet. It needs no Swift:
any agent id renders on its own — a monogram and the name you give it — so a bridge
is a few lines that call `agentbar report` as the agent starts, works and stops
(see "Bring your own agent" in [`docs/protocol.md`](docs/protocol.md)). Put it in
`Scripts/hooks/<agent>/` with a README saying which of the agent's own hooks or
wrappers it uses, add a case to `Scripts/test/bridge-hooks-test.sh`, and open a PR.
A native mark, an entry in `Agents.swift` and an installer step can come later —
the list under **Adding an agent** above is what that takes.

Issues labelled [`good first issue`](https://github.com/michalstrnadel/AgentBar/labels/good%20first%20issue)
are picked to be done in an evening.

## Pull requests

- Conventional Commits (`feat:`, `fix:`, `docs:`, …).
- Add or extend a test when you touch the hook protocol.
- Update `CHANGELOG.md` for user-visible changes, and end your entry with
  `— thanks @you (#PR)`. Every change from outside this repo is credited where the
  release notes are read; that is the only place credit is given.
- CI must be green (build + hook tests).

## Demo GIFs

`Scripts/demo/make-gifs.sh` regenerates the feature GIFs in `docs/assets/` from the
app's own views; see [`Scripts/demo/README.md`](Scripts/demo/README.md) for how it works
and how to add one.

## Releases

A release asset has to satisfy two things that no longer fit on one machine. It
must be **universal**, and it must be signed with the **"AgentBar Local Signing"**
identity — that lives in one keychain, and changing the signature makes macOS
re-ask every user for folder access on update, which is the whole reason a stable
identity exists. It is also what the in-app updater checks a download against: an
installed copy only installs a bundle that satisfies its own designated requirement,
so a release signed with any other identity is refused by every install
("Update could not be verified") and has to be installed by hand. A machine with only the Command Line Tools cannot link x86_64 at
all, and CI has no access to the certificate. So CI builds and verifies the
universal bundle, and it is signed locally.

1. Bump `VERSION` in `Scripts/build.sh`, date the `CHANGELOG.md` section.
2. Commit as `chore: release X.Y.Z — …` and push. Wait for CI to go green.
3. Download the bundle CI built and verified, then sign it here:
   ```bash
   # The selector release-provenance.yml uses: the successful push run of this
   # commit, never just the newest run of any event or branch.
   RID=$(gh run list --workflow ci.yml --commit "$(git rev-parse HEAD)" --event push \
     --status success --limit 1 --json databaseId -q '.[0].databaseId')
   gh run download "$RID" -n AgentBar-app-universal -D /tmp/rel
   cd /tmp/rel && ditto -xk AgentBar.app.zip .
   codesign --force --deep -s "AgentBar Local Signing" AgentBar.app
   mkdir ci && mv AgentBar.app.zip ci/
   ditto -c -k --sequesterRsrc --keepParent AgentBar.app AgentBar.app.zip
   ```
   `ditto`, not `zip`: a plain zip of a `.app` loses symlinks and resource forks.
4. Check the asset before publishing it — this is what every user downloads:
   ```bash
   codesign --verify --deep --strict AgentBar.app
   codesign -dvvv AgentBar.app 2>&1 | grep Authority   # AgentBar Local Signing
   lipo -archs AgentBar.app/Contents/MacOS/AgentBar    # x86_64 arm64
   /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" AgentBar.app/Contents/Info.plist
   Scripts/dev/verify-release.sh /tmp/rel/ci/AgentBar.app.zip AgentBar.app.zip
   ```
   The last line proves the asset is the CI build with a new signature and
   nothing else — the same check `release-provenance.yml` runs on the published
   asset before attesting it.
5. `Scripts/dev/release-notes.sh X.Y.Z > /tmp/notes.md`, then
   `gh release create vX.Y.Z AgentBar.app.zip --title "…" --notes-file /tmp/notes.md`.
   The notes are the CHANGELOG section and nothing else: the app shows the same
   section from the CHANGELOG it bundles (Settings ▸ What's New, and before an
   update installs), so GitHub and the app say the same thing. Edit the CHANGELOG,
   not the release page — a test fails when the top section is not this version. The
   asset **must** be named `AgentBar.app.zip` and the tag `vX.Y.Z`: `UpdateChecker`
   looks up exactly that name under `releases/latest` and strips the leading `v`
   to compare versions. A different name ships an update nobody can install.
6. Update `Casks/agentbar.rb` in `michalstrnadel/homebrew-tap`: bump `version`,
   set `sha256` to the output of `shasum -a 256 AgentBar.app.zip`, push, then
   verify with `brew audit --cask michalstrnadel/tap/agentbar` (and
   `brew style` on the tap checkout).
7. Publishing the release starts `release-provenance.yml`. Wait for it, then check
   the download answers for itself:
   ```bash
   gh release download vX.Y.Z -p AgentBar.app.zip -D /tmp/check
   gh attestation verify /tmp/check/AgentBar.app.zip -R michalstrnadel/AgentBar
   ```
   A failed run means the asset is not the CI build re-signed; it gets no
   attestation, and it should not stay published.

### Moving to a Developer ID (notarization)

Releases are signed with the project's own certificate and not notarized, so a zip
downloaded by hand meets Gatekeeper's "cannot verify" dialog (the cask and the
install script clear quarantine instead). Notarization needs an Apple Developer
account; the tooling is ready for the day there is one, in this order:

1. **Bridge release, old certificate.** Every copy in the field pins the old
   certificate (`UpdateSignature`) and would refuse a Developer ID release, with a
   click or without. Add the new signer to `UpdateSignature.successors`
   (`anchor apple generic and identifier "com.michalstrnadel.agentbar" and
   certificate leaf[subject.OU] = "<TEAM ID>"`) and release that as usual. Wait
   until most installs have updated — automatic updates make that days, not weeks.
2. **First notarized release.** In step 3 above, replace the `codesign` line with
   `Scripts/dev/notarize.sh AgentBar.app` (hardened runtime, the Apple Events
   entitlement in `Scripts/dev/AgentBar.entitlements`, notarytool, staple,
   Gatekeeper check). It refuses to run until step 1's line is in the source.
   Verify with `AGENTBAR_SIGN_ID="Developer ID Application: … (TEAM ID)"
   Scripts/dev/verify-release.sh …`, and set the same identity in
   `release-provenance.yml`.
3. **Then:** drop the quarantine strip from the cask and `Scripts/install.sh`, the
   "Open Anyway" steps from the README, and empty `successors` again a few releases
   later.
