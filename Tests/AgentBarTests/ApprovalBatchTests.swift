import Foundation
import Testing
@testable import AgentBar

/// Allow all alike: the same tool, the whole same input and the same directory —
/// and only the requests that were on screen when the click landed.
@Suite struct ApprovalBatchTests {
    private func request(session: String, tool: String = "Bash", input: String = #"{"command":"npm test"}"#,
                         cwd: String = "/tmp/proj", hookPid: Int = 2, ts: Int = 100,
                         extra: String = "") -> ApprovalRequest {
        let json = """
        {"sessionId":"\(session)","agent":"claude","toolName":"\(tool)","display":"\(tool): npm test",
         "toolInputPretty":\(quoted(input)),"cwd":"\(cwd)","pid":1,"hookPid":\(hookPid),"ts":\(ts)\(extra)}
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("batch-\(UUID().uuidString).json")
        try? json.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return ApprovalRequest(fileURL: url)!
    }

    private func quoted(_ s: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!
            .dropFirst().dropLast().description
    }

    @Test func theSameRequestInThreeSessionsIsOneGroup() {
        let a = request(session: "a", hookPid: 2, ts: 100)
        let b = request(session: "b", hookPid: 3, ts: 101)
        let c = request(session: "c", hookPid: 4, ts: 99)
        let group = ApprovalBatch.alike(a, in: [a, b, c])
        #expect(group.count == 3)
        #expect(group.first?.sessionId == "c")   // oldest first
    }

    @Test func aDifferentInputToolOrDirectoryIsNotTheSameRequest() {
        let a = request(session: "a")
        let force = request(session: "b", input: #"{"command":"npm test --force"}"#, hookPid: 3)
        let other = request(session: "c", cwd: "/tmp/other", hookPid: 4)
        let edit = request(session: "d", tool: "Edit", hookPid: 5)
        #expect(ApprovalBatch.alike(a, in: [a, force, other, edit]).count == 1)
    }

    @Test func aDirectoryFromTheSessionCountsWhenTheRequestHasNone() {
        let a = request(session: "a", cwd: "")
        let b = request(session: "b", cwd: "", hookPid: 3)
        let dirs = ["a": "/tmp/x", "b": "/tmp/x"]
        #expect(ApprovalBatch.alike(a, in: [a, b], cwd: { dirs[$0.sessionId] ?? "" }).count == 2)
        // With no directory at all there is no telling where it would run: never batched.
        #expect(ApprovalBatch.alike(a, in: [a, b]).count == 1)
    }

    @Test func plansNeverBatch() {
        let a = request(session: "a", tool: "ExitPlanMode")
        let b = request(session: "b", tool: "ExitPlanMode", hookPid: 3)
        #expect(ApprovalBatch.key(a) == nil)
        #expect(ApprovalBatch.alike(a, in: [a, b]).count == 1)
    }

    @Test func onlyWhatWasShownAndIsStillWaitingIsAnswered() {
        let a = request(session: "a", hookPid: 2)
        let b = request(session: "b", hookPid: 3)
        let late = request(session: "c", hookPid: 4)
        let shown = [a.identity, b.identity]
        // b was answered in its terminal meanwhile; c arrived after the button was drawn.
        let now = ApprovalBatch.stillPending(shown, in: [a, late])
        #expect(now.map(\.sessionId) == ["a"])
    }
}
