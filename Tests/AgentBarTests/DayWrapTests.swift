import Foundation
import Testing
@testable import AgentBar

/// The recap's numbers. Every one is quotable, so every one is held to the same
/// rules as the Today digest: measured or absent, never guessed.
@Suite struct DayWrapTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Prague")!
        return c
    }

    /// 2026-10-07 at a given local hour:minute.
    private func at(_ h: Int, _ m: Int = 0, day: Int = 7) -> TimeInterval {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
            .timeIntervalSince1970
    }

    private func record(_ agent: String, _ project: String, from: TimeInterval, to: TimeInterval,
                        state: String = "done", prompt: String = "", change: String = "") -> HistoryStore.Record {
        let c = change.isEmpty ? "" : #","change":\#(change)"#
        let line = #"{"agent":"\#(agent)","sessionId":"\#(UUID().uuidString)","project":"\#(project)","cwd":"/r/\#(project)","prompt":"\#(prompt)","startedAt":\#(Int(from)),"endedAt":\#(Int(to)),"state":"\#(state)"\#(c)}"#
        return HistoryStore.Record(jsonLine: line)!
    }

    private func decision(_ ts: TimeInterval, waited: TimeInterval, via: String = "app") -> DecisionLedger.Record {
        var r = DecisionLedger.Record()
        r.ts = ts; r.waited = waited; r.via = via; r.decision = "allow"; r.shape = "bash:ls"
        return r
    }

    @Test func anEmptyDayIsEmpty() {
        let w = DayWrap.make(.today, history: [], ledger: [], now: at(18), calendar: calendar)
        #expect(w.isEmpty)
        #expect(w.longest == nil)
        #expect(w.persona.title == "The Builder")
    }

    @Test func timeIsSummedAndUnionedAndPeakIsFound() {
        let h = [
            record("claude", "AgentBar", from: at(9), to: at(11)),
            record("codex", "Site", from: at(10), to: at(10, 30)),
            record("copilot", "Site", from: at(10, 15), to: at(10, 45)),
            record("claude", "AgentBar", from: at(14), to: at(15)),
        ]
        let w = DayWrap.make(.today, history: h, ledger: [], now: at(18), calendar: calendar)
        #expect(w.sessions == 4)
        #expect(w.agentSeconds == 2 * 3600 + 1800 + 1800 + 3600)
        #expect(w.busySeconds == 3 * 3600)              // 9–11 and 14–15
        #expect(w.peak == 3)
        #expect(w.peakAt == at(10, 15))
        #expect(w.topAgent?.id == "claude")
        #expect(w.projects.first?.name == "AgentBar")
        #expect(w.bins.count == 24)
        #expect(w.bins[10] == 3600 + 1800 + 1800)
        #expect(w.binAgents[10] == "claude")
        #expect(w.persona.title == "The Orchestrator")
        #expect(w.persona.reason.contains("10:15"))
    }

    /// Yesterday's evening counts for the part of it that was today.
    @Test func aSessionThatStartedYesterdayIsClipped() {
        let h = [record("claude", "X", from: at(23, day: 6), to: at(1))]
        let w = DayWrap.make(.today, history: h, ledger: [], now: at(18), calendar: calendar)
        #expect(w.agentSeconds == 3600)
    }

    @Test func anUntimedSessionCountsButAddsNoTime() {
        var r = record("gemini", "X", from: at(9), to: at(10))
        r.startedAt = 0
        let w = DayWrap.make(.today, history: [r], ledger: [], now: at(18), calendar: calendar)
        #expect(w.sessions == 1)
        #expect(w.timed == 0)
        #expect(w.agentSeconds == 0)
        #expect(w.longest == nil)
    }

    @Test func linesComeOnlyFromMeasuredSessions() {
        let h = [
            record("claude", "A", from: at(9), to: at(10), change: #"{"files":3,"added":120,"removed":4}"#),
            record("claude", "A", from: at(11), to: at(12)),
        ]
        let w = DayWrap.make(.today, history: h, ledger: [], now: at(18), calendar: calendar)
        #expect(w.linesAdded == 120 && w.linesRemoved == 4 && w.filesChanged == 3)
        #expect(w.changeMeasured == 1)
    }

    @Test func yourAnswersAndYourRulesAreCountedApart() {
        let l = [decision(at(9), waited: 3), decision(at(10), waited: 20), decision(at(11), waited: 7),
                 decision(at(12), waited: 0, via: "rule"), decision(at(12), waited: 0, via: "claude"),
                 decision(at(9, day: 6), waited: 99)]
        let w = DayWrap.make(.today, history: [], ledger: l, now: at(18), calendar: calendar)
        #expect(w.waits.answered == 3)
        #expect(w.waits.waited == 30)
        #expect(w.waits.byRules == 1)
        #expect(w.waits.fastest == 3)
        #expect(w.waits.median == 7)
    }

    @Test func theLongestRunNamesItsTask() {
        let h = [record("claude", "A", from: at(8), to: at(10, 30), prompt: "refactor the ledger\\nand more"),
                 record("codex", "B", from: at(11), to: at(11, 10))]
        let w = DayWrap.make(.today, history: h, ledger: [], now: at(18), calendar: calendar)
        #expect(w.longest?.task == "refactor the ledger")
        #expect(w.longest?.seconds == 2.5 * 3600)
        #expect(w.persona.title == "The Marathoner")
    }

    @Test func aWeekHasSevenDaysAndABestOne() {
        let h = [record("claude", "A", from: at(9, day: 2), to: at(10, day: 2)),
                 record("claude", "A", from: at(9, day: 5), to: at(12, day: 5)),
                 record("claude", "A", from: at(9, day: 7), to: at(10, day: 7)),
                 record("claude", "A", from: at(9, day: 0), to: at(12, day: 0))]   // 30 Sep, outside
        let w = DayWrap.make(.week, history: h, ledger: [], now: at(18), calendar: calendar)
        #expect(w.bins.count == 7)
        #expect(w.sessions == 3)
        #expect(w.bestDay.map { $0.seconds } == 10_800)
        #expect(w.bestDay?.start == calendar.startOfDay(for: Date(timeIntervalSince1970: at(9, day: 5))).timeIntervalSince1970)
    }

    @Test func personasFollowTheTable() {
        let night = [record("claude", "A", from: at(22), to: at(23, 30))]
        #expect(DayWrap.make(.today, history: night, ledger: [], now: at(23, 45), calendar: calendar)
            .persona.title == "The Night Owl")
        let rules = (0..<6).map { decision(at(9, $0), waited: 0, via: "rule") } + [decision(at(10), waited: 4)]
        #expect(DayWrap.make(.today, history: [], ledger: rules, now: at(18), calendar: calendar)
            .persona.title == "The Delegator")
        let quick = (0..<5).map { decision(at(9, $0), waited: 4) }
        #expect(DayWrap.make(.today, history: [], ledger: quick, now: at(18), calendar: calendar)
            .persona.title == "The Quick Draw")
        let early = [record("claude", "A", from: at(6, 10), to: at(6, 40))]
        #expect(DayWrap.make(.today, history: early, ledger: [], now: at(18), calendar: calendar)
            .persona.title == "The Early Bird")
    }

    /// What goes on a public card says nothing about which repositories exist.
    @Test func shareSafeTakesTheNamesOut() {
        let h = [record("claude", "secret-client", from: at(8), to: at(10), prompt: "fix the billing bug")]
        let w = DayWrap.make(.today, history: h, ledger: [], now: at(18), calendar: calendar).shareSafe()
        #expect(w.projects.map(\.name) == ["Project A"])
        #expect(w.longest?.task == "")
        #expect(w.longest?.project == "a project")
        #expect(w.agentSeconds == 7200)
    }
}
