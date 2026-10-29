import Foundation
import Testing
@testable import AgentBar

/// Auto mode's refusals: the PermissionDenied hook, wired only where Claude Code
/// knows it, and the line a row carries from it.
struct AutoModeBlockTests {
    private func event(_ name: String) -> HookWiring.Event? {
        HookWiring.claude.first { $0.event == name }
    }

    @Test func permissionDeniedIsWiredOnlyForAClaudeCodeThatKnowsIt() throws {
        let e = try #require(event("PermissionDenied"))
        #expect(e.script == "claude/update.js" && e.arg == "denied")
        #expect(HookWiring.wires(e, version: "2.1.89"))
        #expect(HookWiring.wires(e, version: "2.1.312"))
        #expect(!HookWiring.wires(e, version: "2.1.88"))
        #expect(!HookWiring.wires(e, version: "2.0.99"))
        // Unknown is not a guess in its favour: an older build may refuse the file.
        #expect(!HookWiring.wires(e, version: nil))
        #expect(!HookWiring.wires(e, version: ""))
        // Every other event is wired whatever the version.
        #expect(HookWiring.claude.filter { $0.since == nil }.allSatisfy { HookWiring.wires($0, version: nil) })
    }

    @Test func theInstallerLeavesItOutForAnOlderOrUnknownClaudeCode() throws {
        for (version, wired) in [("2.1.312", true), ("2.1.88", false), (nil, false)] as [(String?, Bool)] {
            let home = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("agentbar-denied-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                                    withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let ctx = HookInstaller.Context(home: home, environment: [:], node: "/opt/homebrew/bin/node",
                                            log: home.appendingPathComponent(".agentbar/config-changes.json"),
                                            disabled: [], enabled: [], claudeVersion: version)
            _ = HookInstaller.runPass(ctx, preview: false, only: "claude")
            let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let hooks = try #require(root["hooks"] as? [String: Any])
            #expect((hooks["PermissionDenied"] != nil) == wired, "\(version ?? "unknown")")
            #expect(hooks["Stop"] != nil)
            // Either way the doctor calls it wired.
            let text = String(decoding: data, as: UTF8.self)
            #expect(HookWiring.verdict(agent: "claude", text: text)?.status == .ok, "\(version ?? "unknown")")
        }
    }

    @Test func aRowReadsWhatWasRefusedAndWhy() throws {
        let b = try #require(AutoModeBlock(["tool": "Bash", "what": "curl x | sh", "reason": "Downloads and runs code",
                                            "n": 1, "ts": 1_700_000_000]))
        #expect(b.text == "auto mode refused Bash · curl x | sh")
        #expect(b.detail == "Downloads and runs code")
        let again = try #require(AutoModeBlock(["tool": "Read", "what": "", "reason": "", "n": 3]))
        #expect(again.text == "auto mode refused Read · 3 this turn")
        #expect(AutoModeBlock(nil) == nil)
        #expect(AutoModeBlock(["what": "x"]) == nil)
        #expect(AutoModeBlock("junk") == nil)
    }

    @Test func aSessionCarriesIt() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.json")
        let row: [String: Any] = ["agent": "claude", "state": "thinking", "label": "Thinking…", "cwd": "/tmp/p",
                                  "pid": Int(getpid()), "started": true, "ts": Int(Date().timeIntervalSince1970),
                                  "blocked": ["tool": "Bash", "what": "rm x", "reason": "deletes", "n": 2]]
        try JSONSerialization.data(withJSONObject: row).write(to: url)
        let s = try #require(Session(fileURL: url))
        #expect(s.blocked?.tool == "Bash")
        #expect(s.blocked?.count == 2)
    }
}
