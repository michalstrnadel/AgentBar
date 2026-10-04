import Foundation
import Testing
@testable import AgentBar

/// The Claude Code mod is loaded through one entry in
/// `env.CLAUDE_CODE_PLUGIN_DIRS`, in a settings file that belongs to the person and
/// may already list plugin directories of their own. These pin the promises: theirs
/// survive in order, a second wiring is nothing, wiring then unwiring gives back the
/// bytes, a value of the wrong type is refused rather than repaired — and none of it
/// happens until somebody switches it on.
@Suite struct ClaudeModWiringTests {
    private static let ours = "/Users/x/.agentbar/mods/claude"

    private func env(_ root: [String: Any]) -> [String: Any]? { root["env"] as? [String: Any] }

    // MARK: - The transform

    @Test func aFreshSettingsFileGainsOnlyOurEntry() {
        let (plan, out) = ClaudeModWiring.wired(["theme": "dark"], modDir: Self.ours)
        #expect(plan == .write)
        #expect(env(out)?[ClaudeModWiring.envKey] as? String == Self.ours)
        #expect(out["theme"] as? String == "dark")
    }

    @Test func thePersonsOwnDirectoriesStayFirstAndInOrder() {
        let root: [String: Any] = ["env": ["CLAUDE_CODE_PLUGIN_DIRS": "/opt/b:/opt/a", "FOO": "1"]]
        let (_, out) = ClaudeModWiring.wired(root, modDir: Self.ours)
        #expect(env(out)?[ClaudeModWiring.envKey] as? String == "/opt/b:/opt/a:" + Self.ours)
        #expect(env(out)?["FOO"] as? String == "1")
    }

    /// An entry left by another AgentBar home, or an older layout, is replaced —
    /// never a second copy of the mod loaded beside the first.
    @Test func anOlderAgentBarEntryIsReplacedNotDoubled() {
        let root: [String: Any] = ["env": ["CLAUDE_CODE_PLUGIN_DIRS": "/old/.agentbar/mods/claude:/opt/a"]]
        let (_, out) = ClaudeModWiring.wired(root, modDir: Self.ours)
        #expect(env(out)?[ClaudeModWiring.envKey] as? String == "/opt/a:" + Self.ours)
    }

    @Test func wiringTwiceIsNothing() {
        let (_, once) = ClaudeModWiring.wired(["env": ["CLAUDE_CODE_PLUGIN_DIRS": "/opt/a"]], modDir: Self.ours)
        let (plan, _) = ClaudeModWiring.wired(once, modDir: Self.ours)
        #expect(plan == .unchanged)
        #expect(ClaudeModWiring.isWired(once))
    }

    @Test func blanksInTheListAreNotDirectories() {
        #expect(ClaudeModWiring.entries("a::b: ") == ["a", "b"])
        #expect(ClaudeModWiring.entries(nil) == [])
    }

    /// Claude Code reads a string there. Anything else is the person's to fix, and
    /// "fixing" it would throw their value away.
    @Test func aValueOfTheWrongTypeIsRefusedAndLeftAlone() {
        if case .refused = ClaudeModWiring.wired(["env": "FOO=1"], modDir: Self.ours).plan {} else {
            Issue.record("a non-object env must be refused")
        }
        if case .refused = ClaudeModWiring.wired(["env": ["CLAUDE_CODE_PLUGIN_DIRS": ["/opt/a"]]],
                                                 modDir: Self.ours).plan {} else {
            Issue.record("a list where a string belongs must be refused")
        }
        if case .refused = ClaudeModWiring.wired(["env": ["CLAUDE_CODE_PLUGIN_DIRS": 5]],
                                                 modDir: Self.ours).plan {} else {
            Issue.record("a number where a string belongs must be refused")
        }
        // Unwiring something it cannot read is not a write either.
        #expect(ClaudeModWiring.unwired(["env": ["CLAUDE_CODE_PLUGIN_DIRS": ["/x/.agentbar/mods/claude"]]]).plan == .unchanged)
        #expect(ClaudeModWiring.unwired(["env": "x"]).plan == .unchanged)
    }

