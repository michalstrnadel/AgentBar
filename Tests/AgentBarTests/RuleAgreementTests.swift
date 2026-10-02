import Foundation
import Testing
@testable import AgentBar

/// Whether a watching rule matched **you**, not just a prompt. Most of these are
/// about the one thing the count must never do: call something agreement that
/// nobody witnessed — a terminal answer, a keystroke, a timeout, a rule.
struct RuleAgreementTests {
    private static let t0: TimeInterval = 1_789_646_400
    private static let day: TimeInterval = 86_400
    private static let shape = "bash:git status"

    private func watch(_ ts: TimeInterval, session: String = "s1", rule: String = "r-1",
                       would: String = "allow", shape: String = RuleAgreementTests.shape,
                       tool: String = "Bash") -> DecisionLedger.Record {
        var r = DecisionLedger.Record()
        r.ts = ts; r.sessionId = session; r.shape = shape; r.tool = tool
        r.decision = "watch"; r.would = would; r.via = "rule"; r.rule = rule
        r.display = "Bash: git status"
        return r
    }

    private func human(_ ts: TimeInterval, _ decision: String, session: String = "s1",
                       shape: String = RuleAgreementTests.shape, tool: String = "Bash",
                       via: String = "app", display: String = "Bash: git status")
    -> DecisionLedger.Record {
        var r = DecisionLedger.Record()
        r.ts = ts; r.sessionId = session; r.shape = shape; r.tool = tool
        r.decision = decision; r.via = via; r.display = display
        return r
    }

    private func agreement(_ rows: [DecisionLedger.Record], since: TimeInterval = 0)
    -> DecisionLedger.Agreement {
        DecisionLedger.agreement(rule: "r-1", in: rows, since: since)
    }

    // MARK: - Matching

    @Test func theSameSessionAndShapeAnsweredTheSameWayAgrees() {
        let a = agreement([watch(Self.t0), human(Self.t0 + 20, "allow")])
        #expect(a.agreed == 1 && a.disagreed == 0 && a.unwitnessed == 0)
        #expect(a.firstAt == Self.t0 && a.lastAt == Self.t0)
    }

    @Test func theOtherWayDisagreesAndIsKept() {
        let no = human(Self.t0 + 20, "deny", display: "Bash: git status --porcelain")
        let a = agreement([watch(Self.t0), no])
        #expect(a.agreed == 0 && a.disagreed == 1)
        #expect(a.lastDisagreement == no)
    }

    @Test func alwaysIsAnAllow() {
        #expect(agreement([watch(Self.t0), human(Self.t0 + 5, "always", via: "cli")]).agreed == 1)
        // …and so it is the other way for a rule that would refuse.
        let refusing = [watch(Self.t0, would: "deny"), human(Self.t0 + 5, "always")]
        #expect(agreement(refusing).disagreed == 1)
    }

    @Test func anotherSessionOrShapeOrToolIsNotTheSamePrompt() {
        let rows = [
            watch(Self.t0, session: "s1"), human(Self.t0 + 5, "allow", session: "s2"),
            watch(Self.t0 + 100, session: "s3"), human(Self.t0 + 105, "allow", session: "s3",
                                                       shape: "bash:git diff"),
            watch(Self.t0 + 200, session: "s4"), human(Self.t0 + 205, "allow", session: "s4",
                                                       tool: "Shell"),
        ]
        let a = agreement(rows)
        #expect(a.witnessed == 0)
        #expect(a.unwitnessed == 3)
    }

    @Test func anAnswerOutsideTheWindowIsAnotherPrompt() {
        let late = Self.t0 + DecisionLedger.agreementWindow + 1
        #expect(agreement([watch(Self.t0), human(late, "allow")]).unwitnessed == 1)
        let inTime = Self.t0 + DecisionLedger.agreementWindow
        #expect(agreement([watch(Self.t0), human(inTime, "allow")]).agreed == 1)
        // An answer from before the rule ever saw the prompt is not an answer to it.
        #expect(agreement([human(Self.t0 - 5, "allow"), watch(Self.t0)]).unwitnessed == 1)
    }

    @Test func aRuleIsNeverTheHuman() {
        var byRule = human(Self.t0 + 5, "allow", via: "rule")
        byRule.rule = "r-2"
        #expect(agreement([watch(Self.t0), byRule]).unwitnessed == 1)
    }

    @Test func aHandOffIsNotAVerdict() {
        let rows = [watch(Self.t0), human(Self.t0 + 5, "defer"), human(Self.t0 + 6, "answer")]
        #expect(agreement(rows).unwitnessed == 1)
        // …and does not hide the verdict that follows it.
        #expect(agreement(rows + [human(Self.t0 + 30, "allow")]).agreed == 1)
    }

