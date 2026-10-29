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