    @Test func unwiringLeavesTheirsAndDropsWhatEmptied() {
        let theirs: [String: Any] = ["env": ["CLAUDE_CODE_PLUGIN_DIRS": "/opt/a:" + Self.ours]]
        #expect(env(ClaudeModWiring.unwired(theirs).root)?[ClaudeModWiring.envKey] as? String == "/opt/a")

        let onlyOurs: [String: Any] = ["env": ["CLAUDE_CODE_PLUGIN_DIRS": Self.ours, "FOO": "1"]]
        let keepsEnv = ClaudeModWiring.unwired(onlyOurs).root
        #expect(env(keepsEnv)?[ClaudeModWiring.envKey] == nil)
        #expect(env(keepsEnv)?["FOO"] as? String == "1")

        let emptied = ClaudeModWiring.unwired(["theme": "dark", "env": ["CLAUDE_CODE_PLUGIN_DIRS": Self.ours]]).root
        #expect(emptied["env"] == nil)
        #expect(emptied["theme"] as? String == "dark")

        #expect(ClaudeModWiring.unwired(["env": ["CLAUDE_CODE_PLUGIN_DIRS": "/opt/a"]]).plan == .unchanged)
        #expect(ClaudeModWiring.unwired(["theme": "dark"]).plan == .unchanged)
    }

    // MARK: - The version gate

    @Test func theGateOpensAt2_1_287() {
        #expect(ClaudeModWiring.supports("2.1.287"))
        #expect(ClaudeModWiring.supports("2.1.289"))
        #expect(ClaudeModWiring.supports("2.2.0"))
        #expect(ClaudeModWiring.supports("3"))
        #expect(!ClaudeModWiring.supports("2.1.286"))
        #expect(!ClaudeModWiring.supports("2.1.99"))
        #expect(!ClaudeModWiring.supports("1.9.999"))
        // Unknown is not a refusal: an older Claude Code ignores the setting.
        #expect(ClaudeModWiring.supports(nil))
        #expect(ClaudeModWiring.parseVersion("2.1.289 (Claude Code)\n") == "2.1.289")
        #expect(ClaudeModWiring.parseVersion("Claude Code\n") == nil)
    }

    // MARK: - Through a real pass, in a borrowed home