    @Test func noSessionProvesNothing() {
        #expect(agreement([watch(Self.t0, session: ""), human(Self.t0 + 5, "allow", session: "")])
                .unwitnessed == 1)
    }

    /// Two identical prompts pending at once each get their own answer; one answer
    /// is never counted for both.
    @Test func oneAnswerWitnessesOnePrompt() {
        let both = agreement([watch(Self.t0), watch(Self.t0 + 1),
                              human(Self.t0 + 10, "allow"), human(Self.t0 + 12, "deny")])
        #expect(both.agreed == 1 && both.disagreed == 1)
        let once = agreement([watch(Self.t0), watch(Self.t0 + 1), human(Self.t0 + 10, "allow")])
        #expect(once.agreed == 1 && once.unwitnessed == 1)
    }

    @Test func onlyThisRulesRowsAndOnlySinceItWasSaved() {
        let rows = [watch(Self.t0 - 100), human(Self.t0 - 90, "deny"),
                    watch(Self.t0, rule: "r-2"), human(Self.t0 + 5, "allow"),
                    watch(Self.t0 + 50), human(Self.t0 + 55, "allow")]
        let a = agreement(rows, since: Self.t0)
        #expect(a.agreed == 1 && a.disagreed == 0 && a.unwitnessed == 0)
    }

    // MARK: - Letting it answer

    /// `n` agreements spread over `days` days, a day apart so no time zone can fold
    /// two of them together.
    private func evidence(_ n: Int, days: Int) -> [DecisionLedger.Record] {
        (0..<n).flatMap { i -> [DecisionLedger.Record] in
            let ts = Self.t0 + Double(i % days) * Self.day + Double(i / days) * 60
            return [watch(ts, session: "s\(i)"), human(ts + 5, "allow", session: "s\(i)")]
        }
    }

    @Test func tenAgreementsOverThreeDaysEarnTheOffer() {
        let a = agreement(evidence(10, days: 3))
        #expect(a.agreed == 10 && a.days == 3)
        #expect(DecisionLedger.canLetItAnswer(a))
    }

    @Test func nineAreNotEnough() {
        #expect(!DecisionLedger.canLetItAnswer(agreement(evidence(9, days: 3))))
    }

    @Test func twoDaysAreNotEnough() {
        let a = agreement(evidence(30, days: 2))
        #expect(a.days == 2)
        #expect(!DecisionLedger.canLetItAnswer(a))
    }

    @Test func oneDisagreementBlocksIt() {
        let rows = evidence(40, days: 5) + [watch(Self.t0 + 10 * Self.day, session: "x"),
                                            human(Self.t0 + 10 * Self.day + 5, "deny", session: "x")]
        let a = agreement(rows)
        #expect(a.agreed == 40 && a.disagreed == 1)
        #expect(!DecisionLedger.canLetItAnswer(a))
        // Saved again after it, the old evidence is gone with it — and has to be
        // earned again rather than restored.
        #expect(!DecisionLedger.canLetItAnswer(agreement(rows, since: Self.t0 + 11 * Self.day)))
    }

    @Test func unwitnessedNeitherHelpsNorBlocks() {
        let rows = evidence(10, days: 3) + (0..<20).map { watch(Self.t0 + Double($0), session: "t\($0)") }
        let a = agreement(rows)
        #expect(a.unwitnessed == 20)
        #expect(DecisionLedger.canLetItAnswer(a))
        #expect(!DecisionLedger.canLetItAnswer(agreement((0..<20).map {
            watch(Self.t0 + Double($0) * Self.day, session: "t\($0)") })))
    }

    @Test func theOfferIsOnlyEverForAWatchingRule() {
        let rows = evidence(10, days: 3)
        var rule = RulesStore.Rule(id: "r-1", decision: "allow", shape: Self.shape,
                                   cwd: "/work/proj", mode: .watch, created: 0)
        #expect(RulesView.mayLetItAnswer(rule, ledger: rows))
        rule.mode = .on
        #expect(!RulesView.mayLetItAnswer(rule, ledger: rows))
        rule.mode = .off
        #expect(!RulesView.mayLetItAnswer(rule, ledger: rows))
    }

    // MARK: - What the row says

    private let now = Date(timeIntervalSince1970: RuleAgreementTests.t0 + 3600)

    @Test func theLineSaysWhetherYouAgreed() {
        let rule = RulesStore.Rule(id: "r-1", decision: "allow", shape: Self.shape,
                                   cwd: "/work/proj", mode: .watch, created: 0)
        let rows = [watch(Self.t0), human(Self.t0 + 5, "allow"),
                    watch(Self.t0 + 60, session: "s2"), human(Self.t0 + 65, "deny", session: "s2",
                                                              display: "Bash: git status -uall"),
                    watch(Self.t0 + 120, session: "s3")]
        let line = RulesView.trail(rule, ledger: rows, now: now)
        #expect(line.text == "Would have allowed 3× · you did the same 1×, the other way 1× · last today")
        #expect(line.tooltip?.hasPrefix("Last time you went the other way: you denied “Bash: git status -uall” today at ") == true)
        #expect(!line.empty)
    }

    @Test func unwitnessedIsSaidOnlyWhenItIsMostOfTheStory() {
        let rule = RulesStore.Rule(id: "r-1", decision: "allow", shape: Self.shape,
                                   cwd: "/work/proj", mode: .watch, created: 0)
        let none = RulesView.trail(rule, ledger: [watch(Self.t0), watch(Self.t0 + 1, session: "s2")],
                                   now: now)
        #expect(none.text == "Would have allowed 2× · none answered here yet · last today")
        #expect(none.tooltip == nil)
        let some = RulesView.trail(rule, ledger: [watch(Self.t0), human(Self.t0 + 2, "allow"),
                                                  watch(Self.t0 + 5, session: "s2"),
                                                  watch(Self.t0 + 6, session: "s3")], now: now)
        #expect(some.text == "Would have allowed 3× · you did the same 1×, 2× not answered here · last today")
        #expect(RulesView.trail(rule, ledger: [], now: now).text == "Nothing has matched it yet")
    }

    @Test func anAnsweringRulesLineIsUnchanged() {
        let rule = RulesStore.Rule(id: "r-1", decision: "allow", shape: Self.shape,
                                   cwd: "/work/proj", mode: .on, created: Self.t0 + 999)
        var fired = human(Self.t0, "allow", via: "rule")
        fired.rule = "r-1"
        #expect(RulesView.trail(rule, ledger: [fired], now: now).text == "Allowed 1× · last today")
    }

    @Test func theConfirmationRestatesTheEvidence() {
        let rule = RulesStore.Rule(id: "r-1", decision: "allow", shape: Self.shape,
                                   cwd: "/work/proj", mode: .watch, created: 0)
        var a = DecisionLedger.Agreement()
        a.agreed = 12; a.days = 4; a.unwitnessed = 2
        let text = RulesView.letItAnswerText(rule, a)
        #expect(text.hasPrefix("Allow git status in proj."))
        #expect(text.contains("you answered 12 of its prompts here and allowed every one, across 4 days"))
        #expect(text.contains("2 more were answered somewhere AgentBar cannot see"))
        #expect(text.contains("The live command is still checked first"))
    }

    /// The path "Let it answer" takes is the sheet's: validated, stamped, written.
    @Test func lettingItAnswerTakesTheSheetsPath() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rules-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let watching = RulesStore.Rule(id: "r-1", decision: "allow", shape: Self.shape,
                                       cwd: "/work/proj", mode: .watch, created: 5)
        RulesStore.save([watching], to: url)
        var on = watching
        on.mode = .on
        let saved = try RuleSheet.finalised(on, now: Self.t0).get()
        #expect(saved.created == Self.t0)
        RulesStore.put(saved, to: url)
        #expect(RulesStore.load(url: url).rules == [saved])
        // A rule the file would refuse is refused here too, and nothing is written.
        var bad = on
        bad.cwd = ""
        guard case .failure(let why) = RuleSheet.finalised(bad) else {
            Issue.record("an approving rule with no directory was accepted"); return
        }
        #expect(why.text.hasPrefix("This rule approves without naming a directory"))
    }

    // MARK: - The fixture the CLI test reads too

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/rule-agreement")

    /// `Scripts/test/cli-test.sh` asserts the same numbers from the same two files,
    /// so the app and `agentbar rules` cannot quietly count differently.
    @Test func theSharedFixtureCountsTheSameEverywhere() throws {
        let rules = RulesStore.load(url: Self.fixtures.appendingPathComponent("rules.json")).rules
        let ledger = DecisionLedger.read(url: Self.fixtures.appendingPathComponent("decisions.jsonl"))
        #expect(rules.count == 2 && ledger.count == 38)
        let agree = try #require(rules.first { $0.id == "r-agree" })
        let a = DecisionLedger.agreement(rule: agree.id, in: ledger, since: agree.created)
        #expect(a.agreed == 10 && a.disagreed == 0 && a.unwitnessed == 5 && a.days == 3)
        #expect(RulesView.mayLetItAnswer(agree, ledger: ledger))
        let split = try #require(rules.first { $0.id == "r-split" })
        let b = DecisionLedger.agreement(rule: split.id, in: ledger, since: split.created)
        #expect(b.agreed == 2 && b.disagreed == 1 && b.unwitnessed == 0 && b.days == 1)
        #expect(b.lastDisagreement?.display == "Bash: curl https://example.com")
        #expect(!RulesView.mayLetItAnswer(split, ledger: ledger))
    }
}
