import Foundation
import Testing
@testable import AgentBar

/// "Try an approval": a request that exists on screen only, and an answer that
/// writes nothing.
@MainActor
@Suite(.serialized) struct DemoApprovalTests {
    @Test func theDemoDecodesThroughTheRealTypes() throws {
        let pair = try #require(DemoApproval.make())
        #expect(pair.session.id == DemoApproval.sessionID)
        #expect(pair.session.state == .permission)
        #expect(pair.request.sessionId == DemoApproval.sessionID)
        #expect(pair.request.display == "Bash: npm test")
        #expect(DemoApproval.isDemo(pair.request) && DemoApproval.isDemo(pair.session))
        // It never batches and never travels: no directory to run in.
        #expect(ApprovalBatch.key(pair.request, cwd: pair.session.cwd) == nil)
        #expect(!Handoff.canHandOff(pair.session))
        #expect(DropToAgent.refusal(for: pair.session) != nil)
    }

    @Test func itIsMergedInWhileItWaitsAndGoneAfter() {
        let demo = DemoApproval.shared
        var changes = 0
        var ended = ""
        demo.onChange = { changes += 1 }
        demo.onFinish = { ended = $0 }
        defer { demo.onChange = {}; demo.onFinish = { _ in } }
        demo.start()
        #expect(demo.isActive)
        #expect(demo.merged([Session]()).count == 1)
        #expect(demo.merged([ApprovalRequest]()).count == 1)
        demo.start()                                  // a second press adds nothing
        #expect(demo.merged([ApprovalRequest]()).count == 1)
        demo.finish("deny")
        #expect(!demo.isActive && ended == "deny")
        #expect(demo.merged([Session]()).isEmpty)
        #expect(changes == 2)
    }

    @Test func answeringItWritesNoAnswerFile() throws {
        let demo = DemoApproval.shared
        demo.start()
        defer { demo.finish("expired") }
        let r = try #require(demo.request), s = try #require(demo.session)
        let answer = RequestStore.answersDir.appendingPathComponent(r.fileName)
        #expect(AgentActions.answer(ApprovalAction(request: r, behavior: "allow", session: s)))
        #expect(!FileManager.default.fileExists(atPath: answer.path))
        #expect(!demo.isActive)
    }
}
