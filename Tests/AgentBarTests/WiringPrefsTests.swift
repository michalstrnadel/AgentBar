import Foundation
import Testing
@testable import AgentBar

/// `~/.agentbar/wire-disabled` is shared with the Linux CLI, so its reading rules
/// are the contract: one id per line, `#` starts a comment, blanks and junk are
/// ignored, and an id this build does not know survives a save.
@Suite struct WiringPrefsTests {
    private let home: URL

    init() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    @Test func parsesIdsCommentsAndBlankLines() {
        let text = """
        # Agents AgentBar leaves unwired
        cursor

          Gemini   # trailing comment, any case
        \tqwen\r
        #codex
        not an id
        ../etc
        future-agent
        """
        #expect(WiringPrefs.parse(text) == ["cursor", "gemini", "qwen", "future-agent"])
        #expect(WiringPrefs.parse("") == [])
    }

    @Test func aMissingFileDisablesNothing() {
        #expect(WiringPrefs.load(home: home) == [])
        #expect(!WiringPrefs.isDisabled("claude", home: home))
    }

    @Test func saveRoundTripsAndKeepsUnknownIds() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".agentbar"),
                                                withIntermediateDirectories: true)
        try "future-agent\n".write(to: WiringPrefs.url(home: home), atomically: true, encoding: .utf8)
        try WiringPrefs.set("cursor", disabled: true, home: home)
        #expect(WiringPrefs.load(home: home) == ["cursor", "future-agent"])
        let attrs = try FileManager.default.attributesOfItem(atPath: WiringPrefs.url(home: home).path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o644)
        let text = try String(contentsOf: WiringPrefs.url(home: home), encoding: .utf8)
        #expect(text.hasPrefix("#"))
        #expect(text.hasSuffix("cursor\nfuture-agent\n"))

        try WiringPrefs.set("cursor", disabled: false, home: home)
        try WiringPrefs.set("future-agent", disabled: false, home: home)
        // Nothing disabled has one spelling on disk: no file.
        #expect(!FileManager.default.fileExists(atPath: WiringPrefs.url(home: home).path))
    }
}
