import Foundation
import Testing
@testable import AgentBar

/// The record that outlives `state.d`. Everything here goes through the real
/// `Session(fileURL:)` decoder rather than a hand-built value, so a change to the
/// state protocol shows up as a failing history test instead of silently writing
/// empty fields into a file nobody reads until a month later.
@Suite struct HistoryStoreTests {
    private let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentbar-history-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func session(_ id: String, agent: String = "codex", state: String,
                         started: Bool = true, ts: TimeInterval = 1_000,
                         startedAt: TimeInterval = 400, project: String = "AgentBar") throws -> Session {
        let url = dir.appendingPathComponent("\(id).json")
        let o: [String: Any] = ["agent": agent, "state": state, "started": started, "ts": ts,
                                "started_at": startedAt, "project": project, "label": "build",
                                "cwd": "/tmp/\(project)", "pid": 4242]
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        return try #require(Session(fileURL: url))
    }

    private func by(_ sessions: [Session]) -> [String: Session] {
        Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    }

    /// The CLI writes the same file and spells the field `agentName`, like the
    /// other history keys; the two sides drifting apart would lose the name of
    /// every third-party agent the moment the other frontend wrote a line.
    @Test func aGenericAgentsNameSurvivesTheHistoryLine() throws {
        let url = dir.appendingPathComponent("named.json")
        let o: [String: Any] = ["agent": "aider", "agent_name": "Aider", "state": "done",
                                "started": true, "ts": 1_000, "started_at": 400, "pid": 4242]
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        let s = try #require(Session(fileURL: url))
        let record = HistoryStore.Record(s, endedAt: 2_000)
        #expect(record.json["agentName"] as? String == "Aider")
        let line = try #require(String(data: JSONSerialization.data(withJSONObject: record.json),
                                       encoding: .utf8))
        let back = try #require(HistoryStore.Record(jsonLine: line))
        #expect(back.resolvedAgent.name == "Aider")
    }

    // MARK: - The edge

    @Test func aFinishedTurnIsRecordedOnce() throws {
        let working = try session("a", state: "thinking")
        let done = try session("a", state: "done")

        let first = HistoryStore.records(from: by([working]), to: [done], now: 2_000)
        #expect(first.count == 1)
        #expect(first.first?.state == "done")
        #expect(first.first?.agent == "codex")
        #expect(first.first?.project == "AgentBar")
        // `ts` is when the session last did something; "now" is when we noticed.
        #expect(first.first?.endedAt == 1_000)
        #expect(first.first?.startedAt == 400)

        // The row survives in `done` for hours before pruning reaches it. Writing it
        // on each of those ticks would fill the file with one session.
        #expect(HistoryStore.records(from: by([done]), to: [done], now: 3_000).isEmpty)
    }

    /// The only end signal several agents give: the file disappears. Nothing else
    /// marks the end of a Codex or Antigravity session.
    @Test func aSessionThatDisappearsIsRecorded() throws {
        let working = try session("a", state: "tool")
        let out = HistoryStore.records(from: by([working]), to: [], now: 2_000)
        #expect(out.count == 1)
        #expect(out.first?.sessionId == "a")
        #expect(out.first?.state == "tool")
    }

    /// `idle` is where a Claude session sits *between* turns — open and waiting.
    /// Counting it as an ending would write a record every time someone paused to
    /// read the output, and `Session.State.isFinished` includes it, so this is the
    /// one place that must not reuse that helper.
    @Test func idleIsNotAnEnding() throws {
        let working = try session("a", agent: "claude", state: "thinking")
        let idle = try session("a", agent: "claude", state: "idle")
        #expect(HistoryStore.records(from: by([working]), to: [idle], now: 2_000).isEmpty)
    }

    /// A session first seen when it is already over still counts: it ended, we just
    /// missed the middle. Relaunching AgentBar mid-turn is the common way in.
    @Test func aSessionFirstSeenFinishedIsStillRecorded() throws {
        let done = try session("a", state: "error")
        #expect(HistoryStore.records(from: [:], to: [done], now: 2_000).count == 1)
    }

    /// `started: false` means opened but never used — the protocol says frontends
    /// must hide those, and a digest counting them would inflate every day.
    @Test func sessionsThatNeverStartedAreNotRecorded() throws {
        let ghost = try session("ghost", state: "done", started: false)
        #expect(HistoryStore.records(from: [:], to: [ghost], now: 2_000).isEmpty)
        #expect(HistoryStore.records(from: by([ghost]), to: [], now: 2_000).isEmpty)
    }

    /// A watchdog-synthesized end is not the agent saying it finished, and the
    /// record has to carry that distinction or the digest quietly invents outcomes.
    @Test func aDecayedEndIsMarkedAsSuch() throws {
        var decayed = try session("a", agent: "antigravity", state: "done")
        decayed.decayed = true
        let out = HistoryStore.records(from: by([try session("a", state: "tool")]), to: [decayed], now: 2_000)
        #expect(out.first?.decayed == true)
    }

    @Test func severalEndingsInOneTickComeBackInAStableOrder() throws {
        let a = try session("a", state: "thinking", ts: 900)
        let b = try session("b", state: "thinking", ts: 800)
        let out = HistoryStore.records(from: by([a, b]), to: [], now: 2_000)
        #expect(out.map(\.sessionId) == ["b", "a"])
    }

    // MARK: - The file

    @Test func theFirstTickIsABaselineAndWritesNothing() throws {
        let url = dir.appendingPathComponent("first.jsonl")
        let store = HistoryStore(url: url)
        // A relaunch sees every live session at once; those did not just end.
        store.observe([try session("a", state: "done")])
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func recordsRoundTripThroughTheFile() throws {
        let url = dir.appendingPathComponent("rt.jsonl")
        let store = HistoryStore(url: url)
        store.enrich = { $0 }   // no git, no transcripts: see `measure`
        store.observe([try session("a", state: "thinking")])   // baseline
        store.observe([try session("a", state: "done")])
        // Records are measured and written on the store's own serial queue, so a
        // test has to wait for it. Nothing on a surface ever does.
        store.flush()

        let back = HistoryStore.read(url: url)
        #expect(back.count == 1)
        #expect(back.first?.sessionId == "a")
        #expect(back.first?.state == "done")
        #expect(back.first?.cwd == "/tmp/AgentBar")
    }

    /// The line carries when the session was working, not just how long it was
    /// open: two stretches of thinking, with a pause at the prompt between them.
    @Test func theLineCarriesTheStretchesItWasWorking() throws {
        let url = dir.appendingPathComponent("spans.jsonl")
        let store = HistoryStore(url: url)
        store.enrich = { $0 }
        store.observe([try session("a", state: "idle")], now: 1_000)       // baseline
        store.observe([try session("a", state: "thinking")], now: 1_100)
        store.observe([try session("a", state: "idle")], now: 1_400)
        store.observe([try session("a", state: "tool")], now: 2_000)
        store.observe([try session("a", state: "done")], now: 2_060)
        store.flush()
        let spans = try #require(HistoryStore.read(url: url).first?.spans)
        #expect(spans == [.init(start: 1_100, end: 1_400), .init(start: 2_000, end: 2_060)])
    }

    /// A session is written more than once — turn end, then disappearance. The
    /// reader has to collapse those to the newest, or a day's count double-counts.
    @Test func theLastLineForASessionWins() throws {
        let url = dir.appendingPathComponent("dup.jsonl")
        let store = HistoryStore(url: url)
        store.enrich = { $0 }
        store.observe([try session("a", state: "thinking")])          // baseline
        store.observe([try session("a", state: "done", ts: 1_000)])   // turn ended
        store.observe([])                                             // row disappeared
        store.flush()

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").count
        #expect(lines == 2, "both events should be appended")
        let back = HistoryStore.read(url: url)
        #expect(back.count == 1, "but they are one session")
        #expect(back.first?.state == "done")
    }

    /// A line torn by a crash mid-append must cost that line and nothing else.
    @Test func aTornLineIsSkippedRatherThanLosingTheFile() throws {
        let url = dir.appendingPathComponent("torn.jsonl")
        let good = #"{"agent":"codex","sessionId":"a","state":"done","endedAt":1000}"#
        try (good + "\n{\"agent\":\"codex\",\"sessi\n" + good.replacingOccurrences(of: "\"a\"", with: "\"b\"") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(HistoryStore.read(url: url).map(\.sessionId) == ["a", "b"])
    }

    @Test func pruneDropsWhatIsOlderThanTheWindowAndRewritesNothingOtherwise() throws {
        let url = dir.appendingPathComponent("prune.jsonl")
        let old = #"{"agent":"codex","sessionId":"old","state":"done","endedAt":1000}"#
        let new = #"{"agent":"codex","sessionId":"new","state":"done","endedAt":100000}"#
        try (old + "\n" + new + "\n").write(to: url, atomically: true, encoding: .utf8)

        let now: TimeInterval = 100_000 + HistoryStore.maxAge - 1
        HistoryStore.prune(url: url, now: now)
        #expect(HistoryStore.read(url: url).map(\.sessionId) == ["new"])

        // Nothing to drop: the file must be left exactly as it is, not rewritten.
        let before = try Data(contentsOf: url)
        HistoryStore.prune(url: url, now: now)
        #expect(try Data(contentsOf: url) == before)
    }

    /// A session written on every turn is many lines and one record. Counting
    /// records meant a file of nothing but repeats was never compacted.
    @Test func pruneCompactsRepeatsOfOneSession() throws {
        let url = dir.appendingPathComponent("repeats.jsonl")
        let line = { (s: String) in #"{"agent":"codex","sessionId":"a","state":"\#(s)","endedAt":100000}"# }
        try ([line("thinking"), line("tool"), line("done")].joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        HistoryStore.prune(url: url, now: 100_001)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 1)
        #expect(HistoryStore.read(url: url).first?.state == "done")
    }

    // MARK: - Weight and repo change

    /// Both are optional, and "absent" has to survive the round trip as `nil` rather
    /// than arriving as a zero somebody then quotes.
    @Test func whatWasNotMeasuredStaysAbsent() throws {
        let url = dir.appendingPathComponent("bare.jsonl")
        let store = HistoryStore(url: url)
        store.enrich = { $0 }
        store.observe([try session("a", state: "thinking")])
        store.observe([try session("a", state: "done")])
        store.flush()

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("weight"))
        #expect(!text.contains("change"))
        let back = try #require(HistoryStore.read(url: url).first)
        #expect(back.weight == nil)
        #expect(back.change == nil)
    }

    @Test func weightAndChangeRoundTripThroughTheFile() throws {
        let url = dir.appendingPathComponent("weighted.jsonl")
        let store = HistoryStore(url: url)
        store.enrich = { r in
            var out = r
            out.weight = Weight(input: 1_330, output: 622_024, cacheWrite: 1_453_897,
                                cacheRead: 220_795_232, source: "claude-transcript")
            out.change = RepoChange(files: 7, added: 210, removed: 80, base: "3a30264")
            return out
        }
        store.observe([try session("a", state: "thinking")])
        store.observe([try session("a", state: "done")])
        store.flush()

        let back = try #require(HistoryStore.read(url: url).first)
        #expect(back.weight?.input == 1_330)
        #expect(back.weight?.cacheRead == 220_795_232)
        #expect(back.weight?.source == "claude-transcript")
        // Cache reads are excluded from the number a person is shown.
        #expect(back.weight?.total == 2_077_251)
        #expect(back.change == RepoChange(files: 7, added: 210, removed: 80, base: "3a30264"))
    }

    /// Records supersede each other by session id, so a later one that could not be
    /// measured must not quietly erase a number an earlier one had. It does erase it —
    /// last line wins is the protocol — which is only safe because every reader takes
    /// the running total, not a delta. Pinned here so the rule stays deliberate.
    @Test func theNewestRecordIsTheOneThatCounts() throws {
        let url = dir.appendingPathComponent("supersede.jsonl")
        let withWeight = #"{"agent":"claude","sessionId":"a","state":"done","endedAt":1000,"weight":{"in":10,"out":20,"cacheWrite":0,"cacheRead":0,"src":"claude-transcript"}}"#
        let later = #"{"agent":"claude","sessionId":"a","state":"done","endedAt":2000,"weight":{"in":30,"out":40,"cacheWrite":0,"cacheRead":0,"src":"claude-transcript"}}"#
        try (withWeight + "\n" + later + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(HistoryStore.read(url: url).first?.weight?.total == 70)
    }

    /// The island footer reads this about once a second while an agent works.
    @Test func theCacheReReadsOnlyWhenTheFileMoves() throws {
        let url = dir.appendingPathComponent("cached.jsonl")
        let one = #"{"agent":"codex","sessionId":"a","state":"done","endedAt":1000}"#
        try (one + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(HistoryStore.cached(url: url).count == 1)

        let two = #"{"agent":"codex","sessionId":"b","state":"done","endedAt":2000}"#
        try (one + "\n" + two + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(HistoryStore.cached(url: url).count == 2)
    }
}
