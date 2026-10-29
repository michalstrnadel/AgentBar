import Foundation
import Testing
@testable import AgentBar

/// The mascot's pace follows the session's: tool edges a minute in, a frame-rate
/// multiplier out, and a working session that has gone quiet is stalled.
struct TempoTests {
    private func tick(_ t: inout Tempo, _ state: Session.State, _ label: String, at now: TimeInterval,
                      id: String = "s") {
        t.observe([.init(id: id, state: state, label: label)], now: now)
    }

    @Test func theMultiplierRunsFromSlowToBusy() {
        #expect(Tempo.multiplier(rate: 0) == Tempo.range.lowerBound)
        #expect(Tempo.multiplier(rate: Tempo.natural) == 1)
        #expect(Tempo.multiplier(rate: Tempo.busy) == Tempo.range.upperBound)
        #expect(Tempo.multiplier(rate: 500) == Tempo.range.upperBound)
        #expect(Tempo.multiplier(rate: 4) > 0.6 && Tempo.multiplier(rate: 4) < 1)
        #expect(Tempo.multiplier(rate: 14) > 1 && Tempo.multiplier(rate: 14) < 1.6)
    }

    @Test func aBusySessionPlaysFasterThanAQuietOne() {
        var t = Tempo()
        // Busy: a tool every 2 s for a minute — thirty edges.
        for i in 0..<30 {
            tick(&t, i % 2 == 0 ? .tool : .thinking, i % 2 == 0 ? "Reading" : "Thinking…",
                 at: 1_000 + Double(i) * 2)
        }
        #expect(t.multiplier(for: "s", now: 1_060) == Tempo.range.upperBound)
        // Quiet: two edges over the next minute.
        tick(&t, .tool, "Editing", at: 1_090)
        tick(&t, .thinking, "Thinking…", at: 1_120)
        #expect(t.multiplier(for: "s", now: 1_121) < 1)
        // The same state ticked again is no edge.
        var still = Tempo()
        for i in 0..<20 { tick(&still, .tool, "Reading", at: 1_000 + Double(i)) }
        #expect(still.multiplier(for: "s", now: 1_020) == Tempo.range.lowerBound)
    }

    @Test func oneEdgeRightAfterLaunchIsNotSixtyAMinute() {
        var t = Tempo()
        tick(&t, .tool, "Reading", at: 1_000)
        tick(&t, .thinking, "Thinking…", at: 1_001)
        #expect(t.rate(for: "s", now: 1_001) == 60.0 / Tempo.shortest)
    }

    @Test func aWorkingSessionThatGoesQuietStalls() {
        var t = Tempo()
        tick(&t, .tool, "Using tool", at: 1_000)
        tick(&t, .tool, "Using tool", at: 1_050)
        #expect(!t.stalled("s", now: 1_050))
        tick(&t, .tool, "Using tool", at: 1_000 + Tempo.stallsAfter)
        #expect(t.stalled("s", now: 1_000 + Tempo.stallsAfter))
        // An edge ends it, and a session that is not working never stalls.
        tick(&t, .thinking, "Thinking…", at: 1_100)
        #expect(!t.stalled("s", now: 1_100))
        tick(&t, .done, "", at: 1_101)
        #expect(!t.stalled("s", now: 9_999))
    }

    @Test func goneSessionsAreForgotten() {
        var t = Tempo()
        tick(&t, .tool, "Reading", at: 1_000, id: "a")
        tick(&t, .thinking, "Thinking…", at: 1_001, id: "a")
        t.observe([.init(id: "b", state: .tool, label: "Reading")], now: 1_002)
        #expect(t.rate(for: "a", now: 1_002) == 0)
        #expect(!t.stalled("a", now: 5_000))
    }

    /// The walk gives way to thinking when stalled; a tool with a picture keeps it.
    @Test func aStallTurnsTheWalkIntoThinking() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tempo-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        for (label, stalled, scene) in [("Using tool", true, ClawdScene.think), ("Using tool", false, .walk),
                                        ("Running command", true, .hammer)] {
            try JSONSerialization.data(withJSONObject: ["agent": "claude", "state": "tool", "label": label,
                                                        "ts": 1_000]).write(to: url)
            let s = try #require(Session(fileURL: url))
            #expect(ClawdScene.scene(for: s, now: 1_000, stalled: stalled) == scene, "\(label) \(stalled)")
        }
    }
}
