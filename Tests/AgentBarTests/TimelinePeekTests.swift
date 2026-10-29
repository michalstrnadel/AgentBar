import Foundation
import Testing
@testable import AgentBar

/// What was it doing then: a point on the hour strip, answered from the transcript.
@Suite struct TimelinePeekTests {
    private let base: TimeInterval = 1_790_000_000 // 2026-09-21T13:33:20Z

    private func iso(_ t: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    private func tool(_ t: TimeInterval, _ file: String) -> Substring {
        Substring(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x/"# + file + #""}}]},"timestamp":""# + iso(t) + #""}"#)
    }

    @Test func xMapsAcrossTheHourAndClampsAtTheEdges() {
        let now = base
        #expect(TimelinePeek.time(atX: 0, width: 300, now: now) == now - 3600)
        #expect(TimelinePeek.time(atX: 300, width: 300, now: now) == now)
        #expect(TimelinePeek.time(atX: 150, width: 300, now: now) == now - 1800)
        #expect(TimelinePeek.time(atX: -20, width: 300, now: now) == now - 3600)
        #expect(TimelinePeek.time(atX: 999, width: 300, now: now) == now)
        #expect(TimelinePeek.time(atX: 10, width: 0, now: now) == now)
        #expect(TimelinePeek.time(atX: .nan, width: 300, now: now) == now)
    }

    @Test func onlyStepsWithinTheWindowCount() {
        let lines = [tool(base - 61, "Early.swift"), tool(base - 59, "Near.swift"),
                     tool(base + 60, "Edge.swift"), tool(base + 90, "Late.swift")]
        let got = TimelinePeek.items(lines: lines, at: Date(timeIntervalSince1970: base))
        #expect(got == [.tool("Read", "Near.swift"), .tool("Read", "Edge.swift")])
    }

    @Test func badTimestampsAreSkippedNotGuessed() {
        let lines: [Substring] = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x/NoStamp.swift"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x/Junk.swift"}}]},"timestamp":"yesterday"}"#,
            // A tool input's own `timestamp` is not the line's.
            Substring(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"date","timestamp":""# + iso(base) + #""}}]},"timestamp":""# + iso(base - 600) + #""}"#),
            Substring(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Looks right."}]},"timestamp":""# + iso(base + 5) + #""}"#),
            #"{"type":"assistant","message":"#,
        ]
        let got = TimelinePeek.items(lines: lines, at: Date(timeIntervalSince1970: base))
        #expect(got == [.said("Looks right.")])
    }

    @Test func atMostThreeTheClosestInTheOrderTheyHappened() {
        let lines = [tool(base - 50, "A.swift"), tool(base - 10, "B.swift"), tool(base - 2, "C.swift"),
                     tool(base + 4, "D.swift"), tool(base + 40, "E.swift")]
        let got = TimelinePeek.items(lines: lines, at: Date(timeIntervalSince1970: base))
        #expect(got == [.tool("Read", "B.swift"), .tool("Read", "C.swift"), .tool("Read", "D.swift")])
    }

    @Test func userLinesAndSubagentsAreLeftOut() {
        let lines: [Substring] = [
            Substring(#"{"type":"user","message":{"content":"hi"},"timestamp":""# + iso(base) + #""}"#),
            Substring(#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"sub"}]},"timestamp":""# + iso(base) + #""}"#),
            tool(base, "Main.swift"),
        ]
        #expect(TimelinePeek.items(lines: lines, at: Date(timeIntervalSince1970: base)) == [.tool("Read", "Main.swift")])
    }

    @Test func phaseAtAMomentAndItsWord() {
        let segs = [SessionTimeline.Segment(phase: .working, start: 0, end: 100),
                    SessionTimeline.Segment(phase: .waiting, start: 100, end: 160)]
        #expect(TimelinePeek.phase(at: 50, in: segs) == .working)
        #expect(TimelinePeek.phase(at: 100, in: segs) == .waiting)
        #expect(TimelinePeek.phase(at: 500, in: segs) == nil)
        #expect(TimelinePeek.word(nil) == "not seen")
        #expect(TimelinePeek.word(.working) == "worked")
    }
}
