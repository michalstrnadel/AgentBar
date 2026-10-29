import Foundation
import Testing
@testable import AgentBar

/// Which subagent asked, and which are working: read from what the hooks wrote.
@Suite struct SubagentTests {
    private func decode<T>(_ json: String, _ make: (URL) -> T?) -> T? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sub-\(UUID().uuidString).json")
        try? json.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return make(url)
    }

    private func request(_ extra: String) -> ApprovalRequest? {
        decode("""
        {"sessionId":"s","agent":"claude","toolName":"Bash","display":"Bash: ls",
         "toolInputPretty":"{}","pid":1,"hookPid":2,"ts":1\(extra)}
        """) { ApprovalRequest(fileURL: $0) }
    }

    @Test func aSubagentsRequestNamesIt() {
        #expect(request(#","agentId":"a-1","agentType":"code-reviewer""#)?.subagent == "code-reviewer")
        #expect(request(#","agentId":"a-1""#)?.subagent == "subagent")
    }

    @Test func aTypeWithoutAnIdIsTheSessionItself() {
        // `claude --agent x`: the main thread carries agent_type and no agent_id.
        #expect(request(#","agentType":"planner""#)?.subagent == nil)
        #expect(request("")?.subagent == nil)
    }

    @Test func theLedgerRowCarriesIt() {
        guard let r = request(#","agentId":"a-1","agentType":"code-reviewer""#) else {
            Issue.record("no request"); return
        }
        let row = DecisionLedger.shared.row("allow", request: r, session: nil, via: "rule", rule: "r", would: "", now: 10)
        #expect(row?.agentType == "code-reviewer")
        #expect(row.map { DecisionLedger.Record(jsonLine: String(data: try! JSONSerialization.data(withJSONObject: $0.json), encoding: .utf8)!)?.agentType } == "code-reviewer")
    }

    @Test func theSessionListsItsWorkingSubagents() {
        let s = decode("""
        {"sessionId":"s","agent":"claude","state":"tool","ts":1,
         "subagentRuns":[{"id":"a","type":"Explore","ts":1},{"id":"b","type":"code-reviewer","ts":1}]}
        """) { Session(fileURL: $0) }
        #expect(s?.subagentTypes == ["Explore", "code-reviewer"])
        #expect(s?.subagentCount == 2)
    }
}

/// The audit export: every field, one object a line, after a header.
@Suite struct LedgerExportTests {
    @Test func jsonLinesKeepEveryFieldOldestFirst() throws {
        var a = DecisionLedger.Record(); a.ts = 200; a.shape = "bash:ls"; a.decision = "allow"
        a.sessionId = "s1"; a.agentType = "code-reviewer"; a.reason = "why"
        var b = DecisionLedger.Record(); b.ts = 100; b.shape = "bash:rm"; b.decision = "deny"
        let text = DecisionLedger.jsonl([a, b], generator: "AgentBar test", since: nil,
                                        now: Date(timeIntervalSince1970: 300))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        let header = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(header["agentbarExport"] as? Int == 1)
        #expect(header["rows"] as? Int == 2)
        #expect(header["since"] is NSNull)
        #expect(DecisionLedger.Record(jsonLine: lines[1])?.shape == "bash:rm")
        let last = DecisionLedger.Record(jsonLine: lines[2])
        #expect(last?.agentType == "code-reviewer")
        #expect(last?.sessionId == "s1")
        #expect(last?.reason == "why")
    }
}

/// The agent's own task list, as the row carries it.
@Suite struct TaskProgressTests {
    @Test func readsTheCountAndTheStep() {
        let t = TaskProgress(["done": 3, "total": 7, "now": "Running\ntests"])
        #expect(t?.text == "3/7 · Running tests")
        #expect(t?.fraction == 3.0 / 7.0)
    }

    @Test func nonsenseIsNoProgress() {
        #expect(TaskProgress(["done": 1, "total": 0]) == nil)
        #expect(TaskProgress(["done": -1, "total": 3]) == nil)
        #expect(TaskProgress("3/7") == nil)
        #expect(TaskProgress(["done": 9, "total": 3])?.done == 3)
    }
}
