import Foundation
import Testing
@testable import AgentBar

/// A turn as a level: each tool is its scene, errors are pits, waits are gates,
/// long gaps are a longer walk rather than a longer clip, and nothing the agent
/// said goes in unless names may be shown.
@Suite struct ReplayLevelTests {
    private let t0: TimeInterval = 1_790_000_000

    private func tool(_ dt: TimeInterval, _ name: String, _ arg: String = "x") -> TimelinePeek.Entry {
        .init(at: t0 + dt, item: .tool(name, arg))
    }

    private func stations(_ l: ReplayLevel.Level) -> [(ClawdScene, String, Int)] {
        l.beats.compactMap { if case let .station(s, w, n) = $0.kind { return (s, w, n) }; return nil }
    }

    @Test func eachToolIsItsScene() {
        let l = ReplayLevel.make(entries: [tool(0, "Read"), tool(5, "Bash"), tool(10, "Edit"), tool(15, "Grep"),
                                           tool(20, "WebFetch"), tool(25, "Agent"), tool(30, "linear_create")],
                                 includeSaid: false)
        #expect(stations(l).map(\.0) == [.read, .hammer, .type, .search, .web, .delegate, .walk])
        #expect(stations(l).map(\.1) == ["Read", "Run", "Edit", "Search", "Web", "Agent", "Tool"])
        #expect(l.beats.last?.kind == .flag)
        #expect(l.steps == 7)
    }

    @Test func anUnknownToolSaysItsNameOnlyWhenNamesMayShow() {
        let named = ReplayLevel.make(entries: [tool(0, "linear_create")], includeSaid: true)
        #expect(stations(named).first?.1 == "linear_create")
    }

    @Test func theSameToolInARowIsOneStationWithACount() {
        let l = ReplayLevel.make(entries: [tool(0, "Read"), tool(1, "Read"), tool(2, "Read"), tool(3, "Edit")],
                                 includeSaid: false)
        #expect(stations(l).map(\.2) == [3, 1])
        #expect(l.steps == 4)
    }

    @Test func anErrorIsAPitAfterTheStepThatFailed() {
        let l = ReplayLevel.make(entries: [tool(0, "Bash", "swift test"), tool(30, "Edit")],
                                 failures: [.init(at: t0 + 10, tests: true)], includeSaid: false)
        let kinds = l.beats.map(\.kind)
        #expect(kinds.count == 4)
        #expect(kinds[1] == .pit(tests: true))
        #expect(l.errors == 1)
        // Clawd clears it: he leaves from past its far side.
        let pit = l.beats[1]
        #expect(pit.x1 >= pit.x0 + 13 + ReplayLevel.pitWidth)
        if case .hop = ReplayLevel.clawd(at: (pit.arrive + pit.leave) / 2, in: l).pose {} else {
            Issue.record("Clawd is not hopping over the pit")
        }
        // An error between two Reads keeps them apart.
        let split = ReplayLevel.make(entries: [tool(0, "Read"), tool(5, "Read")],
                                     failures: [.init(at: t0 + 2)], includeSaid: false)
        #expect(stations(split).map(\.2) == [1, 1])
    }

    @Test func aWaitOnYouIsAGateThatOpens() {
        let segments: [SessionTimeline.Segment] = [
            .init(phase: .working, start: t0, end: t0 + 20),
            .init(phase: .waiting, start: t0 + 20, end: t0 + 140),
            .init(phase: .working, start: t0 + 140, end: t0 + 200),
        ]
        let l = ReplayLevel.make(entries: [tool(0, "Bash"), tool(150, "Bash", "y")], segments: segments,
                                 includeSaid: false)
        let gates = l.beats.filter { if case .gate = $0.kind { return true }; return false }
        #expect(gates.count == 1)
        #expect(gates.first?.kind == .gate(waited: 120))
        #expect(l.waited == 120)
        // The time spent at the gate is the gate's: the walk after it is short.
        let after = l.beats[l.beats.firstIndex { $0.kind == .gate(waited: 120) }! + 1]
        #expect(after.gapBefore == 10)
        let g = gates[0]
        guard case let .waiting(open) = ReplayLevel.clawd(at: g.arrive + 0.01, in: l).pose else {
            Issue.record("Clawd is not waiting at the gate"); return
        }
        #expect(open == 0)
        guard case let .waiting(later) = ReplayLevel.clawd(at: g.leave - 0.01, in: l).pose else {
            Issue.record("Clawd left the gate early"); return
        }
        #expect(later > 0.9)
        // A wait in another hour is not this turn's.
        let elsewhere = ReplayLevel.make(entries: [tool(0, "Bash")],
                                         segments: [.init(phase: .waiting, start: t0 - 3_600, end: t0 - 3_500)],
                                         includeSaid: false)
        #expect(!elsewhere.beats.contains { if case .gate = $0.kind { return true }; return false })
    }

