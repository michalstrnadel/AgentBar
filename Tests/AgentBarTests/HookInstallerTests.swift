import Foundation
import Testing
@testable import AgentBar

/// The two silent failures that motivated `agentbar doctor`, both of which came
/// down to a node path written into a config that outlives the next node upgrade.
/// Neither had a test, and neither announced itself when it broke — the rows just
/// stopped appearing.
@Suite struct HookInstallerTests {
    private static let script = "/Users/x/.agentbar/hooks/codex/notify.js"

    // MARK: - Codex: a moved interpreter has to be repaired, not preserved

    /// The regression. A config that is already ours but names a node that no longer
    /// exists must be rewritten; the old code returned at the marker and left it.
    // MARK: - The hooks block, which is the real Codex integration

    /// Codex speaks Claude's hook dialect, so the whole integration is one block of
    /// TOML pointing at the shared scripts. These assert the two promises the notify
    /// line already keeps: everything outside survives byte for byte, and a second
    /// copy is never appended.
    @Test func codexHooksBlockCarriesEveryEventAndItsOwnTimeout() {
        let plan = HookInstaller.codexHooksPlan(config: "model = \"o3\"\n",
                                                node: "/opt/homebrew/bin/node", dir: "/h")
        guard case .write(let next, let replaced) = plan else {
            Issue.record("a fresh config must produce a write, got \(plan)"); return
        }
        #expect(!replaced)
        #expect(next.hasPrefix("model = \"o3\"\n"))
        for e in HookInstaller.codexEvents {
            #expect(next.contains("[[hooks.\(e.event)]]"))
        }
        // The blocking one outlasts permission.js's own 600s wait, so the hook gives
        // up first and falls through to Codex's prompt rather than being killed.
        #expect(next.contains("command = \"\\\"/opt/homebrew/bin/node\\\" \\\"/h/codex/hook.js\\\" permission.js\"\ntimeout = 630"))
        // Codex clamps SessionEnd to 3s; asking for more earns a warning every session.
        #expect(next.contains("\"/h/codex/hook.js\\\" lifecycle.js end\"\ntimeout = 3"))
        #expect(next.contains("statusMessage = \"Waiting for you in AgentBar\""))
    }

    @Test func codexHooksBlockIsIdempotent() {
        guard case .write(let once, _) = HookInstaller.codexHooksPlan(
            config: "model = \"o3\"\n", node: "/n", dir: "/h") else {
            Issue.record("expected a write"); return
        }
        #expect(HookInstaller.codexHooksPlan(config: once, node: "/n", dir: "/h") == .unchanged)
    }

    /// A node that moved rewrites the block where it stands, rather than appending a
    /// second one — the same repair the notify line gets, for the same reason.
    @Test func codexHooksBlockIsReplacedInPlaceNotAppended() {
        guard case .write(let old, _) = HookInstaller.codexHooksPlan(
            config: "model = \"o3\"\n", node: "/old/node", dir: "/h") else {
            Issue.record("expected a write"); return
        }
        let trailing = old + "\n[profiles.mine]\nmodel = \"o4\"\n"
        guard case .write(let next, let replaced) = HookInstaller.codexHooksPlan(
            config: trailing, node: "/new/node", dir: "/h") else {
            Issue.record("expected a rewrite"); return
        }
        #expect(replaced)
        #expect(!next.contains("/old/node"))
        #expect(next.components(separatedBy: HookInstaller.codexBegin).count - 1 == 1)
        // Everything the user put after our block is still there, untouched.
        #expect(next.hasSuffix("[profiles.mine]\nmodel = \"o4\"\n"))
        #expect(next.hasPrefix("model = \"o3\"\n"))
    }

    /// The trap this release had to fix first: the marker check used to match the path
    /// anywhere in the file, so once the hooks block existed — which carries the same
    /// path — a config with no `notify` key was read as "already wired" and notify was
    /// never installed at all.
    @Test func theHooksBlockDoesNotHideAMissingNotify() {
        guard case .write(let withHooks, _) = HookInstaller.codexHooksPlan(
            config: "model = \"o3\"\n", node: "/n", dir: "/h") else {
            Issue.record("expected a write"); return
        }
        #expect(withHooks.contains("/.agentbar/hooks/codex/") == false)   // dir is /h here
        let real = withHooks.replacingOccurrences(of: "/h/codex/", with: "/u/.agentbar/hooks/codex/")
        let plan = HookInstaller.codexPlan(config: real, node: "/n",
                                           script: "/u/.agentbar/hooks/codex/notify.js",
                                           isExecutable: { _ in true })
        guard case .write(let next, let repaired) = plan else {
            Issue.record("notify must still be installed beside the hooks block, got \(plan)")
            return
        }
        #expect(!repaired)
        #expect(next.contains("notify = [\"/n\", \"/u/.agentbar/hooks/codex/notify.js\"]"))
    }

