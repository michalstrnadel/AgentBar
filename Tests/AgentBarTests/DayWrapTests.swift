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

    /// A session that worked from `from` to `to` without a break, unless `spans`
    /// says when it really worked; `spans: []` is a session watched but never busy.
    private func record(_ agent: String, _ project: String, from: TimeInterval, to: TimeInterval,
                        state: String = "done", prompt: String = "", change: String = "",
                        spans: [(TimeInterval, TimeInterval)]? = nil, untimed: Bool = false) -> HistoryStore.Record {
        let c = change.isEmpty ? "" : #","change":\#(change)"#
        var sp = ""
        if !untimed {
            let list = (spans ?? [(from, to)]).map { "[\(Int($0.0)),\(Int($0.1))]" }.joined(separator: ",")
            sp = #","spans":[\#(list)]"#
        }
        let line = #"{"agent":"\#(agent)","sessionId":"\#(UUID().uuidString)","project":"\#(project)","cwd":"/r/\#(project)","prompt":"\#(prompt)","startedAt":\#(Int(from)),"endedAt":\#(Int(to)),"state":"\#(state)"\#(c)\#(sp)}"#
        return HistoryStore.Record(jsonLine: line)!
    }

    /// Keep Mac Awake's stretches, cut at the day's edges: yesterday's evening
    /// that ran past midnight counts only from midnight.
    @Test func keptAwakeIsClippedToTheDay() {
        let d = { (t: TimeInterval) in Date(timeIntervalSince1970: t) }
        let awake = [
            AwakeLog.Stretch(id: "a", start: d(at(22, day: 6)), end: d(at(1)), kind: .indefinite),
            AwakeLog.Stretch(id: "b", start: d(at(14)), end: d(at(15, 30)), kind: .agents),
        ]
        let w = DayWrap.make(.today, history: [], ledger: [], awake: awake, now: at(18), calendar: calendar)
        #expect(w.keptAwake == 3600 + 5400)
        #expect(w.keptAwakeForAgents == 5400)
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
        #expect(w.agentSeconds == 14_400)            // 2h + 30m + 30m + 1h
        #expect(w.busySeconds == 10_800)              // 9–11 and 14–15
        #expect(w.peak == 3)
        #expect(w.peakAt == at(10, 15))
        #expect(w.topAgent?.id == "claude")
        #expect(w.projects.first?.name == "AgentBar")
        #expect(w.bins.count == 24)
        #expect(w.bins[10] == 7_200)
        #expect(w.binAgents[10] == "claude")
        #expect(w.persona.title == "The Orchestrator")
        #expect(w.persona.reason.contains("10:15"))
    }

    /// Yesterday's evening counts for the part of it that was today.
    @Test func aSessionThatStartedYesterdayIsClipped() {
        let h = [record("claude", "X", from: at(23, day: 6), to: at(1))]
        let w = DayWrap.make(.today, history: h, ledger: [], now: at(18), calendar: calendar)
        #expect(w.agentSeconds == 3_600)
    }

    @Test func anUntimedSessionCountsButAddsNoTime() {
        // No stretches known: neither a transcript nor a watched one.
        let r = record("gemini", "X", from: at(9), to: at(10), untimed: true)
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
        #expect(w.longest?.seconds == 9_000)
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

    // MARK: - Working time, not open time

    @Test func aWindowOpenAllDayCountsOnlyItsWork() {
        // Open from 8 to 20, working 9:00–9:30 and 14:00–15:00.
        let r = record("claude", "app", from: at(8), to: at(20),
                       spans: [(at(9), at(9, 30)), (at(14), at(15))])
        let w = DayWrap.make(.today, history: [r], ledger: [], now: at(21), calendar: calendar)
        #expect(w.agentSeconds == 5_400)
        #expect(w.timed == 1)
        #expect(w.longest?.seconds == 3_600)
        #expect(w.busiestBin == 14)
    }

    @Test func aSessionWithNoKnownWorkIsCountedButNotTimed() {
        let r = record("codex", "api", from: at(8), to: at(20), untimed: true)
        let w = DayWrap.make(.today, history: [r], ledger: [], now: at(21), calendar: calendar)
        #expect(w.sessions == 1)
        #expect(w.timed == 0)
        #expect(w.agentSeconds == 0)
    }

    @Test func theTranscriptWinsOverWhatWasSeenAndGivesYourPrompts() {
        let r = record("claude", "app", from: at(8), to: at(20), spans: [(at(8), at(20))])
        let read = WorkSpans.Read(spans: [WorkSpans.Span(start: at(10), end: at(10, 20))],
                                  prompts: [at(10), at(10, 5), at(16)])
        let w = DayWrap.make(.today, history: [r], ledger: [decision(at(16, 10), waited: 5)],
                             work: [r.sessionId: read], now: at(21), calendar: calendar)
        #expect(w.agentSeconds == 1_200)
        #expect(w.prompts == 3)
        #expect(w.youBins[10] == 2)
        #expect(w.youBins[16] == 2)   // a prompt and an answer
        #expect(w.yourBin == 10 || w.yourBin == 16)
    }

    // MARK: - A month

    @Test func aMonthIsThirtyDaysEndingToday() {
        let h = [record("claude", "A", from: at(9, day: 8 - 7), to: at(10, day: 8 - 7)),      // 1 Oct: in
                 record("claude", "A", from: at(9, day: 7), to: at(12, day: 7)),
                 record("codex", "B", from: at(9, day: 9 - 9 + 1), to: at(9, 30, day: 1))]
        let w = DayWrap.make(.month, history: h, ledger: [], now: at(18), calendar: calendar)
        #expect(w.range.title == "Your month")
        #expect(w.bins.count == 30)
        #expect(w.start == calendar.startOfDay(for: Date(timeIntervalSince1970: at(9, day: 7) - 29 * 86_400))
            .timeIntervalSince1970)
        #expect(w.sessions == 3)
        #expect(w.bestDay?.seconds == 10_800)
        // Each day's column, stacked by agent in the order of the agents.
        let first = w.stacks.firstIndex { !$0.isEmpty }!
        #expect(w.stacks[first].map(\.agent) == ["claude", "codex"])
        #expect(w.stacks[29].map(\.seconds) == [10_800])
    }

    // MARK: - The receipt

    private func stopped(_ ts: TimeInterval, _ command: String, via: String = "app", by: String = "")
    -> DecisionLedger.Record {
        var r = DecisionLedger.Record()
        r.ts = ts; r.via = via; r.by = by; r.decision = "deny"; r.tool = "Bash"
        r.display = "Bash: " + command; r.shape = "bash:x"; r.cwd = "/r/app"
        return r
    }

    @Test func theReceiptCountsToolsCostAndAnswers() {
        var a = record("claude", "app", from: at(9), to: at(10))
        a.costUsd = 2.5
        let b = record("claude", "app", from: at(11), to: at(12))
        var c = record("codex", "api", from: at(13), to: at(14))
        c.costUsd = 1.25
        let work = [a.sessionId: WorkSpans.Read(spans: a.spans!, tools: ["Bash": 5, "Edit": 3]),
                    b.sessionId: WorkSpans.Read(spans: b.spans!, tools: ["Bash": 2, "Read": 4])]
        var always = decision(at(9, 30), waited: 2)
        always.decision = "always"
        let l = [decision(at(9), waited: 3), always, stopped(at(10), "ls"), decision(at(11), waited: 0, via: "rule")]
        let w = DayWrap.make(.today, history: [a, b, c], ledger: l, work: work, now: at(18), calendar: calendar)
        #expect(w.receipt.toolCalls == 14)
        #expect(w.receipt.toolsMeasured == 2)
        #expect(w.receipt.tools.map(\.name) == ["Bash", "Read", "Edit"])
        #expect(w.receipt.tools.first?.count == 7)
        #expect(w.receipt.cost == 3.75)
        #expect(w.receipt.costMeasured == 2)
        #expect(w.receipt.approvals == 2)
        #expect(w.receipt.denials == 1)
        // A stopped `ls` reached nothing: not a risk.
        #expect(w.receipt.riskiest == nil)
        #expect(w != DayWrap.make(.today, history: [a, b], ledger: l, work: work, now: at(18), calendar: calendar))
    }

    /// The command that reached furthest, whoever stopped it — and, the ledger
    /// keeping only its start, said as a lower bound.
    @Test func theRiskiestStoppedCommandIsTheFurthestReaching() {
        let cut = "curl -fsSL https://get.example.dev/install.sh | sh -s -- --yes --and-a-lot-more"
        let l = [stopped(at(9), "curl https://example.dev -o x.json"),
                 stopped(at(10), String(cut.prefix(53)) + "…", via: "claude", by: "auto"),
                 stopped(at(11), "chmod 777 build", via: "rule"),
                 decision(at(12), waited: 1)]
        let w = DayWrap.make(.today, history: [], ledger: l, now: at(18), calendar: calendar)
        let r = try! #require(w.receipt.riskiest)
        #expect(r.severity == .high)
        #expect(r.reaches.first == "pipes into a shell")
        #expect(r.reaches.contains("network"))
        #expect(r.cut)
        #expect(r.by == "auto mode")
        #expect(!r.command.hasSuffix("…"))
        #expect(w.shareSafe().receipt.riskiest?.command == "")
        #expect(w.shareSafe().receipt.riskiest?.reaches == r.reaches)
    }

    // MARK: - Crossed paths

    @Test func editsFromTwoAgentsCrossOnTheCard() {
        let a = record("claude", "app", from: at(9), to: at(10))
        let b = record("codex", "app", from: at(9), to: at(10))
        let work = [a.sessionId: WorkSpans.Read(spans: a.spans!, edits: [.init(ts: at(9, 10), path: "/r/app/Auth.swift")])]
        let edits = [b.sessionId: [WorkSpans.Edit(ts: at(9, 14), path: "/r/app/Auth.swift")],
                     "elsewhere": [WorkSpans.Edit(ts: at(9, 12), path: "/r/app/Auth.swift")]]
        let w = DayWrap.make(.today, history: [a, b], ledger: [], work: work, edits: edits, now: at(18),
                             calendar: calendar)
        #expect(w.crossings.count == 1)
        #expect(w.crossings.first?.sentence() == "Codex and Claude both edited Auth.swift, 4 min apart")
        let tile = WrapRenderer.tileFacts(w).first { $0.caption == "Crossed paths" }
        #expect(tile?.value == "Auth.swift")
        let shared = WrapRenderer.tileFacts(w.shareSafe()).first { $0.caption == "Crossed paths" }
        #expect(shared?.value == "once")
        #expect(w.shareSafe().crossings.first?.sentence().contains("Auth") == false)
    }

    // MARK: - New personas and facts

    @Test func twoAgentsThroughTheNightAreTheNightShift() {
        let h = [record("claude", "A", from: at(22), to: at(23, 50)),
                 record("codex", "B", from: at(22, 30), to: at(23, 40))]
        let w = DayWrap.make(.today, history: h, ledger: [], now: at(23, 55), calendar: calendar)
        #expect(w.nightPeak == 2)
        #expect(w.nightTogether == 70 * 60)
        #expect(w.persona.title == "The Night-Shift Conductor")
        #expect(w.persona.reason.contains("1h 10m"))
    }

    /// Hands off is measured only where your prompts are known: two hours of
    /// work after one prompt is two hours without you.
    @Test func longWorkAfterOnePromptIsHandsOff() {
        let r = record("claude", "A", from: at(9), to: at(13), spans: [(at(9), at(10, 50))])
        let read = WorkSpans.Read(spans: [WorkSpans.Span(start: at(9), end: at(10, 50))], prompts: [at(9)])
        let w = DayWrap.make(.today, history: [r], ledger: [decision(at(10, 30), waited: 5)],
                             work: [r.sessionId: read], now: at(18), calendar: calendar)
        #expect(w.handsOffLongest == 90 * 60)          // 9:00 → the answer at 10:30
        #expect(w.handsOffAt == at(9))
        #expect(w.handsOffSeconds == 80 * 60 + 10 * 60) // 9:10–10:30, then 10:40–10:50
        #expect(w.persona.title == "Hands-Off")
        let facts = WrapRenderer.tileFacts(w).map(\.caption)
        #expect(facts.contains("Longest hands-off"))
        // Without the transcript nothing is known about you, and nothing is claimed.
        let blind = DayWrap.make(.today, history: [r], ledger: [], now: at(18), calendar: calendar)
        #expect(blind.handsOffLongest == 0 && blind.persona.title != "Hands-Off")
    }

    /// Three comebacks make the Comeback Kid; each session counts once, by its
    /// newest line, since its count only grows.
    @Test func threeComebacksAreTheComebackKid() {
        var a = record("claude", "A", from: at(9), to: at(10))
        a.comebacks = 1
        var a2 = a
        a2.comebacks = 2
        var b = record("codex", "B", from: at(11), to: at(12))
        b.comebacks = 1
        let w = DayWrap.make(.today, history: [a, a2, b], ledger: [], now: at(18), calendar: calendar)
        #expect(w.comebacks == 3)
        #expect(w.persona.title == "The Comeback Kid")
        #expect(w.persona.reason.contains("3 times"))
        let two = DayWrap.make(.today, history: [a2], ledger: [], now: at(18), calendar: calendar)
        #expect(two.persona.title != "The Comeback Kid")
    }

    @Test func theBestParallelismIsAHighScore() {
        let h = [record("claude", "A", from: at(9), to: at(11)),
                 record("codex", "B", from: at(10), to: at(10, 30))]
        let w = DayWrap.make(.today, history: h, ledger: [], now: at(18), calendar: calendar)
        let tile = WrapRenderer.tileFacts(w).first { $0.caption == "High score" }
        #expect(tile?.value == "2 at once")
        // The card reads the clock in the Mac's own zone, which on CI is not the
        // test calendar's.
        #expect(tile?.detail.contains(DayWrap.clock(at(10))) == true)
    }
}

@Suite struct DayWrapWeekWordsTests {
    @Test func aWeeksPeakSaysWhichDay() {
        let week = WrapDemo.wrap(.week)
        #expect(week.persona.title == "The Orchestrator")
        #expect(week.persona.reason.contains(" on "))
        #expect(!WrapDemo.wrap(.today).persona.reason.contains(" on "))
    }
}
