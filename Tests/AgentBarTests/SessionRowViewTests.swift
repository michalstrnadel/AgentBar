import Foundation
import Testing
@testable import AgentBar

/// What a menu row says and how it spends its width, without a menu: the view's
/// words and layout are static functions for exactly this reason.
@Suite struct SessionRowViewTests {
    private let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentbar-rowview-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func session(_ state: String, agent: String = "claude", project: String = "myapp",
                         label: String = "", recap: String = "", startedAgo: TimeInterval? = 600) throws -> Session {
        let url = dir.appendingPathComponent("\(UUID().uuidString).json")
        var o: [String: Any] = ["agent": agent, "state": state, "label": label, "project": project,
                                "recap": recap, "started": true, "pid": 4242,
                                "ts": Date().timeIntervalSince1970]
        if let startedAgo { o["started_at"] = Date().timeIntervalSince1970 - startedAgo }
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        return try #require(Session(fileURL: url))
    }

    @Test func eachStateGetsItsDotAndItsWords() throws {
        let cases: [(String, String, SessionRowView.Dot, String)] = [
            ("permission", "Bash: git push", .waiting, "needs approval"),
            ("question", "❓ Which?", .asking, "❓ Which?"),
            ("thinking", "Thinking…", .working, "Thinking…"),
            ("tool", "Running command", .working, "Running command"),
            ("error", "quota exceeded", .failed, "failed — quota exceeded"),
            ("error", "", .failed, "failed"),
            ("done", "", .quiet, ""),
        ]
        for (state, label, dot, detail) in cases {
            let c = SessionRowView.content(for: try session(state, label: label))
            #expect(c.dot == dot, "\(state)")
            #expect(c.detail == detail, "\(state)")
        }
    }

    @Test func aFinishedRowSaysWhatFinishedCutAtSixty() throws {
        let recap = String(repeating: "word ", count: 30)
        let c = SessionRowView.content(for: try session("done", recap: recap))
        #expect(c.detail == String(recap.prefix(60)) + "…")
        let short = SessionRowView.content(for: try session("done", recap: "Shipped."))
        #expect(short.detail == "Shipped.")
    }

    @Test func anEndedRowIsDimmedAndTimeless() throws {
        let c = SessionRowView.content(for: try session("thinking", label: "Thinking…"), ended: true)
        #expect(c.dot == .ended)
        #expect(c.detail == "ended")
        #expect(c.elapsed.isEmpty)
        #expect(c.agent == "CLAUDE")
    }

    @Test func theAgentTagAndTimeRideAlong() throws {
        let c = SessionRowView.content(for: try session("thinking", agent: "codex", label: "Thinking…"))
        #expect(c.agent == "CODEX")
        #expect(c.agentID == "codex")
        #expect(c.elapsed == "10m")
        let untimed = SessionRowView.content(for: try session("thinking", startedAgo: nil))
        #expect(untimed.elapsed.isEmpty)
        #expect(SessionRowView.content(for: try session("idle", project: "")).name == "session")
    }

    @Test func thePlainTitleSkipsWhatIsEmpty() {
        let c = SessionRowView.Content(dot: .quiet, name: "api", detail: "", elapsed: "3m",
                                       agent: "CODEX", agentID: "codex")
        #expect(SessionRowView.plainTitle(c) == "api, 3m, CODEX")
    }

    @Test func theWidthStaysWithinItsBounds() {
        let tiny = SessionRowView.Content(dot: .quiet, name: "a", detail: "", elapsed: "", agent: "X", agentID: "claude")
        #expect(SessionRowView.idealWidth(tiny) == SessionRowView.minWidth)
        let huge = SessionRowView.Content(dot: .working, name: String(repeating: "n", count: 200),
                                          detail: String(repeating: "d", count: 200), elapsed: "2h",
                                          agent: "CLAUDE", agentID: "claude")
        #expect(SessionRowView.idealWidth(huge) == SessionRowView.maxWidth)
    }

    @Test func aLongDetailGivesWayBeforeTheName() {
        let c = SessionRowView.Content(dot: .quiet, name: "AgentBar · main",
                                       detail: String(repeating: "recap ", count: 40), elapsed: "1h",
                                       agent: "CLAUDE", agentID: "claude")
        let width: CGFloat = 400
        let lay = SessionRowView.textLayout(c, width: width)
        #expect(lay.name == SessionRowView.textWidth(c.name, SessionRowView.nameFont))
        #expect(lay.detail > 0)
        let textX = SessionRowView.textX(markWidth: SessionRowView.defaultMarkWidth)
        let right = SessionRowView.elapsedColumn + SessionRowView.gap + SessionRowView.agentColumn
            + SessionRowView.rightPad
        #expect(textX + lay.name + SessionRowView.gap + lay.detail <= width - right - SessionRowView.gap * 2 + 0.5)
    }

    @Test func noRoomLeftDropsTheDetailRatherThanAnInch() {
        let c = SessionRowView.Content(dot: .quiet, name: String(repeating: "n", count: 80),
                                       detail: "needs approval", elapsed: "", agent: "CLAUDE", agentID: "claude")
        let lay = SessionRowView.textLayout(c, width: 300)
        #expect(lay.detail == 0)
        #expect(lay.name > 0)
    }

    /// A row from an agent AgentBar ships nothing for is labelled with that
    /// agent, not with Claude — the bug was a crab and "CLAUDE" on an aider row.
    @Test func anUnknownAgentIsLabelledAsItself() throws {
        let c = SessionRowView.content(for: try session("thinking", agent: "aider"))
        #expect(c.agent == "AIDER")
        #expect(c.agentID == "aider")

        let url = dir.appendingPathComponent("\(UUID().uuidString).json")
        let o: [String: Any] = ["agent": "my-bot", "agent_name": "Robo Helper", "state": "thinking",
                                "started": true, "pid": 4242, "ts": Date().timeIntervalSince1970]
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        let named = SessionRowView.content(for: try #require(Session(fileURL: url)))
        #expect(named.agent == "ROBO HELPER")
    }
}
