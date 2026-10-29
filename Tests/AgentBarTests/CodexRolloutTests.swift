import Foundation
import Testing
@testable import AgentBar

/// Context and subagents for Codex rows, out of the rollout. The lines are written
/// for these tests in the shapes measured on Codex CLI 0.153–0.157 rollouts; none
/// is copied from a real session.
@Suite struct CodexRolloutTests {
    private func tokens(last: Int, input: Int = 0, cached: Int = 0, total: Int = 40_000_000,
                        window: Int = 258_400) -> String {
        #"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":\#(total - 1000),"output_tokens":5000,"total_tokens":\#(total + 5000)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":51,"total_tokens":\#(last)},"model_context_window":\#(window)},"rate_limits":{"limit_id":"codex","primary":{"used_percent":4.0,"window_minutes":300,"resets_at":1790000000}}}}"#
    }
    private func turn(_ kind: String) -> String {
        #"{"timestamp":"t","type":"event_msg","payload":{"type":"\#(kind)","turn_id":"t1"}}"#
    }
    private func activity(_ kind: String, _ path: String, ms: Int = 1_790_000_000_000) -> String {
        #"{"timestamp":"t","type":"event_msg","payload":{"type":"item_completed","thread_id":"p","turn_id":"t1","item":{"type":"SubAgentActivity","id":"call_x","kind":"\#(kind)","agent_thread_id":"c-\#(path)","agent_path":"\#(path)"},"started_at_ms":\#(ms),"completed_at_ms":\#(ms)}}"#
    }
    private let spawn = #"{"timestamp":"t","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","namespace":"collaboration","arguments":"{\"task_name\":\"core_review\",\"fork_turns\":\"none\",\"message\":\"opaque\"}"}}"#

    // MARK: - Context

    /// The last request's whole size over the window — not the thread's running
    /// total, which is tens of millions, and not input plus cached, which counts
    /// the cache twice.
    @Test func contextIsTheLastRequestOverTheWindow() {
        let r = CodexRollout([tokens(last: 129_200, input: 129_149, cached: 120_000)])
        #expect(r.contextPercent == 50)
    }