    @Test func codexRepairsAnInterpreterThatHasMoved() {
        let stale = "model = \"o3\"\nnotify = [\"/Users/x/.nvm/versions/node/v20.11.0/bin/node\", \"\(Self.script)\"]\n"
        let plan = HookInstaller.codexPlan(config: stale, node: "/opt/homebrew/bin/node",
                                           script: Self.script, isExecutable: { _ in false })
        guard case .write(let next, let repaired) = plan else {
            Issue.record("a dead interpreter must produce a write, got \(plan)"); return
        }
        #expect(repaired)
        #expect(next.contains("notify = [\"/opt/homebrew/bin/node\""))
        #expect(!next.contains("v20.11.0"))
        // Codex accepts exactly one notify key, and the rest of the file is the
        // user's — repairing must not append or disturb anything.
        #expect(next.components(separatedBy: "notify = [").count - 1 == 1)
        #expect(next.hasPrefix("model = \"o3\"\n"))
    }

    /// The other half: a working interpreter must not be rewritten on every launch,
    /// or `install-hooks` stops being idempotent and churns the user's config.
    @Test func codexLeavesAWorkingInterpreterAlone() {
        let fine = "notify = [\"/opt/homebrew/bin/node\", \"\(Self.script)\"]\n"
        #expect(HookInstaller.codexPlan(config: fine, node: "/usr/local/bin/node",
                                        script: Self.script, isExecutable: { _ in true }) == .unchanged)
    }

    @Test func codexAppendsToAConfigThatHasNoNotifyYet() {
        let plan = HookInstaller.codexPlan(config: "model = \"o3\"", node: "/opt/homebrew/bin/node",
                                           script: Self.script, isExecutable: { _ in true })
        guard case .write(let next, let repaired) = plan else {
            Issue.record("a fresh config must be written, got \(plan)"); return
        }
        #expect(!repaired)
        // The file had no trailing newline; appending to it must not join two keys.
        #expect(next == "model = \"o3\"\nnotify = [\"/opt/homebrew/bin/node\", \"\(Self.script)\"]\n")
    }

    /// Someone else's notify hook stays theirs even when ours is dead — a status
    /// bridge must never take a key the user pointed somewhere on purpose.
    @Test func codexRefusesToTakeOverAForeignNotify() {
        #expect(HookInstaller.codexPlan(config: "notify = [\"/usr/bin/say\", \"done\"]\n",
                                        node: "/opt/homebrew/bin/node", script: Self.script,
                                        isExecutable: { _ in false }) == .foreignNotify)
    }

    /// …on any line, not only the first. Without `(?m)` the pattern saw a notify only
    /// at the very start of the file, and a second key appended below the user's made
    /// a config.toml that TOML, and so Codex, refuses to load.
    @Test func aForeignNotifyOnALaterLineIsStillForeign() {
        #expect(HookInstaller.codexPlan(config: "model = \"o3\"\nnotify = [\"/usr/bin/say\", \"done\"]\n",
                                        node: "/opt/homebrew/bin/node", script: Self.script,
                                        isExecutable: { _ in true }) == .foreignNotify)
    }

    /// A bare key written after a `[table]` header belongs to that table, so notify
    /// appended to a file with an MCP server in it was that server's notify.
    @Test func notifyGoesAboveTheFirstTable() {
        let config = "model = \"o3\"\n\n[mcp_servers.github]\ncommand = \"gh\"\n"
        guard case .write(let next, _) = HookInstaller.codexPlan(
            config: config, node: "/n", script: Self.script, isExecutable: { _ in true }) else {
            Issue.record("expected a write"); return
        }
        let notify = next.range(of: "notify = [")!.lowerBound
        #expect(notify < next.range(of: "[mcp_servers.github]")!.lowerBound)
        #expect(next.hasSuffix("[mcp_servers.github]\ncommand = \"gh\"\n"))
    }

    /// …and one an older release already put below a table is moved up, once.
    @Test func aNotifyStrandedInATableIsMovedToTheTop() {
        let ours = "notify = [\"/n\", \"\(Self.script)\"]"
        let stranded = "model = \"o3\"\n[mcp_servers.github]\ncommand = \"gh\"\n\(ours)\n"
        guard case .write(let next, let repaired) = HookInstaller.codexPlan(
            config: stranded, node: "/n", script: Self.script, isExecutable: { _ in true }) else {
            Issue.record("expected a move"); return
        }
        #expect(repaired)
        #expect(next == "model = \"o3\"\n\(ours)\n[mcp_servers.github]\ncommand = \"gh\"\n")
        #expect(HookInstaller.codexPlan(config: next, node: "/n", script: Self.script,
                                        isExecutable: { _ in true }) == .unchanged)
    }

    /// Our marker in a shape the line pattern can't read (a comment, hand-edited
    /// formatting) must fall through to "leave it", never to "append a second key".
    @Test func codexDoesNotAppendWhenTheMarkerIsThereInAnUnreadableShape() {
        let odd = "# wired by agentbar: /Users/x/.agentbar/hooks/codex/notify.js\n"
        #expect(HookInstaller.codexPlan(config: odd, node: "/opt/homebrew/bin/node",
                                        script: Self.script, isExecutable: { _ in false }) == .unchanged)
    }

    // MARK: - firstQuoted

    @Test(arguments: [
        ("notify = [\"/usr/bin/node\", \"/x/notify.js\"]", "/usr/bin/node"),
        ("notify = [\"\", \"/x\"]", ""),
    ])
    func firstQuotedReadsTheInterpreter(_ line: String, _ want: String) {
        #expect(HookInstaller.firstQuoted(line) == want)
    }

    @Test(arguments: ["notify = []", "", "no quotes here", "\"unterminated"])
    func firstQuotedIsNilWithoutAClosedPair(_ line: String) {
        #expect(HookInstaller.firstQuoted(line) == nil)
    }

    // MARK: - Node paths

    /// A path that does not resolve comes back untouched. An nvm-only machine has no
    /// stable alias at all, and inventing one would write a path that isn't there —
    /// `agentbar doctor` reports the situation instead.
    @Test func anUnresolvablePathIsReturnedUnchanged() {
        #expect(HookInstaller.stableNodeAlias(for: "/nope/not/a/node") == "/nope/not/a/node")
    }

    /// The actual fix: a version-pinned path that names the same binary as a stable
    /// alias must come back as the alias. Built from whatever node this machine has.
    @Test func aVersionPinnedPathIsSwappedForItsStableAlias() throws {
        let fm = FileManager.default
        guard let stable = HookInstaller.stableNodePaths.first(where: { fm.isExecutableFile(atPath: $0) }),
              let real = HookInstaller.realPath(stable)
        else { return }   // no node on this machine: nothing to assert against

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-node-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Stand in for ~/.nvm/versions/node/v20.11.0/bin/node: a different path that
        // resolves to the very same interpreter.
        let pinned = dir.appendingPathComponent("node")
        try fm.createSymbolicLink(at: pinned, withDestinationURL: URL(fileURLWithPath: real))

        let resolved = HookInstaller.stableNodeAlias(for: pinned.path)
        #expect(resolved != pinned.path, "a pinned path with a stable alias must not survive")
        #expect(HookInstaller.realPath(resolved) == real)
        #expect(HookInstaller.stableNodePaths.contains(resolved))
    }

    // MARK: - Wiring and unwiring a whole agent, in a home of our own

    /// Every pass here runs against a temporary home with an empty environment — the
    /// shell running the tests may carry a real `CLAUDE_CONFIG_DIR` or `COPILOT_HOME`,
    /// and a pass that read either would write into the person's own settings.
    private struct Home {
        let url: URL
        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("agentbar-wire-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var log: URL { url.appendingPathComponent(".agentbar/config-changes.json") }
        func ctx(off: Set<String> = []) -> HookInstaller.Context {
            HookInstaller.Context(home: url, environment: [:], node: "/opt/homebrew/bin/node",
                                  log: log, disabled: off)
        }
        func path(_ rel: String) -> URL { url.appendingPathComponent(rel) }
        func dir(_ rel: String) throws {
            try FileManager.default.createDirectory(at: path(rel), withIntermediateDirectories: true)
        }
        func put(_ rel: String, _ text: String) throws {
            try FileManager.default.createDirectory(at: path(rel).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: path(rel), atomically: true, encoding: .utf8)
        }
        func read(_ rel: String) -> String? { try? String(contentsOf: path(rel), encoding: .utf8) }
        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path(rel).path) }
        func records() -> [ConfigBackup.Record] { ConfigBackup.recent(log: log) }
        /// The installer's own serializer, so "the file as it was" means the same bytes.
        static func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                   as: UTF8.self)
        }
        func cleanUp() { try? FileManager.default.removeItem(at: url) }
    }

    /// Wire one agent, then switch it off: the file must come back to exactly what it
    /// was, the user's own entries included, and every record must name the agent.
    private func roundTrip(_ agent: String, file: String, before: String,
                           marker: String, setUp: (Home) throws -> Void = { _ in }) throws {
        let home = try Home()
        defer { home.cleanUp() }
        try setUp(home)
        try home.put(file, before)

        let wired = HookInstaller.runPass(home.ctx(), preview: false, only: agent)
        #expect(wired.wired == [agent])
        let during = try #require(home.read(file))
        #expect(Diagnostics.unescapingSlashes(during).contains(marker), "\(agent) was not wired")

        // The preview of switching it off is the diff the sheet shows, tagged.
        let planned = HookInstaller.runPass(home.ctx(off: [agent]), preview: true, only: agent).planned
        #expect(planned.count == 1)
        #expect(planned.first?.agent == agent)
        #expect(home.read(file) == during, "a preview wrote")

        let unwired = HookInstaller.runPass(home.ctx(off: [agent]), preview: false, only: agent)
        #expect(unwired.wired.isEmpty)
        #expect(home.read(file) == before, "\(agent): unwiring did not give the file back")
        #expect(home.records().allSatisfy { $0.agent == agent })
        #expect(home.records().count == 2)

        // And again: nothing of ours left means nothing is written.
        _ = HookInstaller.runPass(home.ctx(off: [agent]), preview: false, only: agent)
        #expect(home.records().count == 2)
    }

    /// A config the installer will not rewrite is a problem the pass reports, not
    /// a success: the Agents switch and Diagnostics' repair both used to say done.
    @Test func aConfigLeftUntouchedIsReportedAsAProblem() throws {
        let home = try Home()
        defer { home.cleanUp() }
        let broken = #"{"model": "x",}"#
        try home.put(".gemini/settings.json", broken)
        let pass = HookInstaller.runPass(home.ctx(), preview: false, only: "gemini")
        #expect(pass.wired.isEmpty)
        #expect(pass.problems.count == 1)
        #expect(pass.problems.first?.contains("not valid JSON") == true)
        #expect(home.read(".gemini/settings.json") == broken)
    }

    @Test func noNodeIsReportedAsAProblem() throws {
        let home = try Home()
        defer { home.cleanUp() }
        try home.dir(".gemini")
        let ctx = HookInstaller.Context(home: home.url, environment: [:], node: nil,
                                        log: home.log, disabled: [])
        let pass = HookInstaller.runPass(ctx, preview: false, only: "gemini")
        #expect(pass.wired.isEmpty)
        #expect(pass.problems.first?.contains("node was not found") == true)
    }

    @Test func claudeUnwiresBackToTheUsersOwnSettings() throws {
        let before = try Home.json([
            "env": ["FOO": "1"],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
            "model": "opus",
        ])
        try roundTrip("claude", file: ".claude/settings.json", before: before,
                      marker: HookInstaller.claudeMarker)
    }

    @Test func claudeWithNoHooksOfItsOwnLosesTheEmptyHooksKey() throws {
        try roundTrip("claude", file: ".claude/settings.json",
                      before: try Home.json(["model": "opus"]), marker: HookInstaller.claudeMarker)
    }

    @Test func qwenUnwires() throws {
        let before = try Home.json([
            "hooks": ["SessionStart": [["hooks": [["type": "command", "command": "echo hi"]]]]],
        ])
        try roundTrip("qwen", file: ".qwen/settings.json", before: before,
                      marker: HookInstaller.claudeMarker)
    }

    @Test func geminiUnwires() throws {
        let before = try Home.json([
            "hooks": ["AfterTool": [["hooks": [["type": "command", "command": "lint"]]]]],
            "theme": "dark",
        ])
        try roundTrip("gemini", file: ".gemini/settings.json", before: before,
                      marker: HookInstaller.geminiMarker)
    }

    @Test func cursorUnwiresAndKeepsTheUsersFlatRules() throws {
        let before = try Home.json([
            "version": 1,
            "hooks": ["stop": [["command": "/usr/local/bin/notify-me"]]],
        ])
        try roundTrip("cursor", file: ".cursor/hooks.json", before: before,
                      marker: HookInstaller.cursorMarker)
    }

    @Test func antigravityLosesOnlyItsOwnGroup() throws {
        let before = try Home.json([
            "mine": ["Stop": [["hooks": [["type": "command", "command": "beep"]]]]],
        ])
        try roundTrip("antigravity", file: ".gemini/antigravity/hooks.json", before: before,
                      marker: "\"agentbar\"")
    }

    @Test func codexUnwiresTheBlockAndItsOwnNotify() throws {
        let before = "model = \"o3\"\n\n[mcp_servers.github]\ncommand = \"gh\"\n"
        try roundTrip("codex", file: ".codex/config.toml", before: before,
                      marker: "/.agentbar/hooks/codex/")
    }

    /// Somebody else's notify was never ours to take, so it is not ours to remove.
    @Test func codexUnwiringLeavesAForeignNotifyAlone() throws {
        let before = "notify = [\"/usr/bin/say\", \"done\"]\nmodel = \"o3\"\n"
        try roundTrip("codex", file: ".codex/config.toml", before: before,
                      marker: HookInstaller.codexBegin)
    }

    @Test func codexUnwiredIsTheInverseOfBothPlans() {
        for original in ["", "model = \"o3\"\n", "model = \"o3\"\n\n", "a = 1\n[t]\nb = 2\n"] {
            var text = original
            if case .write(let next, _) = HookInstaller.codexPlan(
                config: text, node: "/n", script: "/u/.agentbar/hooks/codex/notify.js",
                isExecutable: { _ in true }) { text = next }
            if case .write(let next, _) = HookInstaller.codexHooksPlan(
                config: text, node: "/n", dir: "/u/.agentbar/hooks") { text = next }
            #expect(text != original)
            #expect(HookInstaller.codexUnwired(config: text) == original, "\(original.debugDescription)")
        }
        // Our marker in a shape the notify pattern cannot read stays, as codexPlan leaves it.
        let odd = "# wired by agentbar: /u/.agentbar/hooks/codex/notify.js\n"
        #expect(HookInstaller.codexUnwired(config: odd) == odd)
    }

    /// Copilot loads every *.json in its hooks dir; ours is a file of its own, so
    /// switching it off deletes that file — kept beside itself first — and nothing else.
    @Test func copilotUnwiresByRemovingItsOwnFile() throws {
        let home = try Home()
        defer { home.cleanUp() }
        try home.put(".copilot/hooks/mine.json", "{\"version\":1}")
        _ = HookInstaller.runPass(home.ctx(), preview: false, only: "copilot")
        #expect(home.exists(".copilot/hooks/agentbar.json"))

        let planned = HookInstaller.runPass(home.ctx(off: ["copilot"]), preview: true, only: "copilot").planned
        #expect(planned.count == 1)
        #expect(ConfigChangesSheet.isRemoval(try #require(planned.first)))
        #expect(home.exists(".copilot/hooks/agentbar.json"), "a preview removed")

        _ = HookInstaller.runPass(home.ctx(off: ["copilot"]), preview: false, only: "copilot")
        #expect(!home.exists(".copilot/hooks/agentbar.json"))
        #expect(home.read(".copilot/hooks/mine.json") == "{\"version\":1}")
        let removal = try #require(home.records().first)
        #expect(removal.agent == "copilot")
        #expect(ConfigChangesSheet.isRemoval(removal))
        let kept = try #require(removal.backup)
        #expect(FileManager.default.fileExists(atPath: kept))
        // The copy is not a *.json, or Copilot would load our hooks from it.
        #expect(!kept.hasSuffix(".json"))
    }

    @Test func openCodeIsPreviewedForItsOwnSwitchAndRemovedWhenOff() throws {
        let home = try Home()
        defer { home.cleanUp() }
        try home.dir(".config/opencode")
        try home.put(".agentbar/hooks/opencode/agentbar.js", "export default {}\n")

        // A whole-pass preview still leaves the plugin out (it is our release, not
        // the user's settings); the one-agent preview behind the switch shows it.
        #expect(HookInstaller.runPass(home.ctx(), preview: true).planned.allSatisfy { $0.agent != "opencode" })
        let shown = HookInstaller.runPass(home.ctx(), preview: true, only: "opencode").planned
        #expect(shown.map(\.agent) == ["opencode"])

        _ = HookInstaller.runPass(home.ctx(), preview: false, only: "opencode")
        #expect(home.read(".config/opencode/plugins/agentbar.js") == "export default {}\n")
        _ = HookInstaller.runPass(home.ctx(off: ["opencode"]), preview: false, only: "opencode")
        #expect(!home.exists(".config/opencode/plugins/agentbar.js"))
        #expect(home.records().first?.agent == "opencode")
    }

    /// The whole launch pass, with one agent switched off: that one is not wired —
    /// its file stays byte for byte, hand formatting and all — and the rest are.
    @Test func aDisabledAgentIsNotRewiredByTheLaunchPass() throws {
        let home = try Home()
        defer { home.cleanUp() }
        let handWritten = "{ \"version\": 1,\n  \"hooks\": {} }\n"
        try home.put(".cursor/hooks.json", handWritten)
        try home.dir(".codex")

        let pass = HookInstaller.runPass(home.ctx(off: ["cursor"]), preview: false)
        #expect(home.read(".cursor/hooks.json") == handWritten)
        #expect(!pass.wired.contains("cursor"))
        #expect(pass.wired.contains("claude"))
        #expect(pass.wired.contains("codex"))
        #expect(!home.records().contains { $0.agent == "cursor" })
        // Every record the pass left says whose file it was.
        #expect(!home.records().isEmpty)
        #expect(home.records().allSatisfy { $0.agent != nil })
    }

    /// Only Claude's config dir in the temporary home is touched — the environment
    /// is the context's, so a `CLAUDE_CONFIG_DIR` in the shell running this is not.
    @Test func claudeIsUnwiredInEveryConfigDirItWasWiredInto() throws {
        let home = try Home()
        defer { home.cleanUp() }
        let other = home.path("elsewhere/claude")
        var ctx = home.ctx()
        ctx.environment = ["CLAUDE_CONFIG_DIR": other.path]
        try home.put(".claude/settings.json", "{}")
        _ = HookInstaller.runPass(ctx, preview: false, only: "claude")
        #expect(home.read("elsewhere/claude/settings.json")?.contains("lifecycle.js") == true)
        ctx.disabled = ["claude"]
        _ = HookInstaller.runPass(ctx, preview: false, only: "claude")
        #expect(home.read("elsewhere/claude/settings.json") == "{\n\n}")
        #expect(home.read(".claude/settings.json") == "{\n\n}")
    }

    /// One alias per account: `~/.claude-work` was wired from a shell that had
    /// CLAUDE_CONFIG_DIR, and the app — launched by `open` — has none. It must still
    /// find that directory (switching the mod on once wrote only `~/.claude`), and
    /// still leave alone a `~/.claude-*` nobody wired.
    @Test func aConfigDirWiredFromAShellIsKeptWithoutTheVariable() throws {
        let home = try Home()
        defer { home.cleanUp() }
        try home.put(".claude/settings.json", "{}")
        try home.put(".claude-work/settings.json",
                     #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"node /h/.agentbar/hooks/claude/update.js done"}]}]}}"#)
        try home.put(".claude-mine/settings.json", "{}")
        let ctx = home.ctx()
        let dirs = HookInstaller.claudeConfigDirs(ctx).map(\.lastPathComponent)
        #expect(dirs == [".claude", ".claude-work"])
        _ = HookInstaller.runPass(ctx, preview: false, only: "claude")
        #expect(home.read(".claude-work/settings.json")?.contains("lifecycle.js") == true)
        #expect(home.read(".claude-mine/settings.json") == "{}")
    }
}