    private func home() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-mod-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".agentbar/mods/claude"),
                                                withIntermediateDirectories: true)
        return url
    }

    /// Exactly the way the installer serializes, so a file it once wrote compares
    /// byte for byte.
    private func installerBytes(_ o: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// An empty environment, always: the runner's CLAUDE_CONFIG_DIR must never reach
    /// a pass (it once rewrote a real Claude config from a test).
    private func ctx(_ home: URL, enabled: Set<String> = [], disabled: Set<String> = [],
                     version: String? = "2.1.289") -> HookInstaller.Context {
        HookInstaller.Context(home: home, environment: [:], node: "/opt/homebrew/bin/node",
                              log: home.appendingPathComponent(".agentbar/config-changes.json"),
                              disabled: disabled, enabled: enabled, claudeVersion: version)
    }

    private func settings(_ home: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The point of `WiringPrefs.defaultOff`: a pass nobody asked for writes nothing.
    @Test func aPassWithoutTheSwitchNeverWiresTheMod() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let original = try installerBytes(["theme": "dark", "env": ["FOO": "1"]])
        try original.write(to: home.appendingPathComponent(".claude/settings.json"))
        _ = HookInstaller.runPass(ctx(home), preview: false, only: ClaudeModWiring.id)
        #expect(try Data(contentsOf: home.appendingPathComponent(".claude/settings.json")) == original)
    }

    @Test func switchedOnItIsWiredAndOffItGivesBackTheBytes() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent(".claude/settings.json")
        let original = try installerBytes(["theme": "dark",
                                           "env": ["CLAUDE_CODE_PLUGIN_DIRS": "/opt/mine", "FOO": "1"]])
        try original.write(to: url)

        _ = HookInstaller.runPass(ctx(home, enabled: [ClaudeModWiring.id]), preview: false, only: ClaudeModWiring.id)
        let wired = try settings(home)
        let modDir = home.appendingPathComponent(".agentbar/mods/claude", isDirectory: true).path
        #expect((wired["env"] as? [String: Any])?[ClaudeModWiring.envKey] as? String == "/opt/mine:" + modDir)

        // Idempotent through the pass as well: no second backup.
        let before = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted()
        _ = HookInstaller.runPass(ctx(home, enabled: [ClaudeModWiring.id]), preview: false, only: ClaudeModWiring.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted() == before)

        _ = HookInstaller.runPass(ctx(home), preview: false, only: ClaudeModWiring.id)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func aPreviewShowsTheChangeAndWritesNothing() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent(".claude/settings.json")
        let original = try installerBytes(["theme": "dark"])
        try original.write(to: url)
        let planned = HookInstaller.runPass(ctx(home, enabled: [ClaudeModWiring.id]),
                                            preview: true, only: ClaudeModWiring.id).planned
        #expect(planned.count == 1)
        #expect(planned.first?.agent == ClaudeModWiring.id)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func aClaudeCodeTooOldIsNotWired() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let original = try installerBytes(["theme": "dark"])
        try original.write(to: home.appendingPathComponent(".claude/settings.json"))
        _ = HookInstaller.runPass(ctx(home, enabled: [ClaudeModWiring.id], version: "2.1.200"),
                                  preview: false, only: ClaudeModWiring.id)
        #expect(try Data(contentsOf: home.appendingPathComponent(".claude/settings.json")) == original)
    }

    /// Pointing Claude Code at a directory that is not there would load nothing and
    /// say nothing; better not to write it at all.
    @Test func aModThatWasNeverCopiedIsNotWired() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.removeItem(at: home.appendingPathComponent(".agentbar/mods/claude"))
        let original = try installerBytes(["theme": "dark"])
        try original.write(to: home.appendingPathComponent(".claude/settings.json"))
        _ = HookInstaller.runPass(ctx(home, enabled: [ClaudeModWiring.id]), preview: false, only: ClaudeModWiring.id)
        #expect(try Data(contentsOf: home.appendingPathComponent(".claude/settings.json")) == original)
    }

    /// `wire-disabled` wins: a line written there by hand turns the mod off even
    /// when `wire-enabled` still lists it.
    @Test func wireDisabledWinsOverWireEnabled() {
        #expect(WiringPrefs.effectiveDisabled(disabled: [], enabled: []).contains(ClaudeModWiring.id))
        #expect(!WiringPrefs.effectiveDisabled(disabled: [], enabled: [ClaudeModWiring.id]).contains(ClaudeModWiring.id))
        #expect(WiringPrefs.effectiveDisabled(disabled: [ClaudeModWiring.id], enabled: [ClaudeModWiring.id])
                    .contains(ClaudeModWiring.id))
        // Every agent stays on by default — only the default-off list starts off.
        #expect(WiringPrefs.effectiveDisabled(disabled: [], enabled: []) == WiringPrefs.defaultOff)
    }

    // MARK: - The copy

    @Test func theCopyReplacesTheModAndKeepsTheConfig() throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundle/mods", isDirectory: true)
        let dest = root.appendingPathComponent("installed/mods", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled.appendingPathComponent("claude/hooks"),
                                                withIntermediateDirectories: true)
        try Data("v2".utf8).write(to: bundled.appendingPathComponent("claude/hooks/mod.mjs"))
        try FileManager.default.createDirectory(at: dest.appendingPathComponent("claude"),
                                                withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: dest.appendingPathComponent("claude/old.mjs"))
        try Data("{\"band\":true}".utf8).write(to: dest.appendingPathComponent("config.json"))

        try HookInstaller.copyMods(from: bundled, to: dest)
        #expect(try String(contentsOf: dest.appendingPathComponent("claude/hooks/mod.mjs"), encoding: .utf8) == "v2")
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("claude/old.mjs").path))
        #expect(try String(contentsOf: dest.appendingPathComponent("config.json"), encoding: .utf8) == "{\"band\":true}")
        #expect(HookInstaller.sameTree(bundled.appendingPathComponent("claude"), dest.appendingPathComponent("claude")))

        // An identical copy is left alone — Claude Code reloads a mod whose files change.
        let stamp = try FileManager.default.attributesOfItem(
            atPath: dest.appendingPathComponent("claude/hooks/mod.mjs").path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 1.1)
        try HookInstaller.copyMods(from: bundled, to: dest)
        let again = try FileManager.default.attributesOfItem(
            atPath: dest.appendingPathComponent("claude/hooks/mod.mjs").path)[.modificationDate] as? Date
        #expect(stamp == again)
    }

    // MARK: - WiringPrefs, the switch

    @Test func theSwitchWritesWireEnabledAndLiftsADisabledLine() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try "cursor\nclaude-mod\n".write(to: WiringPrefs.url(home: home), atomically: true, encoding: .utf8)

        try WiringPrefs.set(ClaudeModWiring.id, disabled: false, home: home)
        #expect(WiringPrefs.loadEnabled(home: home) == [ClaudeModWiring.id])
        #expect(WiringPrefs.load(home: home) == ["cursor"])
        #expect(!WiringPrefs.effectiveDisabled(home: home).contains(ClaudeModWiring.id))
        let text = try String(contentsOf: WiringPrefs.enabledURL(home: home), encoding: .utf8)
        #expect(text.hasPrefix("# Integrations AgentBar wires only because you asked"))

        try WiringPrefs.set(ClaudeModWiring.id, disabled: true, home: home)
        #expect(!FileManager.default.fileExists(atPath: WiringPrefs.enabledURL(home: home).path))
        #expect(WiringPrefs.load(home: home) == ["cursor"])   // off is not a line in wire-disabled
        #expect(WiringPrefs.effectiveDisabled(home: home).contains(ClaudeModWiring.id))
    }
}
