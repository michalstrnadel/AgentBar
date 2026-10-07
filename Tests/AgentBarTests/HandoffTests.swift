import AppKit
import Testing
@testable import AgentBar

private func session(_ fields: [String: Any]) throws -> Session {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("h-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    var o: [String: Any] = ["agent": "claude", "state": "thinking", "started": true, "ts": 1_000,
                            "project": "webshop", "cwd": NSTemporaryDirectory(), "pid": 4242,
                            "term_program": "iTerm.app"]
    o.merge(fields) { $1 }
    try JSONSerialization.data(withJSONObject: o).write(to: url)
    return try #require(Session(fileURL: url))
}

/// Carrying a session over to another agent: what the prompt says, who it can go
/// to, and when the quota makes it worth offering.
@Suite struct HandoffTests {
    @Test func thePromptSaysWhereItGotToOnOneLine() throws {
        let s = try session(["prompt": "make the checkout button\nmatch the mockup",
                             "recap": "Restyled the checkout button."])
        let p = Handoff.prompt(for: s)
        #expect(!p.contains("\n"))
        #expect(p.contains("Claude Code") || p.contains("Claude"))
        #expect(p.contains("webshop"))
        #expect(p.contains("make the checkout button match the mockup"))
        #expect(p.contains("Restyled the checkout button."))
        #expect(p.contains("git diff"))
    }

    @Test func noTaskRecordedSaysSoInsteadOfInventingOne() throws {
        let p = Handoff.prompt(for: try session([:]))
        #expect(p.contains("tell you what the task was"))
        #expect(!p.contains("The task:"))
    }

    @Test func longWordsAreCutAtAWordAndMarked() {
        let long = String(repeating: "refactor the module ", count: 20)
        let c = Handoff.clip(long, 60)
        #expect(c.count <= 60)
        #expect(c.hasSuffix("…"))
        #expect(!c.contains("  "))
        // The prompt's own quotes stay the only curly ones.
        #expect(!Handoff.clip("say “hi”", 50).contains("“"))
    }

    @Test func itGoesToAnyOtherAgentPromptTakersFirst() throws {
        let s = try session([:])
        let all = Agent.all
        let t = Handoff.targets(from: s, launchable: all)
        #expect(!t.contains { $0.id == "claude" })
        if let firstNo = t.firstIndex(where: { !$0.takesPrompt }) {
            #expect(!t[..<firstNo].contains { !$0.takesPrompt })
            #expect(!t[firstNo...].contains { $0.takesPrompt })
        }
    }

    @Test func runningOutOnlyWhenTheForecastIsUnderHalfAnHour() throws {
        let s = try session([:])
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let w = UsageWindow(name: "5h", usedPercent: 90, resetsAt: now.addingTimeInterval(7_200))
        let readings = [UsageCenter.Reading(provider: "Claude", text: "", windows: [w])]
        let soon = UsagePace.Forecast(runsOutAt: now.addingTimeInterval(1_200), perHour: 30)
        let later = UsagePace.Forecast(runsOutAt: now.addingTimeInterval(4_000), perHour: 9)
        #expect(Handoff.runningOut(s, readings: readings, forecast: { _, _ in soon }, now: now) == soon)
        #expect(Handoff.runningOut(s, readings: readings, forecast: { _, _ in later }, now: now) == nil)
        // Another provider's quota is not this session's.
        let codex = [UsageCenter.Reading(provider: "Codex", text: "", windows: [w])]
        #expect(Handoff.runningOut(s, readings: codex, forecast: { _, _ in soon }, now: now) == nil)
    }

    @Test func aCloudSessionHasNothingToCarryHere() throws {
        #expect(!Handoff.canHandOff(try session(["entrypoint": "cloud"])))
        #expect(!Handoff.canHandOff(try session(["cwd": "/nonexistent/agentbar-handoff"])))
        #expect(Handoff.canHandOff(try session([:])))
    }

    @Test func theFillIsTheSameProjectAndTheChosenAgent() throws {
        let s = try session([:])
        let codex = Agent.byID("codex")
        let f = Handoff.fill(s, to: codex)
        #expect(f.cwd == s.cwd && f.agent == "codex")
        #expect(f.prompt == Handoff.prompt(for: s))
    }
}
