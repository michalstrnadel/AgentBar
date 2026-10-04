import Foundation
import Testing
@testable import AgentBar

/// What Settings ▸ Agents says about the plugins that could answer a prompt before
/// AgentBar sees one. The fixtures under `Tests/Fixtures/plugin-inventory/` are
/// copies of three real mods (blast-radius, token-weather, replay-theater: their
/// `hooks.json`, their manifest, the `on(…)` lines of their source) and of a classic
/// plugin's `hooks.json` (Warp's), plus what `claude plugin validate --json` printed
/// for each mod, paths replaced by `/fixture/…`.
@Suite struct PluginInventoryTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/plugin-inventory")

    private static func validateOutput(_ name: String) throws -> Data {
        try Data(contentsOf: fixtures.appendingPathComponent("validate/\(name).json"))
    }

    // MARK: - Parsing `claude plugin validate --json`

    @Test func validateNotesBecomeEventsWithTheirFilters() throws {
        let events = try #require(PluginInventory.parseValidate(try Self.validateOutput("blast-radius")))
        #expect(events == [.init(name: "tool.call", filter: ["tool": "Bash"]),
                           .init(name: "ui.render", filter: ["component": "Pane"]),
                           .init(name: "ui.render", filter: ["component": "AbovePrompt"])])
        let replay = try #require(PluginInventory.parseValidate(try Self.validateOutput("replay-theater")))
        #expect(replay.contains(.init(name: "command.run", filter: ["command": "replay"])))
        #expect(replay.contains(.init(name: "tool.call")))
        #expect(replay.count == 8)
    }

    @Test func outputOfAnotherShapeIsNoAnswerRatherThanNoHooks() {
        #expect(PluginInventory.parseValidate(Data("not json".utf8)) == nil)
        #expect(PluginInventory.parseValidate(Data(#"{"contents":[]}"#.utf8)) == nil)
    }

    // MARK: - The fallback: the module source

    @Test func theSourceScanFindsTheSameHooksValidateDoes() throws {
        for name in ["blast-radius", "token-weather", "replay-theater"] {
            let text = try String(contentsOf: Self.fixtures.appendingPathComponent("plugins/\(name)/hooks/\(name).mjs"),
                                  encoding: .utf8)
            let scanned = Set(PluginInventory.scanSource(text))
            let validated = Set(try #require(PluginInventory.parseValidate(try Self.validateOutput(name))))
            #expect(scanned == validated, "\(name)")
        }
    }

    // MARK: - Classification

    @Test func onlyHooksThatRunBeforeAToolCanAnswer() {
        typealias E = PluginInventory.Event
        #expect(PluginInventory.canAnswer(kind: .mod, events: [E(name: "tool.call", filter: ["tool": "Bash"])]))
        #expect(PluginInventory.canAnswer(kind: .mod, events: [E(name: "tool.check")]))
        #expect(PluginInventory.canAnswer(kind: .mod, events: [E(name: "classic.PreToolUse")]))
        #expect(PluginInventory.canAnswer(kind: .mod, events: [E(name: "classic.PermissionRequest")]))
        #expect(!PluginInventory.canAnswer(kind: .mod, events: [E(name: "ui.render"), E(name: "turn.complete")]))
        #expect(PluginInventory.canAnswer(kind: .hooks, events: [E(name: "PermissionRequest")]))
        #expect(PluginInventory.canAnswer(kind: .hooks, events: [E(name: "PreToolUse", filter: ["matcher": "Bash"])]))
        #expect(!PluginInventory.canAnswer(kind: .hooks, events: [E(name: "PostToolUse"), E(name: "Stop")]))
        #expect(!PluginInventory.canAnswer(kind: .other, events: []))
    }

    @Test func theSentencesSayWhatItCanDoToYou() {
        typealias E = PluginInventory.Event
        #expect(PluginInventory.answeringPhrases(kind: .mod, events: [E(name: "tool.call", filter: ["tool": "Bash"])])
                == ["can hold or refuse Bash commands before they run"])
        #expect(PluginInventory.answeringPhrases(kind: .mod, events: [E(name: "tool.call")])
                == ["can hold or refuse any tool call before it runs"])
        #expect(PluginInventory.answeringPhrases(kind: .mod, events: [E(name: "tool.check")])
                == ["can approve or refuse any tool call without asking you"])
        #expect(PluginInventory.answeringPhrases(kind: .hooks, events: [E(name: "PermissionRequest")])
                == ["runs a hook on every permission prompt, and that hook can answer it"])
        #expect(PluginInventory.note(kind: .mod, events: [E(name: "ui.render", filter: ["component": "AbovePrompt"]),
                                                          E(name: "session.start")]) == "draws in the terminal")
        #expect(PluginInventory.note(kind: .mod, events: [E(name: "turn.complete")]) == "watches the session")
        #expect(PluginInventory.note(kind: .other, events: []) == nil)
    }

    // MARK: - A whole config dir, in a temporary home

    /// `~/.claude-x` with the fixture plugins installed and enabled the way Claude
    /// Code records them: `installed_plugins.json` (version 2) and `enabledPlugins`.
    private func configDir(enabled: [String: Bool], inline: [String] = []) throws -> (dir: URL, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-plugins-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent(".claude-x", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("plugins"), to: cache)
        var registry: [String: Any] = [:]
        for name in ["blast-radius", "token-weather", "replay-theater", "warp"] {
            let mkt = name == "warp" ? "claude-code-warp" : "claude-code-playground-mods"
            registry["\(name)@\(mkt)"] = [["scope": "project", "installPath": "/nowhere", "version": "0"],
                                         ["scope": "user", "installPath": cache.appendingPathComponent(name).path,
                                          "version": "0.1.0"]]
        }
        registry["skills-only@x"] = [["scope": "user", "installPath": root.appendingPathComponent("empty").path,
                                      "version": "1"]]
        try JSONSerialization.data(withJSONObject: ["version": 2, "plugins": registry])
            .write(to: dir.appendingPathComponent("plugins/installed_plugins.json"))
        var settings: [String: Any] = ["enabledPlugins": enabled]
        if !inline.isEmpty { settings["env"] = [ClaudeModWiring.envKey: inline.joined(separator: ":")] }
        try JSONSerialization.data(withJSONObject: settings).write(to: dir.appendingPathComponent("settings.json"))
        return (dir, root)
    }

    @Test func enabledPluginsAreSortedIntoTheOnesThatCanAnswer() throws {
        let (dir, root) = try configDir(enabled: [
            "blast-radius@claude-code-playground-mods": true,
            "token-weather@claude-code-playground-mods": true,
            "replay-theater@claude-code-playground-mods": false,      // installed, switched off
            "warp@claude-code-warp": true,
            "skills-only@x": true,
            "built-in@builtin": true,                                 // not in the registry
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let validator: PluginInventory.Validator = { path in
            try? Self.validateOutput(URL(fileURLWithPath: path).lastPathComponent)
        }
        let plugins = PluginInventory.inventory(configDirs: [dir], validate: validator)
        #expect(Set(plugins.map(\.name)) == ["blast-radius", "token-weather", "warp", "skills-only"])

        let blast = try #require(plugins.first { $0.name == "blast-radius" })
        #expect(blast.kind == .mod)
        #expect(!blast.estimated)
        #expect(blast.canAnswer)
        #expect(blast.sentence.hasPrefix("can hold or refuse Bash commands before they run"))

        let weather = try #require(plugins.first { $0.name == "token-weather" })
        #expect(!weather.canAnswer)

        // Warp's PermissionRequest hook only notifies, but a hook there *can* answer,
        // and the card says what can happen, not what this version happens to do.
        let warp = try #require(plugins.first { $0.name == "warp" })
        #expect(warp.kind == .hooks)
        #expect(warp.canAnswer)

        #expect(plugins.first { $0.name == "skills-only" }?.kind == .other)
    }

    /// Without `claude` (or with it timing out) the source scan stands in, marked.
    @Test func withoutValidateTheSourceIsReadAndSaysSo() throws {
        let (dir, root) = try configDir(enabled: ["blast-radius@claude-code-playground-mods": true])
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = PluginInventory.inventory(configDirs: [dir], validate: { _ in nil })
        let blast = try #require(plugins.first)
        #expect(blast.estimated)
        #expect(blast.canAnswer)
        #expect(AgentsPage.pluginBadge(blast) == "Mod · from source")
    }

    /// AgentBar's own mod, loaded inline: listed, and never counted as answering.
    @Test func ourOwnModObservesOnly() throws {
        let (dir, root) = try configDir(enabled: [:])
        defer { try? FileManager.default.removeItem(at: root) }
        let ours = root.appendingPathComponent("home/.agentbar/mods/claude", isDirectory: true)
        try FileManager.default.createDirectory(at: ours.appendingPathComponent("hooks"), withIntermediateDirectories: true)
        try Data(#"{"modules":["./agentbar.mjs"]}"#.utf8).write(to: ours.appendingPathComponent("hooks/hooks.json"))
        try Data(#"on("tool.call", async ($, e, next) => next())"#.utf8)
            .write(to: ours.appendingPathComponent("hooks/agentbar.mjs"))
        let (dir2, root2) = try configDir(enabled: [:], inline: ["/opt/elsewhere", ours.path])
        defer { try? FileManager.default.removeItem(at: root2) }
        _ = dir
        let plugins = PluginInventory.inventory(configDirs: [dir2], validate: nil)
        let mod = try #require(plugins.first { $0.installPath == ours.path })
        #expect(mod.ours)
        #expect(!mod.canAnswer)
        #expect(mod.sentence.hasPrefix("observes only"))
        #expect(AgentsPage.alsoLoaded(plugins)?.contains("claude (observes only)") == true)
    }

    /// Two config dirs enabling the same plugin are one row naming both.
    @Test func onePluginEnabledTwiceIsOneEntry() throws {
        let (a, rootA) = try configDir(enabled: ["blast-radius@claude-code-playground-mods": true])
        defer { try? FileManager.default.removeItem(at: rootA) }
        let b = rootA.appendingPathComponent(".claude-y", isDirectory: true)
        try FileManager.default.copyItem(at: a, to: b)
        let plugins = PluginInventory.inventory(configDirs: [a, b], validate: nil)
        #expect(plugins.count == 1)
        #expect(plugins.first?.configDirs.count == 2)
        #expect(AgentsPage.showsDirs(plugins))
    }
}
