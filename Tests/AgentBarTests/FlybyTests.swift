import Foundation
import Testing
@testable import AgentBar

/// Crossed paths: two sessions on one file within minutes. Found, worded and
/// put on a live row — and nothing more than that.
@Suite struct FlybyTests {
    private func e(_ ts: TimeInterval, _ path: String, _ session: String, _ agent: String = "claude")
    -> Flyby.EditEvent {
        Flyby.EditEvent(ts: ts, path: path, session: session, agent: agent)
    }

    @Test func twoSessionsOnOneFileWithinTheWindowCross() {
        let c = Flyby.pairs(events: [
            e(1_000, "/r/Sources/Auth.swift", "a", "claude"),
            e(1_240, "/r/Sources/Auth.swift", "b", "codex"),
        ])
        #expect(c.count == 1)
        #expect(c.first?.gap == 240)
        #expect(c.first?.file == "Auth.swift")
        #expect(c.first?.sentence() == "Codex and Claude both edited Auth.swift, 4 min apart")
    }

    @Test func oneSessionOrAFarApartPairDoesNot() {
        #expect(Flyby.pairs(events: [e(0, "/r/a.swift", "a"), e(60, "/r/a.swift", "a")]).isEmpty)
        #expect(Flyby.pairs(events: [e(0, "/r/a.swift", "a"), e(601, "/r/a.swift", "b")]).isEmpty)
        #expect(Flyby.pairs(events: [e(0, "/r/a.swift", "a"), e(60, "/r/b.swift", "b")]).isEmpty)
    }

    /// However each writer spelled it, it is the same file on a Mac's disk.
    @Test func pathsAreComparedNormalised() {
        let c = Flyby.pairs(events: [e(0, "/r/src/../Auth.swift", "a"), e(30, "/R/auth.swift", "b", "codex")])
        #expect(c.count == 1)
        #expect(c.first?.sentence() == "Codex and Claude both edited Auth.swift, under a minute apart")
    }

    @Test func eachPairOfSessionsCountsOncePerFileAtItsClosest() {
        let c = Flyby.pairs(events: [e(0, "/r/a", "x"), e(300, "/r/a", "y", "codex"),
                                     e(400, "/r/a", "x"), e(420, "/r/a", "y", "codex")])
        #expect(c.count == 1)
        #expect(c.first?.gap == 20)
        #expect(Flyby.who("claude", "claude") == "Two Claude sessions")
    }

    /// Codex's edits come out of its rollout's `apply_patch` calls, relative paths
    /// resolved against the session's folder.
    @Test func codexEditsComeFromItsPatches() {
        let lines: [Substring] = [
            #"{"timestamp":"2026-10-07T10:00:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Update File: Sources/Auth.swift\n@@\n-a\n+b\n*** Add File: /abs/New.swift\n+x\n*** End Patch"}}"#,
            #"{"timestamp":"2026-10-07T10:05:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"text(await tools.apply_patch(\"*** Begin Patch\\n*** Delete File: old.txt\\n*** End Patch\"))"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Update File: no-time.swift"}}"#,
        ]
        let edits = CodexFeed.edits(lines, cwd: "/repo")
        #expect(edits.map(\.path) == ["/repo/Sources/Auth.swift", "/abs/New.swift", "/repo/old.txt"])
        #expect(edits.first?.ts == 1_791_367_200)
    }

    // MARK: - Live

    private func session(_ id: String, agent: String, edits: [[String: Any]]) throws -> Session {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flyby-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("\(id).json")
        let o: [String: Any] = ["agent": agent, "state": "tool", "ts": 5_000, "edits": edits]
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        return try #require(Session(fileURL: url))
    }

    /// The ring is anybody's to write: only absolute paths with a real time.
    @Test func theEditsRingIsReadWithCare() throws {
        let s = try session("a", agent: "claude", edits: [
            ["path": "/r/a.swift", "ts": 4_000], ["path": "relative.swift", "ts": 4_000],
            ["path": "/r/b.swift", "ts": 1e300], ["path": "/r/\nc", "ts": 4_000], ["ts": 4_000],
        ])
        #expect(s.edits == [WorkSpans.Edit(ts: 4_000, path: "/r/a.swift")])
    }

    @Test func aLiveRowCarriesTheOtherSessionsEdit() throws {
        let a = try session("a", agent: "claude", edits: [["path": "/r/Auth.swift", "ts": 4_000]])
        let b = try session("b", agent: "codex", edits: [["path": "/r/Auth.swift", "ts": 4_180]])
        let c = try session("c", agent: "gemini", edits: [["path": "/r/Other.swift", "ts": 4_100]])
        let marked = Flyby.mark([a, b, c], now: 4_360)
        let byID = Dictionary(uniqueKeysWithValues: marked.map { ($0.id, $0) })
        #expect(byID["a"]?.crossedBy?.chip(now: 4_360) == "also edited by Codex · 3m")
        #expect(byID["b"]?.crossedBy?.agent == "Claude")
        #expect(byID["c"]?.crossedBy == nil)
        // Gone once the later edit is old news.
        #expect(Flyby.mark([a, b], now: 4_180 + Flyby.fresh + 1).allSatisfy { $0.crossedBy == nil })
    }

    @Test func twoSessionsOfOneAgentAreToldApart() throws {
        let a = try session("a", agent: "claude", edits: [["path": "/r/x.swift", "ts": 4_000]])
        let b = try session("b", agent: "claude", edits: [["path": "/r/x.swift", "ts": 4_030]])
        #expect(Flyby.live([a, b], now: 4_100)["a"]?.agent == "another Claude")
    }
}
