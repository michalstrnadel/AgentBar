import AppKit
import Testing
@testable import AgentBar

private func session(_ id: String, agent: String = "claude", state: String = "tool",
                     label: String = "Editing", extra: [String: Any] = [:]) throws -> Session {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(id).json")
    defer { try? FileManager.default.removeItem(at: url) }
    var o: [String: Any] = ["agent": agent, "state": state, "label": label, "started": true, "ts": 1_000,
                            "project": "proj-\(id)", "cwd": NSTemporaryDirectory(), "pid": 4242,
                            "sessionId": id, "term_program": "iTerm.app"]
    o.merge(extra) { $1 }
    try JSONSerialization.data(withJSONObject: o).write(to: url)
    return try #require(Session(fileURL: url))
}

/// The office: who sits where, what each one is seen doing, where a click on a
/// desk leads, and when the room steps aside for work.
@Suite struct OfficeLayoutTests {
    @Test func desksFillTwoToARowFromTheTopLeftAndNeverOverlap() throws {
        let sessions = try (0..<8).map { try session("s\($0)") }
        let layout = Office.layout(sessions, now: 1_000)
        #expect(layout.desks.map(\.sessionID) == sessions.map(\.id))
        let rects = layout.desks.map(\.rect)
        let room = CGRect(origin: .zero, size: Office.size)
        for (i, r) in rects.enumerated() {
            #expect(room.contains(r))
            #expect(r.maxY <= Office.size.height - Office.wallHeight)
            #expect(r.minY >= Office.footerHeight)
            for other in rects[(i + 1)...] { #expect(!r.intersects(other)) }
        }
        #expect(rects[0].minX < rects[1].minX && rects[0].minY == rects[1].minY)
        #expect(rects[2].minY < rects[0].minY)
        #expect(rects[0].maxY == Office.size.height - Office.wallHeight)
    }

    @Test func pastEightDesksTheRestAreACount() throws {
        let sessions = try (0..<11).map { try session("s\($0)") }
        let layout = Office.layout(sessions, now: 1_000)
        #expect(layout.desks.count == Office.maxDesks)
        #expect(layout.overflow == 3)
        #expect(Office.layout(Array(sessions.prefix(3)), now: 1_000).overflow == 0)
    }

    @Test func waitingRaisesTheHandAndAFinishedTurnSleeps() throws {
        let asks = try session("a", state: "permission", label: "Bash: git push")
        let question = try session("q", state: "question", label: "")
        let done = try session("d", state: "done", label: "")
        let working = try session("w", state: "tool", label: "Reading")
        let unknownTool = try session("u", state: "tool", label: "Fiddling")
        let desks = Office.layout([asks, question, done, working, unknownTool], now: 1_000).desks
        #expect(desks[0].scene == .approve && desks[0].handRaised)
        #expect(desks[1].scene == .ask && desks[1].handRaised)
        #expect(desks[2].scene == .sleep && !desks[2].handRaised)
        #expect(desks[3].scene == .read)
        // At a desk, nothing more specific is typing — not the walk.
        #expect(desks[4].scene == .type)
    }

    @Test func aRaisedHandLeadsToTheRequestNeverToTheTerminal() throws {
        let asks = try session("a", state: "permission")
        let working = try session("w")
        let desks = Office.layout([asks, working], now: 1_000).desks
        #expect(Office.target(for: desks[0]) == .showRequest(sessionID: "a"))
        #expect(Office.target(for: desks[1]) == .focus(sessionID: "w"))
        let hit = Office.desk(at: CGPoint(x: desks[0].rect.midX, y: desks[0].rect.midY),
                              in: Office.layout([asks, working], now: 1_000))
        #expect(hit?.sessionID == "a")
    }

    @Test func helpersAreCountedAtTheDesk() throws {
        let s = try session("h", extra: ["subagentRuns": [["type": "Explore"], ["type": "Plan"], ["type": "code-reviewer"]]])
        #expect(Office.layout([s], now: 1_000).desks[0].subagents == s.subagentCount)
    }

    @Test func aHandGoingUpAtADeskDoesNotStepTheOfficeAside() {
        let seated: Set<String> = ["a", "b"]
        let files = ["a.json": "a", "c.json": "c"]
        // Session a, at a desk, starts waiting and writes its request: the hand is the signal.
        #expect(!Office.yields(before: [], now: ["ses:a", "req:a.json"], seated: seated, requestSessions: files))
        // Session c has no desk: it steps the office aside, as it would a game.
        #expect(Office.yields(before: [], now: ["ses:c"], seated: seated, requestSessions: files))
        #expect(Office.yields(before: [], now: ["req:c.json"], seated: seated, requestSessions: files))
        // A request nobody can place is treated as new work.
        #expect(Office.yields(before: [], now: ["req:x.json"], seated: seated, requestSessions: files))
        // What was already waiting when it opened never does.
        #expect(!Office.yields(before: ["ses:c"], now: ["ses:c"], seated: seated, requestSessions: files))
        // The games are unchanged: anything new steps them aside.
        #expect(BreakGame.yields(before: [], now: ["ses:a"]))
    }

    @Test func theOfficeIsABreakWithoutAScore() {
        #expect(!GameChoice.office.isGame)
        #expect(GameChoice.office.backTitle(score: 1234) == "Back to the office")
        #expect(GameChoice.spaceBugs.backTitle(score: 1234).contains("1 234"))
        #expect(!IslandController.gameOrder.contains(.office))
    }

    @Test @MainActor func theViewListsItsDesksAloud() throws {
        let v = OfficeView()
        v.update(sessions: [try session("a", state: "permission"), try session("b", agent: "codex")],
                 requests: [], now: 1_000)
        let label = v.accessibilityLabel() ?? ""
        #expect(label.contains("2 desks"))
        #expect(label.contains("proj-a") && label.contains("waits on you"))
        #expect(label.contains("Codex"))
        #expect(v.score == 0)
        #expect(v.seated == ["a", "b"])
    }
}
