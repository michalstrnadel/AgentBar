import Foundation
import Testing
@testable import AgentBar

/// When an agent was working, read from Claude Code's transcript, and the
/// stretches AgentBar records itself.
@Suite struct WorkSpansTests {
    private func line(_ type: String, _ at: String, content: String, meta: Bool = false) -> Substring {
        let m = meta ? #","isMeta":true"# : ""
        return Substring(#"{"type":"\#(type)","timestamp":"2026-10-07T\#(at)Z","message":{"role":"\#(type)","content":\#(content)}\#(m)}"#)
    }
    private let prompt = #""fix the bug""#
    private let step = #"[{"type":"tool_use","name":"Bash"}]"#
    private let result = #"[{"type":"tool_result","content":"ok"}]"#

    @Test func aTurnRunsFromThePromptToItsLastStep() {
        let r = WorkSpans.claude(lines: [
            line("user", "10:00:00", content: prompt),
            line("assistant", "10:00:20", content: step),
            line("user", "10:01:00", content: result),        // a tool result is not a prompt
            line("assistant", "10:03:00", content: step),
            line("user", "11:00:00", content: prompt),
            line("assistant", "11:02:00", content: step),
        ])
        #expect(r.prompts.count == 2)
        #expect(r.spans.count == 2)
        #expect(r.spans[0].seconds == 180)
        #expect(r.spans[1].seconds == 120)
    }

    @Test func aLongSilenceInsideATurnIsWaitingNotWork() {
        let r = WorkSpans.claude(lines: [
            line("user", "10:00:00", content: prompt),
            line("assistant", "10:01:00", content: step),
            // twenty minutes on a permission prompt
            line("assistant", "10:21:00", content: step),
            line("assistant", "10:22:00", content: step),
        ])
        #expect(r.spans.count == 2)
        #expect(r.spans.reduce(0) { $0 + $1.seconds } == 120)
    }

    @Test func metaLinesAndUnstampedLinesAreNotPrompts() {
        let r = WorkSpans.claude(lines: [
            line("user", "10:00:00", content: prompt, meta: true),
            Substring(#"{"type":"user","message":{"role":"user","content":"no stamp"}}"#),
        ])
        #expect(r.prompts.isEmpty && r.spans.isEmpty)
    }

    @Test func nearlyTouchingStretchesAreOne() {
        let j = WorkSpans.joined([.init(start: 0, end: 10), .init(start: 25, end: 40), .init(start: 100, end: 110)])
        #expect(j == [.init(start: 0, end: 40), .init(start: 100, end: 110)])
    }

    @Test func spansRoundTripThroughTheHistoryLine() throws {
        var r = try #require(HistoryStore.Record(jsonLine: #"{"agent":"codex","sessionId":"s","startedAt":1,"endedAt":9}"#))
        #expect(r.spans == nil)
        r.spans = [.init(start: 2, end: 5)]
        let data = try JSONSerialization.data(withJSONObject: r.json)
        let back = try #require(HistoryStore.Record(jsonLine: String(data: data, encoding: .utf8)!))
        #expect(back.spans == [.init(start: 2, end: 5)])
    }
}

/// The transcript reader works on bytes; these hold it to what the old
/// JSON-per-line reader did, and to the cases it now has to get right itself.
@Suite struct ClaudeScanTests {
    private func read(_ lines: [String]) -> WorkSpans.Read {
        WorkSpans.claude(lines: lines.map { Substring($0) })
    }

    @Test func theTopLevelTimestampWinsOverOneInsideAToolInput() {
        let r = read([
            #"{"type":"user","message":{"role":"user","content":"go"},"timestamp":"2026-10-07T10:00:00.000Z"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"timestamp":"2020-01-01T00:00:00Z"}}]},"timestamp":"2026-10-07T10:02:30.500Z"}"#,
        ])
        #expect(r.prompts.count == 1)
        #expect(r.spans.first?.seconds == 150.5)
    }

    @Test func quotedTextCannotPassForStructure() {
        // A prompt whose text mentions a tool result is still a prompt: inside a
        // JSON string the quotes are escaped, so it cannot match the key.
        let r = read([
            #"{"type":"user","message":{"role":"user","content":"why is \"type\":\"tool_result\" here"},"timestamp":"2026-10-07T10:00:00Z"}"#,
        ])
        #expect(r.prompts.count == 1)
    }

    @Test func sidechainLinesAreSkipped() {
        let r = read([
            #"{"type":"user","message":{"role":"user","content":"go"},"timestamp":"2026-10-07T10:00:00Z"}"#,
            #"{"isSidechain":true,"type":"assistant","message":{},"timestamp":"2026-10-07T10:04:00Z"}"#,
            #"{"type":"assistant","message":{},"timestamp":"2026-10-07T10:01:00Z"}"#,
        ])
        #expect(r.spans.first?.seconds == 60)
    }

    @Test func theFastDateMatchesTheFormatter() {
        for s in ["2026-10-07T10:00:20.123Z", "2026-02-28T23:59:59Z", "2024-02-29T12:00:00.5Z", "1999-12-31T00:00:00Z"] {
            let fast = Array(s.utf8).withUnsafeBytes { WorkSpans.ClaudeScan.iso($0) }
            #expect(fast == WeightReader.parseISO(s)?.timeIntervalSince1970, "\(s)")
        }
    }
}

@Suite struct WrapPlaceholderTests {
    @Test func thePlaceholderHasTodaysDatesAndSaysItIsNotDone() {
        let now = Date(timeIntervalSince1970: 1_791_500_000)
        let w = DayWrap.placeholder(.today, now: now.timeIntervalSince1970)
        #expect(w.pending)
        #expect(w.start == Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        #expect(WrapCardView.spoken(w) == "Your day with agents. Adding it up.")
    }
}
