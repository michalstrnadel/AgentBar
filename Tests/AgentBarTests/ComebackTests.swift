import Foundation
import Testing
@testable import AgentBar

/// The comeback, and the signals it is read from: a failure streak, a red or green
/// test run, a comeback, the files edited (`fails`, `tests`, `comeback`, `edits`).
struct ComebackTests {
    private func session(_ row: [String: Any]) throws -> Session {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("comeback-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var o: [String: Any] = ["agent": "claude", "state": "tool", "label": "Running command", "ts": 1_000]
        o.merge(row) { $1 }
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        return try #require(Session(fileURL: url))
    }

    @Test func aComebackFiresOnceWhenItMovesForward() {
        var c = Comeback()
        let fired = [
            c.observe([.init(id: "a", at: 990)], now: 1_000),   // first sight: history
            c.observe([.init(id: "a", at: 990)], now: 1_001),
            c.observe([.init(id: "a", at: 1_002)], now: 1_003), // moved forward: news
            c.observe([.init(id: "a", at: 1_002)], now: 1_004),
            // One that reaches the app long after it happened is let pass.
            c.observe([.init(id: "a", at: 1_010)], now: 1_010 + Comeback.fresh),
            // A session with none never fires.
            c.observe([.init(id: "b", at: 0)], now: 2_000),
            c.observe([.init(id: "b", at: 0)], now: 2_001),
        ]
        #expect(fired == [[], [], ["a"], [], [], [], []])
    }

    @Test func aGoneSessionStartsOverAsHistory() {
        var c = Comeback()
        _ = c.observe([.init(id: "a", at: 0)], now: 1_000)
        _ = c.observe([], now: 1_001)
        let again = c.observe([.init(id: "a", at: 1_002)], now: 1_003)
        #expect(again.isEmpty)
    }

    /// The finish sparkle's throttle, shared: once per session per quarter hour,
    /// never twice inside 20 s.
    @Test func itAsksTheSameThrottleAsTheSparkle() {
        typealias C = MascotPersonality.Celebrations
        var c = C()
        let answers = [c.allow("a", now: 100),
                       c.allow("a", now: 100 + C.perSession - 1),
                       c.allow("b", now: 110),
                       c.allow("b", now: 100 + C.anySession),
                       c.allow("a", now: 100 + C.perSession)]
        #expect(answers == [true, false, false, true, true])
    }

    @Test func aRowCarriesItsSignals() throws {
        let s = try session([
            "fails": ["streak": 3, "at": 995], "tests": ["last": "red", "ts": 990], "comeback": 980,
            "edits": [["path": "/p/a.swift", "ts": 970], ["path": "relative", "ts": 971], ["ts": 3]],
        ])
        #expect(s.signals.fails == .init(streak: 3, at: 995))
        #expect(s.signals.testsRed == true)
        #expect(s.signals.comeback == 980)
        #expect(s.signals.edits == [.init(path: "/p/a.swift", ts: 970)])
        let none = try session([:])
        #expect(none.signals == SessionSignals())
        let junk = try session(["fails": ["streak": "3"], "tests": ["last": "blue"], "comeback": "x"])
        #expect(junk.signals == SessionSignals())
    }

    @Test func threeFailuresInARowMakeHimSweatForAWhile() throws {
        let s = try session(["fails": ["streak": 3, "at": 1_000]])
        #expect(ClawdScene.scene(for: s, now: 1_010) == .sweat)
        #expect(ClawdScene.scene(for: s, now: 1_000 + SessionSignals.sweatFor) == .hammer)
        #expect(ClawdScene.scene(for: try session(["fails": ["streak": 2, "at": 1_000]]), now: 1_010) == .hammer)
        // Only while working: a session waiting or done is not struggling with anything.
        let done = try session(["state": "done", "fails": ["streak": 5, "at": 1_000]])
        #expect(ClawdScene.scene(for: done, now: 1_010) == .walk)
    }

    @Test func testsHaveTheirOwnScene() throws {
        #expect(ClawdScene.scene(forTool: "Running tests") == .test)
        let after = try session(["state": "thinking", "label": "Thinking…", "activity": ["Running tests"]])
        #expect(ClawdScene.scene(for: after, now: 1_002) == .test)
    }

    /// A failed call is Claude Code's PostToolUseFailure, on the "post" verb — and
    /// wired only for a build known to fire it.
    @Test func postToolUseFailureIsWiredOnlyForAClaudeCodeThatKnowsIt() throws {
        let e = try #require(HookWiring.claude.first { $0.event == "PostToolUseFailure" })
        #expect(e.script == "claude/update.js" && e.arg == "post" && e.matcher)
        #expect(HookWiring.wires(e, version: "2.1.119"))
        #expect(HookWiring.wires(e, version: "2.1.312"))
        #expect(!HookWiring.wires(e, version: "2.1.118"))
        #expect(!HookWiring.wires(e, version: nil))
    }
}