    @Test func longGapsAreCompressedIntoTheClip() {
        // Two hours with an hour of nothing in the middle.
        let l = ReplayLevel.make(entries: [tool(0, "Read"), tool(10, "Edit"), tool(3_610, "Bash"),
                                           tool(7_200, "Grep")], includeSaid: false)
        #expect(l.duration >= ReplayLevel.minSeconds && l.duration <= ReplayLevel.maxSeconds)
        #expect(l.realSeconds == 7_200)
        let bash = l.beats[2]
        #expect(bash.gapBefore == 3_600)
        // A longer gap is a longer walk, but never more than twice the room.
        #expect(ReplayLevel.walkDistance(gap: 3_600) > ReplayLevel.walkDistance(gap: 10))
        #expect(ReplayLevel.walkDistance(gap: 1e9) <= 2 * ReplayLevel.spacing)
        // Beats stay in order on both clocks.
        for (a, b) in zip(l.beats, l.beats.dropFirst()) {
            #expect(a.leave <= b.arrive && a.x1 <= b.x0)
        }
    }

    @Test func aShortTurnStillLastsTheShortestClip() {
        let l = ReplayLevel.make(entries: [tool(0, "Read")], includeSaid: false)
        #expect(l.duration == ReplayLevel.minSeconds)
        let empty = ReplayLevel.make(entries: [], includeSaid: false)
        #expect(empty.duration == ReplayLevel.minSeconds)
        #expect(empty.beats.map(\.kind) == [.flag])
    }

    @Test func aHugeTurnKeepsItsEndAndCountsWhatCameBefore() {
        let names = ["Read", "Edit", "Bash", "Grep"]
        let entries = (0..<200).map { tool(Double($0) * 7, names[$0 % names.count]) }
        let l = ReplayLevel.make(entries: entries, includeSaid: false)
        #expect(l.duration <= ReplayLevel.maxSeconds)
        #expect(l.earlier > 0)
        #expect(l.earlier + stations(l).reduce(0) { $0 + $1.2 } == 200)
        #expect(l.steps == 200)
        // The newest step is the last station.
        #expect(stations(l).last?.0 == .search)
    }

    @Test func nothingSaidGoesInWhenItMayBeShared() {
        let words = "Found it: the prompt fires before the timer is cleared, so the hook waits."
        let entries = [tool(0, "Read"), .init(at: t0 + 5, item: .said(words)), tool(10, "Edit")]
        let safe = ReplayLevel.make(entries: entries, includeSaid: false)
        #expect(safe.bubbles.isEmpty)
        let named = ReplayLevel.make(entries: entries, includeSaid: true)
        #expect(named.bubbles.count == 1)
        let text = named.bubbles[0].text
        #expect(text.count <= ReplayLevel.saidLength)
        #expect(text.hasPrefix("Found it"))
        // Said lines do not change the level itself.
        #expect(safe.beats == named.beats)
    }

    @Test func clawdWalksForwardAndEndsAtTheFlag() {
        let l = ReplayLevel.make(entries: [tool(0, "Read"), tool(60, "Bash")],
                                 failures: [.init(at: t0 + 61)], includeSaid: false)
        var last = -1.0
        for i in 0...150 {
            let x = ReplayLevel.clawd(at: l.duration * Double(i) / 150, in: l).x
            #expect(x >= last)
            last = x
        }
        if case .done = ReplayLevel.clawd(at: l.duration, in: l).pose {} else {
            Issue.record("Clawd does not end at the flag")
        }
        if case .walk = ReplayLevel.clawd(at: 0, in: l).pose {} else { Issue.record("Clawd does not start walking") }
    }

    // MARK: - Reading a turn

    private func line(_ type: String, _ at: String, _ content: String, extra: String = "") -> Substring {
        Substring(#"{"type":"\#(type)"\#(extra),"message":{"content":\#(content)},"timestamp":"2026-10-07T10:\#(at).000Z"}"#)
    }

    @Test func theLastTurnStartsAtThePromptAndKnowsItsErrors() {
        let lines: [Substring] = [
            line("user", "00:00", #""first task""#),
            line("assistant", "00:05", #"[{"type":"tool_use","id":"a","name":"Read","input":{"file_path":"/x/Old.swift"}}]"#),
            line("user", "01:00", #""fix the tests""#),
            line("assistant", "01:05", #"[{"type":"text","text":"Running them."},{"type":"tool_use","id":"b","name":"Bash","input":{"command":"swift test"}}]"#),
            line("user", "01:30", #"[{"type":"tool_result","tool_use_id":"b","is_error":true,"content":"1 failed"}]"#),
            line("assistant", "01:31", #"[{"type":"tool_use","id":"c","name":"Read","input":{"file_path":"/x/Sub.swift"}}]"#,
                 extra: #","isSidechain":true"#),
            line("assistant", "01:40", #"[{"type":"tool_use","id":"d","name":"Edit","input":{"file_path":"/x/A.swift"}}]"#),
        ]
        let turn = ReplayTurn.last(lines)
        #expect(turn.entries.map(\.item) == [.said("Running them."), .tool("Bash", "swift test"), .tool("Edit", "A.swift")])
        #expect(turn.failures.count == 1)
        #expect(turn.failures.first?.tests == true)
        #expect(turn.prompted != nil)
        // By a moment in the first turn, the first turn is the one.
        let earlier = ReplayTurn.last(lines, by: turn.prompted! - 30)
        #expect(earlier.entries.map(\.item) == [.tool("Read", "Old.swift")])
    }
}
