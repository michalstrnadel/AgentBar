import Foundation
import Testing
@testable import AgentBar

/// The last hour of a session, as AgentBar saw it.
@Suite struct SessionTimelineTests {
    private func session(_ state: String) -> Session {
        // A row's id is its file name.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s.json")
        try? Data(#"{"sessionId":"s","agent":"claude","state":"\#(state)","ts":1}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: dir) }
        return Session(fileURL: url)!
    }

    @Test func aPhaseChangeStartsASegmentAndTicksExtendIt() {
        let t = SessionTimeline()
        t.observe([session("tool")], now: 1_000)
        t.observe([session("thinking")], now: 1_300)          // still working
        t.observe([session("permission")], now: 1_600)
        t.observe([session("tool")], now: 1_720)
        #expect(t.strip(for: "s", now: 1_720).map(\.phase) == [.working, .waiting, .working])
        #expect(SessionTimeline.summary(t.strip(for: "s", now: 1_720)) == "last hour: worked 10m · waited on you 2m")
    }

    @Test func onlyTheLastHourIsKept() {
        let t = SessionTimeline()
        t.observe([session("tool")], now: 0)
        t.observe([session("done")], now: 100)
        t.observe([session("done")], now: 5_000)
        let strip = t.strip(for: "s", now: 5_000)
        #expect(strip.map(\.phase) == [.rest])
        #expect(!SessionTimeline.worthShowing(strip))
    }

    @Test func aSessionThatIsGoneIsForgotten() {
        let t = SessionTimeline()
        t.observe([session("tool")], now: 0)
        t.observe([], now: 10)
        #expect(t.segments.isEmpty)
    }
}
