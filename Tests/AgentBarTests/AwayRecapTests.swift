import Foundation
import Testing
@testable import AgentBar

/// Said once, on coming back, about the whole span away — and only when
/// something happened in it.
@Suite struct AwayRecapTests {
    @Test func comingBackShowsWhatHappenedSinceTheInputStopped() {
        let w = AwayWatch()
        var asked: TimeInterval?
        let make: (TimeInterval) -> AwayRecap = { since in
            asked = since
            return AwayRecap(since: since, done: 3, waiting: 1)
        }
        #expect(!w.tick(idle: 60, now: 1_000, make: make))
        #expect(!w.tick(idle: 200, now: 1_140, make: make))   // away since 940
        #expect(w.tick(idle: 1, now: 2_000, make: make))
        #expect(asked == 940)
        #expect(w.current?.pill == "away · 1 waiting · 3 done")
    }

    @Test func nothingHappenedSaysNothing() {
        let w = AwayWatch()
        _ = w.tick(idle: 300, now: 1_000) { AwayRecap(since: $0) }
        #expect(!w.tick(idle: 0, now: 1_100) { AwayRecap(since: $0) })
        #expect(w.current == nil)
    }

    @Test func itGoesAfterAMinuteAndAHalfOrOnceSeen() {
        let w = AwayWatch()
        _ = w.tick(idle: 300, now: 1_000) { AwayRecap(since: $0, done: 1) }
        _ = w.tick(idle: 0, now: 1_100) { AwayRecap(since: $0, done: 1) }
        #expect(w.current != nil)
        #expect(w.tick(idle: 3, now: 1_100 + AwayWatch.showFor + 1) { AwayRecap(since: $0) })
        #expect(w.current == nil)
    }

    @Test func theSentenceSaysAllOfIt() {
        let r = AwayRecap(since: 0, done: 2, failed: 1, waiting: 1, longestWait: 300, byRules: 4)
        #expect(r.sentence(until: 1_800)
                == "While you were away (30 min): 2 finished, 1 failed, 1 waiting on you, the longest 5 min, your rules answered 4.")
    }

    // MARK: - A failure, in one clause

    private func session(_ id: String, agent: String = "claude", state: String,
                         project: String = "agentbar", ts: TimeInterval) -> Session {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("away-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("\(id).json")
        try? Data(#"{"agent":"\#(agent)","state":"\#(state)","project":"\#(project)","ts":\#(ts)}"#.utf8).write(to: url)
        return Session(fileURL: url)!
    }

    private func failedBash(_ command: String) -> LiveFeed.Feed {
        LiveFeed.Feed(items: [.tool("Read", "a.swift"), .tool("Bash", command)],
                      output: LiveFeed.Output(lines: ["error"], isError: true, after: 1))
    }

    @Test func aFailedTestRunIsNamedAsTests() {
        let s = session("a", state: "done", ts: 1_500)
        let f = AwayFailure.from([s], since: 1_000, until: 2_000) { _ in self.failedBash("swift test --filter X") }
        let r = AwayRecap(since: 1_000, done: 1, failure: AwayFailure.clause(f, since: 1_000, until: 2_000))
        #expect(r.pill == "away · 1 done · tests failed in agentbar")
        #expect(r.sentence(until: 2_200) == "While you were away (20 min): 1 finished, tests failed in agentbar.")
    }

    @Test func anyOtherCommandClaimsNoMoreThanACommand() {
        #expect(AwayFailure.clause([AwayFailure(project: "web", command: "npm run build", at: 5)], since: 0, until: 10)
                == "a command failed in web")
        // "test" has to be a word: a file called latest.txt is not a test run.
        #expect(!AwayFailure.isTestRun("cat latest.txt"))
        #expect(AwayFailure.isTestRun("./Scripts/test/cli-test.sh"))
        #expect(AwayFailure.isTestRun("python -m pytest -q"))
    }

    @Test func anErroredSessionCountsAndAFailureAloneIsWorthSaying() {
        let s = session("e", agent: "gemini", state: "error", project: "api", ts: 1_500)
        let f = AwayFailure.from([s], since: 1_000, until: 2_000) { _ in LiveFeed.Feed(items: []) }
        let r = AwayRecap(since: 1_000, failure: AwayFailure.clause(f, since: 1_000, until: 2_000))
        #expect(!r.isEmpty)
        #expect(r.pill == "away · an error in api")
    }

    @Test func onlyWhatHappenedWhileAwayAndNotWhileStillWorking() {
        let before = session("b", state: "done", ts: 900)        // wrote before leaving
        let working = session("w", state: "tool", ts: 1_500)     // still on it
        let passed = session("p", state: "done", ts: 1_500)      // newest command passed
        let feeds: [String: LiveFeed.Feed] = [
            "b": failedBash("swift test"), "w": failedBash("swift test"),
            "p": LiveFeed.Feed(items: [.tool("Bash", "swift test")],
                               output: LiveFeed.Output(lines: ["ok"], isError: false, after: 0)),
        ]
        let f = AwayFailure.from([before, working, passed], since: 1_000, until: 2_000) { feeds[$0.id]! }
        #expect(f.isEmpty)
        #expect(AwayFailure.clause(f, since: 1_000, until: 2_000) == nil)
    }

    @Test func severalAreOneClauseNeverAList() {
        let all = [AwayFailure(project: "a", command: nil, at: 1_100),
                   AwayFailure(project: "b", command: "go test ./...", at: 1_800),
                   AwayFailure(project: "c", command: "make", at: 1_400)]
        #expect(AwayFailure.clause(all, since: 1_000, until: 2_000) == "tests failed in b +2 more")
    }
}
