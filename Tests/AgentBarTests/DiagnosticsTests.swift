import Foundation
import Testing
@testable import AgentBar

/// Everything `doctor` reports, driven from a fabricated home so the assertions
/// are about the diagnosis and not about whichever agents this machine happens to
/// have. Checks are asserted by **id**, never by wording — the text is for humans
/// and will change; the ids are the contract `docs/diagnostics.md` and the Linux
/// CLI both hold to.
@Suite struct DiagnosticsTests {
    private let home: URL

    init() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-doctor-\(UUID().uuidString)")
        for d in ["state.d", "requests.d", "answers.d", "hooks"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".agentbar/\(d)"), withIntermediateDirectories: true)
        }
        for d in Diagnostics.hookDirs {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".agentbar/hooks/\(d)"), withIntermediateDirectories: true)
        }
    }

    private func write(_ rel: String, _ text: String) throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A fixed "now" well clear of the epoch: the quiet-agent check subtracts a
    /// fortnight from it, and a smaller value would go negative and read as "no
    /// history at all" instead of "silent for a long time".
    private static let now: TimeInterval = 1_800_000_000

    private func check(_ id: String) -> Diagnostics.Check? {
        Diagnostics.run(home: home, now: Self.now).first { $0.id == id }
    }

    // MARK: - The catalogue holds together

    /// Drift between this table and the agents AgentBar actually supports is the
    /// way a diagnostic goes quietly wrong: it would report a clean bill of health
    /// for an integration it never looked at.
    @Test func everyIntegrationIsARealAgent() {
        let known = Set(Agent.all.map(\.id))
        for i in Diagnostics.integrations where !Diagnostics.nonAgentIntegrations.contains(i.id) {
            #expect(known.contains(i.id), "\(i.id) is not in Agent.all")
        }
        // …and the ones that are not agents stay out of Agent.all: a `claude-mod`
        // row in the island would be a session that never existed.
        for id in Diagnostics.nonAgentIntegrations {
            #expect(!known.contains(id), "\(id) must not become an agent")
            #expect(Diagnostics.integrations.contains { $0.id == id }, "\(id) has no integration row")
        }
    }

    // MARK: - The Claude Code mod

    /// Off is where it starts, and off is never a failure or something to repair.
    @Test func theModIsOffAndSkippedUntilSwitchedOn() throws {
        try write(".claude/settings.json", "{}")
        let row = check("agent.claude-mod")
        #expect(row?.status == .skipped)
        #expect(row?.detail?.contains("switch it on") == true)
        #expect(check("agent.claude-mod.wired") == nil)
        try write(".agentbar/wire-enabled", "claude-mod\n")
        try write(".agentbar/wire-disabled", "claude-mod\n")
        #expect(check("agent.claude-mod")?.detail?.hasPrefix(Diagnostics.turnedOff) == true)
    }

    @Test func switchedOnTheModIsCheckedEndToEnd() throws {
        try write(".agentbar/wire-enabled", "claude-mod\n")
        try write(".claude/settings.json", "{}")
        #expect(check("agent.claude-mod.copied")?.status == .fail)
        #expect(check("agent.claude-mod.copied")?.repair == .reinstallHooks)
        #expect(check("agent.claude-mod.wired")?.status == .fail)
        #expect(check("agent.claude-mod.reported") == nil)

        try FileManager.default.createDirectory(at: home.appendingPathComponent(".agentbar/mods/claude"),
                                                withIntermediateDirectories: true)
        try write(".claude/settings.json",
                  #"{"env":{"CLAUDE_CODE_PLUGIN_DIRS":"\/opt\/mine:\/Users\/x\/.agentbar\/mods\/claude"}}"#)
        #expect(check("agent.claude-mod.copied")?.status == .ok)
        #expect(check("agent.claude-mod.wired")?.status == .ok)
        #expect(check("agent.claude-mod.reported")?.status == .ok)
    }

    @Test func aClaudeCodeTooOldForModsIsTheHeadline() throws {
        try write(".agentbar/wire-enabled", "claude-mod\n")
        try write(".claude/settings.json", "{}")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/share/claude/versions/2.1.200"),
                                                withIntermediateDirectories: true)
        let row = check("agent.claude-mod.version")
        #expect(row?.status == .fail)
        #expect(row?.fix != nil)
        #expect(check("agent.claude-mod.wired") == nil)
    }

    /// Claude Code sessions since the switch, and nothing in mods.d: the shape of a
    /// mod Claude Code never loaded, which every other row passes.
    @Test func sessionsWithNoSidecarAreWorthSaying() throws {
        try write(".agentbar/wire-enabled", "claude-mod\n")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Self.now - 5 * 86_400)],
                                              ofItemAtPath: home.appendingPathComponent(".agentbar/wire-enabled").path)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".agentbar/mods/claude"),
                                                withIntermediateDirectories: true)
        try write(".claude/settings.json", #"{"env":{"CLAUDE_CODE_PLUGIN_DIRS":"/u/.agentbar/mods/claude"}}"#)
        let ended = Int(Self.now) - 86_400
        try write(".agentbar/history.jsonl",
                  #"{"agent":"claude","sessionId":"s1","startedAt":\#(ended - 60),"endedAt":\#(ended),"state":"done"}"# + "\n")
        #expect(check("agent.claude-mod.reported")?.status == .warn)

        try write(".agentbar/mods.d/s1.json", "{}")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Self.now - 3_600)],
                                              ofItemAtPath: home.appendingPathComponent(".agentbar/mods.d/s1.json").path)
        #expect(check("agent.claude-mod.reported")?.status == .ok)
    }

    /// Information, never a failure, whatever is installed.
    @Test func pluginsThatCanAnswerAreInformationOnly() throws {
        try write(".claude/settings.json", #"{"enabledPlugins":{"holder@m":true}}"#)
        let plugin = home.appendingPathComponent("p/holder")
        try write("p/holder/hooks/hooks.json", #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[]}]}}"#)
        try write(".claude/plugins/installed_plugins.json",
                  #"{"version":2,"plugins":{"holder@m":[{"scope":"user","installPath":"\#(plugin.path)","version":"1"}]}}"#)
        let row = check("claude.plugins")
        #expect(row?.status == .ok)
        #expect(row?.detail?.contains("holder") == true)
    }

    /// Ids must be unique, or the view renders two rows that look like one bug.
    @Test func checkIdsAreUnique() {
        let ids = Diagnostics.run(home: home).map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    // MARK: - Directories

    @Test func aWritableStateDirectoryPasses() throws {
        #expect(check("dirs.state.d")?.status == .ok)
    }

    @Test func aMissingDirectoryIsAFailureWithSomethingToDo() throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent(".agentbar/requests.d"))
        let c = check("dirs.requests.d")
        #expect(c?.status == .fail)
        #expect(c?.fix != nil)
    }

    // MARK: - Hook scripts

    @Test func missingHookScriptsAreAFailure() throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent(".agentbar/hooks/codex"))
        #expect(check("hooks.copied")?.status == .fail)
    }

    /// A GUI-launched Cursor inherits the launchd PATH, which usually has no node
    /// on it — so an unpinned shebang is a hook that never fires.
    @Test func anUnpinnedShebangIsAWarning() throws {
        try write(".cursor/hooks.json", "{}")   // the installer only pins what it wires
        try write(".agentbar/hooks/cursor/cursor.js", "#!/usr/bin/env node\n")
        #expect(check("hooks.shebang")?.status == .warn)
        try write(".agentbar/hooks/cursor/cursor.js", "#!/opt/homebrew/bin/node\n")
        #expect(check("hooks.shebang")?.status == .ok)
    }

    /// Without Cursor or Antigravity the bundled `env node` shebang is never pinned,
    /// and a healthy machine must not be told it has a problem.
    @Test func theShebangCheckIsSkippedForAgentsYouDoNotHave() throws {
        try write(".agentbar/hooks/cursor/cursor.js", "#!/usr/bin/env node\n")
        #expect(check("hooks.shebang")?.status == .skipped)
    }

    // MARK: - Agents

    @Test func anAgentYouDoNotHaveIsSkippedRatherThanFailed() {
        #expect(check("agent.codex")?.status == .skipped)
        #expect(check("agent.codex.wired") == nil)
    }

    /// Switched off in Settings (or in `wire-disabled` by hand): unwired on purpose,
    /// so no failure, no repair button, and no "silent for a fortnight".
    @Test func anAgentYouTurnedOffIsSkippedNotFailed() throws {
        try write(".cursor/hooks.json", "{}")
        try write(".agentbar/hooks/cursor/cursor.js", "#!/usr/bin/env node\n")
        #expect(check("agent.cursor.wired")?.status == .fail)
        #expect(check("hooks.shebang")?.status == .warn)

        try write(".agentbar/wire-disabled", "# mine\ncursor\n")
        let row = check("agent.cursor")
        #expect(row?.status == .skipped)
        #expect(row?.detail?.hasPrefix(Diagnostics.turnedOff) == true)
        #expect(row?.repair == nil)
        #expect(check("agent.cursor.wired") == nil)
        #expect(check("agent.cursor.lastSeen") == nil)
        #expect(check("hooks.shebang")?.status == .skipped)
        #expect(Diagnostics.run(home: home, now: Self.now).allSatisfy { $0.status != .fail || !$0.id.hasPrefix("agent.cursor") })
    }

    @Test func anInstalledButUnwiredAgentIsAFailure() throws {
        try write(".codex/config.toml", "model = \"o3\"\n")
        #expect(check("agent.codex.wired")?.status == .fail)
    }

    @Test func aWiredAgentPasses() throws {
        try write(".codex/config.toml",
                  "notify = [\"/bin/sh\", \"/Users/x/.agentbar/hooks/codex/notify.js\"]\n")
        #expect(check("agent.codex.wired")?.status == .ok)
    }

    /// Codex runs no hook until a human accepts it, and until then the integration
    /// is inert in the one way that looks exactly like nothing happening. The wired
    /// row cannot say this: the notify key alone satisfies it.
    @Test func codexHooksAwaitingAcceptanceAreAWarningNotAFailure() throws {
        try write(".codex/config.toml", "model = \"o3\"\n\(HookInstaller.codexBegin)\n"
                  + "command = \"/x/.agentbar/hooks/codex/hook.js\"\n\(HookInstaller.codexEnd)\n")
        let row = check("codex.hooks")
        #expect(row?.status == .warn)
        #expect(row?.fix != nil)
    }

    @Test func codexHooksAcceptedPass() throws {
        let cfg = home.appendingPathComponent(".codex/config.toml").path
        try write(".codex/config.toml", "model = \"o3\"\n\(HookInstaller.codexBegin)\n"
                  + "command = \"/x/.agentbar/hooks/codex/hook.js\"\n\(HookInstaller.codexEnd)\n"
                  + "[hooks.state.\"\(cfg):session_start:0:0\"]\ntrusted_hash = \"sha256:x\"\n")
        #expect(check("codex.hooks")?.status == .ok)
        #expect(check("codex.hooks")?.fix == nil)
    }

    /// No block, no row: a Codex user who has never had the hooks written should not
    /// be told about a trust prompt that is not coming.
    @Test func codexWithoutTheBlockHasNoTrustRow() throws {
        try write(".codex/config.toml", "model = \"o3\"\n")
        #expect(check("codex.hooks") == nil)
    }

    /// The shape AgentBar's own installer writes: `JSONSerialization` escapes forward
    /// slashes, so every macOS-written config says `\/.agentbar\/hooks\/...` on disk.
    /// Searching the raw text for the plain marker reports a perfectly wired machine
    /// as entirely unwired — which is exactly what the first live run did.
    @Test func aMarkerWithEscapedSlashesStillCounts() throws {
        let escaped = #"{"hooks":{"stop":[{"command":"\/Users\/x\/.agentbar\/hooks\/cursor\/cursor.js"}]}}"#
        #expect(escaped.contains("/.agentbar/hooks/cursor/") == false, "the raw text really does hide the marker")
        try write(".cursor/hooks.json", escaped)
        #expect(check("agent.cursor.wired")?.status == .ok)
    }

    /// Same escaping, same blindness — a dead interpreter must be found through it.
    @Test func aDeadInterpreterIsFoundThroughEscapedSlashes() throws {
        try write(".copilot/hooks/agentbar.json",
                  #"{"hooks":{"SessionStart":[{"exec":"\/nope\/bin\/node","args":["\/Users\/x\/.agentbar\/hooks\/claude\/lifecycle.js"]}]}}"#)
        #expect(check("agent.copilot.wired")?.status == .ok)
        #expect(check("agent.copilot.interpreter")?.status == .fail)
    }

    /// The exact shape the installer refuses to touch — and says so only in
    /// Console.app, which is how "Gemini just stopped appearing" happens.
    @Test func aConfigThatDoesNotParseIsNamed() throws {
        try write(".gemini/settings.json", "{\"theme\": \"dark\" // mine\n}")
        let c = check("agent.gemini.parseable")
        #expect(c?.status == .fail)
        #expect(c?.fix != nil)
    }

    /// Foundation accepts a trailing comma and Node's `JSON.parse` does not, so the
    /// same file is wired on macOS and skipped on Linux. Whatever we think of that,
    /// this side must agree with the installer standing next to it rather than call
    /// a config broken that AgentBar just wired successfully.
    @Test func aTrailingCommaMatchesWhateverTheInstallerDoes() throws {
        try write(".gemini/settings.json", "{\"theme\":\"dark\",}")
        #expect(check("agent.gemini.parseable") == nil)
    }

    /// The whole reason `doctor` exists: an interpreter that moved.
    @Test func anInterpreterThatIsGoneIsTheHeadline() throws {
        try write(".codex/config.toml",
                  "notify = [\"/Users/x/.nvm/versions/node/v20.11.0/bin/node\", \"/Users/x/.agentbar/hooks/codex/notify.js\"]\n")
        let c = check("agent.codex.interpreter")
        #expect(c?.status == .fail)
        #expect(c?.detail?.contains("v20.11.0") == true)
    }

    @Test func aLivingInterpreterRaisesNothing() throws {
        try write(".codex/config.toml",
                  "notify = [\"/bin/sh\", \"/Users/x/.agentbar/hooks/codex/notify.js\"]\n")
        #expect(check("agent.codex.interpreter") == nil)
    }

    /// A shell wrapper makes the hook's parent a shell that exits at once, and that
    /// pid is what prunes dead rows — every Copilot row would vanish on refresh.
    @Test func aShellWrappedCopilotHookIsAFailure() throws {
        try write(".copilot/hooks/agentbar.json",
                  #"{"version":1,"hooks":{"SessionStart":[{"type":"command","bash":"node /Users/x/.agentbar/hooks/claude/lifecycle.js"}]}}"#)
        #expect(check("copilot.exec")?.status == .fail)
    }

    // MARK: - Last seen

    /// The line that tells a broken integration apart from an idle one.
    @Test func lastSeenComesFromTheHistoryFile() throws {
        try write(".codex/config.toml",
                  "notify = [\"/bin/sh\", \"/Users/x/.agentbar/hooks/codex/notify.js\"]\n")
        // No record is not a problem: history only starts when AgentBar starts keeping
        // it, so a freshly updated Mac is blank everywhere and nothing is wrong.
        #expect(check("agent.codex.lastSeen")?.status == .ok)

        let threeDaysAgo = Int(Self.now - 3 * 86_400)
        try write(".agentbar/history.jsonl",
                  #"{"agent":"codex","sessionId":"a","state":"done","endedAt":"# + "\(threeDaysAgo)}\n")
        let c = check("agent.codex.lastSeen")
        #expect(c?.status == .ok)
        #expect(c?.detail?.contains("3 days ago") == true)
    }

    /// Wired and silent for a fortnight is the shape of a broken integration that
    /// passes every other check: the hooks are in place and simply never fire.
    @Test func anAgentWiredButLongSilentIsWorthSaying() throws {
        try write(".codex/config.toml",
                  "notify = [\"/bin/sh\", \"/Users/x/.agentbar/hooks/codex/notify.js\"]\n")
        let longAgo = Self.now - Double(Diagnostics.quietDays + 3) * 86_400
        try write(".agentbar/history.jsonl",
                  #"{"agent":"codex","sessionId":"a","state":"done","endedAt":"# + "\(Int(longAgo))}\n")
        let c = check("agent.codex.lastSeen")
        #expect(c?.status == .warn)
        #expect(c?.fix != nil)
    }

    // MARK: - Leftovers

    @Test func aRequestPastItsPruningWindowIsAWarningNotAnAlarm() throws {
        let url = home.appendingPathComponent(".agentbar/requests.d/old.json")
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                                              ofItemAtPath: url.path)
        #expect(check("orphans")?.status == .warn)
    }

    // MARK: - The report

    @Test func theReportNamesEveryCheckAndItsFix() throws {
        try write(".codex/config.toml", "model = \"o3\"\n")
        let checks = Diagnostics.run(home: home, now: Self.now)
        let text = Diagnostics.report(checks)
        #expect(text.contains("agent.codex.wired"))
        #expect(text.contains("fix:"))
        for c in checks { #expect(text.contains(c.id)) }
    }

    // MARK: - nodePaths

    @Test func nodePathsFindsInterpretersInAnyConfigShape() {
        let toml = "notify = [\"/opt/homebrew/bin/node\", \"/x/notify.js\"]"
        #expect(Diagnostics.nodePaths(in: toml) == ["/opt/homebrew/bin/node"])
        let json = #"{"exec":"/usr/local/bin/node","args":["/x/y.js"]}"#
        #expect(Diagnostics.nodePaths(in: json) == ["/usr/local/bin/node"])
        // A script path that merely lives under a directory called node must not be
        // mistaken for the interpreter.
        #expect(Diagnostics.nodePaths(in: #"{"a":"/x/node/y.js"}"#).isEmpty)
    }
    // MARK: - The fixes the app can carry out itself

    /// A fix in words is an instruction; a fix with a button is a fix. Only where it
    /// is genuinely AgentBar's to make, though — a `chmod` on a path in somebody's
    /// home stays a sentence.
    @Test func onlyTheFixesAgentBarCanMakeCarryOne() throws {
        try write(".codex/config.toml", "model = \"o3\"\n")
        #expect(check("agent.codex.wired")?.repair == .reinstallHooks)
        #expect(check("hooks.copied")?.repair == nil)   // the dirs exist in this fixture
        // A passing check never offers one: there is nothing to do.
        #expect(check("dirs.state.d")?.status == .ok)
        #expect(check("dirs.state.d")?.repair == nil)
    }

    @Test func makingTheDirectoriesMakesThem() throws {
        let base = home.appendingPathComponent(".agentbar-fresh", isDirectory: true)
        #expect(Diagnostics.apply(.makeDirectories, base: base))
        for name in ["state.d", "requests.d", "answers.d"] {
            #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path))
        }
    }

    /// Sweeping uses the same windows the pruning rules do, so the button removes
    /// exactly what a running AgentBar would have removed anyway — and nothing else.
    @Test func sweepingTakesTheStaleAndLeavesTheLive() throws {
        let base = home.appendingPathComponent(".agentbar", isDirectory: true)
        let fm = FileManager.default
        let fresh = base.appendingPathComponent("requests.d/fresh.json")
        let stale = base.appendingPathComponent("requests.d/stale.json")
        try Data().write(to: fresh)
        try Data().write(to: stale)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)],
                             ofItemAtPath: stale.path)

        #expect(Diagnostics.apply(.sweepOrphans, base: base))
        #expect(fm.fileExists(atPath: fresh.path))
        #expect(!fm.fileExists(atPath: stale.path))
    }

    // MARK: - The approval self-test

    /// The self-test reports one of two silences, and it used to pick between them
    /// by asking the hook's exit code — which is 0 down every fall-through path,
    /// because that is exactly what the contract requires. So one wording was
    /// always right and the other was unreachable. The clock is what actually
    /// separates them.
    @Test func aHookThatWaitedItsWholeDeadlineTimedOut() {
        #expect(ApprovalSelfTest.silence(after: 90, timeout: 90) == .timedOut)
        #expect(ApprovalSelfTest.silence(after: 88.5, timeout: 90) == .timedOut)
    }

    @Test func aHookThatCameBackEarlyNeverReachedACard() {
        #expect(ApprovalSelfTest.silence(after: 0.2, timeout: 90) == .fellThrough)
        #expect(ApprovalSelfTest.silence(after: 30, timeout: 90) == .fellThrough)
    }

    /// Both readings are true statements about the wiring rather than about a
    /// decision: neither may ever read as one.
    @Test func neitherSilenceClaimsADecisionWasMade() {
        for outcome in [ApprovalSelfTest.silence(after: 90, timeout: 90),
                        ApprovalSelfTest.silence(after: 1, timeout: 90)] {
            #expect(!outcome.line.contains("allow"))
            #expect(!outcome.line.contains("deny"))
        }
    }

}
