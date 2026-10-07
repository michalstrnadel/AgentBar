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