    @Test func theNewestReportWinsAndANullInfoSaysNothing() {
        let r = CodexRollout([
            tokens(last: 25_840),
            tokens(last: 77_520),
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{}}}"#,
        ])
        #expect(r.contextPercent == 30)
    }

    @Test func noReportNoWindowOrNonsenseIsNoFigure() {
        #expect(CodexRollout([turn("task_started")]).contextPercent == nil)
        #expect(CodexRollout([tokens(last: 1000, window: 0)]).contextPercent == nil)
        #expect(CodexRollout(["not json", "{\"type\":\"event_msg\"}"]).contextPercent == nil)
        // Over the window reads as full, never more.
        #expect(CodexRollout([tokens(last: 400_000)]).contextPercent == 100)
    }

    /// A compaction shows as the drop it is — and the drop is what resets the
    /// compacts-soon forecast.
    @Test func aCompactionDrops() {
        let r = CodexRollout([tokens(last: 230_000), turn("task_started"), tokens(last: 20_000)])
        #expect(r.contextPercent == 8)
    }

    /// The gauge and the forecast are Claude's code, fed nothing Claude-specific:
    /// a Codex row whose rollout climbs turn by turn gets "compacts soon".
    @Test func theForecastWorksForACodexRow() {
        let trend = ContextTrend()
        var row = Session(preview: .thinking, agentID: "codex", project: "p", label: "")
        for last in [180_000, 196_000, 212_000] {   // 70%, 76%, 82%
            row.state = .thinking
            row = CodexRolloutReader.apply(CodexRollout([tokens(last: last)]), to: row)
            trend.observe([row])
            row.state = .done
            trend.observe([row])
        }
        #expect(row.contextPercent == 82)
        #expect(trend.forecast(for: row) == ContextTrend.Forecast(turns: 2))
        #expect(ContextGauge.detail(row.contextPercent, forecast: trend.forecast(for: row)) != nil)
    }

    @Test func applyLeavesWhatTheRolloutLacks() {
        var row = Session(preview: .thinking, agentID: "codex", project: "p", label: "")
        row.contextPercent = 40
        let out = CodexRolloutReader.apply(CodexRollout(), to: row)
        #expect(out.contextPercent == 40)
        #expect(out.subagentDetails.isEmpty)
    }

    // MARK: - Subagents

    @Test func startedSubagentsCountUntilTheyComplete() {
        var r = CodexRollout([
            turn("task_started"), spawn,
            activity("started", "/root/core_review", ms: 1_790_000_000_000),
            activity("started", "/root/ui_review", ms: 1_790_000_005_000),
        ])
        #expect(r.agents.map(\.what) == ["core_review", "ui_review"])
        #expect(r.agents.map(\.type) == ["agent", "agent"])
        #expect(r.agents.first?.since == 1_790_000_000)
        r.feed(activity("completed", "/root/core_review"))
        #expect(r.agents.map(\.what) == ["ui_review"])
        // A message to a running child is not a second child.
        r.feed(activity("interacted", "/root/ui_review"))
        #expect(r.agents.count == 1)
    }

    /// A child sent a follow-up after it had finished is working again.
    @Test func aFollowUpBringsAFinishedChildBack() {
        let r = CodexRollout([
            turn("task_started"),
            activity("started", "/root/core_review"),
            activity("completed", "/root/core_review"),
            activity("interacted", "/root/core_review", ms: 1_790_000_100_000),
        ])
        #expect(r.agents.map(\.what) == ["core_review"])
        #expect(r.agents.first?.since == 1_790_000_100)
    }

    /// Measured: a turn can end with children it sent follow-ups to and no
    /// `completed` for any of them. Past the turn's end the file cannot tell
    /// running from abandoned, so nothing is claimed.
    @Test func onlyTheCurrentTurnCounts() {
        let started = [turn("task_started"), activity("started", "/root/a")]
        #expect(CodexRollout(started + [turn("task_complete")]).agents.isEmpty)
        #expect(CodexRollout(started + [turn("turn_aborted")]).agents.isEmpty)
        #expect(CodexRollout(started + [turn("task_started")]).agents.isEmpty)
    }

    @Test func theParentItselfAndUnknownKindsChangeNothing() {
        let r = CodexRollout([
            turn("task_started"),
            activity("interacted", "/root"),            // a child talking to its parent
            activity("started", "/root/a"),
            activity("errored", "/root/a"),            // a kind never measured
            spawn,                                      // the call alone is not the start
        ])
        #expect(r.agents.map(\.what) == ["a"])
    }

    // MARK: - Reading as the file grows

    @Test func theReaderFoldsOnlyWholeAppendedLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-rollout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollout-x.jsonl")
        var stamp = Date(timeIntervalSince1970: 1_000)
        func write(_ text: String, append: Bool = true) throws {
            if append, let h = try? FileHandle(forWritingTo: url) {
                try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8)); try h.close()
            } else {
                try Data(text.utf8).write(to: url)
            }
            stamp += 1
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        }
        let reader = CodexRolloutReader()
        try write(turn("task_started") + "\n" + tokens(last: 25_840) + "\n", append: false)
        #expect(reader.read(url)?.contextPercent == 10)

        // Half a line: not read until its newline lands.
        let next = tokens(last: 51_680)
        try write(String(next.prefix(40)))
        #expect(reader.read(url)?.contextPercent == 10)
        try write(String(next.dropFirst(40)) + "\n" + activity("started", "/root/a") + "\n")
        #expect(reader.read(url)?.contextPercent == 20)
        #expect(reader.read(url)?.agents.count == 1)

        // Replaced by a shorter file: read again from the start.
        try write(tokens(last: 12_920) + "\n", append: false)
        #expect(reader.read(url)?.contextPercent == 5)
        #expect(reader.read(url)?.agents.isEmpty == true)
    }
}
