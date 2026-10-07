import Foundation
import Testing
@testable import AgentBar

/// Settings ▸ Approvals' "Your week of decisions". What it must never do is count
/// something as you that was not you, or offer to write a rule it could not stand by.
struct DecisionWeekTests {
    private static let now = Date(timeIntervalSince1970: 1_789_646_400)
    private static let t = now.timeIntervalSince1970
    private static let repo = "/work/proj"

    private func row(_ shape: String, _ decision: String, ago: TimeInterval = 3_600,
                     waited: TimeInterval = 60, via: String = "app", cwd: String = DecisionWeekTests.repo,
                     session: String = "s1", rule: String = "", would: String = "")
    -> DecisionLedger.Record {
        var r = DecisionLedger.Record()
        r.ts = Self.t - ago
        r.shape = shape; r.decision = decision; r.waited = waited; r.via = via
        r.cwd = cwd; r.sessionId = session; r.rule = rule; r.would = would
        r.agent = "claude"; r.tool = shape.hasPrefix("bash:") ? "Bash" : "Edit"
        r.display = "Bash: " + shape
        return r
    }

    private func make(_ rows: [DecisionLedger.Record],
                      rules: [RulesStore.Rule] = []) -> DecisionWeek.Week {
        // An old row first, so the week is not "since" the newest fixture.
        let anchor = row("bash:old", "allow", ago: 20 * 86_400)
        return DecisionWeek.make(ledger: [anchor] + rows, rules: rules, now: Self.now)
    }

    // MARK: - What is counted

    @Test func groupsByShapeAndSortsByTimeWaited() {
        let w = make([
            row("bash:ls", "allow", waited: 10), row("bash:ls", "allow", waited: 10),
            row("bash:git push", "allow", waited: 100),
        ])
        #expect(w.items.map(\.shape) == ["bash:git push", "bash:ls"])
        #expect(w.items[1].asked == 2)
        #expect(w.items[1].waited == 20)
        #expect(w.asked == 3)
        #expect(!w.startedLate)
    }

    @Test func onlyYourOwnAnswersAreCounted() {
        let w = make([
            row("bash:ls", "allow"),
            row("bash:ls", "allow", via: "rule", rule: "r-1"),
            row("bash:ls", "allow", via: "claude"),
            row("bash:ls", "watch", via: "rule", rule: "r-1", would: "allow"),
            row("tool:AskUserQuestion", "answer"),
            row("bash:ls", "allow", ago: 8 * 86_400),
        ])
        #expect(w.items.count == 1)
        #expect(w.items[0].asked == 1)
        #expect(w.byRules == 1)
    }

    @Test func showsFiveAndSaysHowManyMore() {
        let shapes = ["bash:a", "bash:b", "bash:c", "bash:d", "bash:e", "bash:f", "bash:g"]
        let w = make(shapes.map { row($0, "allow") })
        #expect(w.items.count == DecisionWeek.shown)
        #expect(w.more == 2)
    }

    @Test func aRecordYoungerThanAWeekSaysWhereItStarts() {
        let w = DecisionWeek.make(ledger: [row("bash:ls", "allow", ago: 2 * 86_400)],
                                  rules: [], now: Self.now)
        #expect(w.startedLate)
        #expect(DecisionWeek.span(w, now: Self.now).hasPrefix("Since "))
    }

    @Test func nothingAskedIsEmpty() {
        #expect(make([]).isEmpty)
        #expect(DecisionWeek.emptyText(ledgerOn: false).contains("off"))
    }

    // MARK: - Honest figures

    @Test func aMissingWaitMakesTheTotalAFloor() {
        let some = make([row("bash:ls", "allow", waited: 120), row("bash:ls", "allow", waited: 0)])
        #expect(DecisionWeek.figure(some.items[0]) == "2× · at least 2m waited")
        let none = make([row("bash:ls", "allow", waited: 0)])
        #expect(DecisionWeek.figure(none.items[0]) == "1× · wait not recorded")
        let all = make([row("bash:ls", "allow", waited: 400)])
        #expect(DecisionWeek.figure(all.items[0]) == "1× · 6m waited")
    }

    @Test func theMixSaysHowYouAnswered() {
        let w = make([row("bash:rm", "deny"), row("bash:rm", "always"), row("bash:rm", "defer")])
        let text = DecisionWeek.detail(w.items[0], now: Self.now)
        #expect(text.hasPrefix("Allowed 1, denied 1, sent 1 to the terminal"))
        #expect(text.hasSuffix("no rule"))
    }

    // MARK: - The rules you wrote

    @Test func aWatchingRuleSaysWhatItWouldHaveDone() {
        let rule = RulesStore.Rule(id: "r-1", decision: "allow", shape: "bash:npm test",
                                   cwd: Self.repo, mode: .watch, created: Self.t - 30 * 86_400)
        var rows: [DecisionLedger.Record] = []
        for i in 0..<3 {
            let s = "s\(i)"
            let ago = TimeInterval(3_600 * (i + 1))
            rows.append(row("bash:npm test", "watch", ago: ago + 5, waited: 0, via: "rule",
                            session: s, rule: "r-1", would: "allow"))
            rows.append(row("bash:npm test", i == 2 ? "deny" : "allow", ago: ago, waited: 90,
                            session: s))
        }
        rows.append(row("bash:npm test", "allow", waited: 90, session: "unseen"))
        let w = make(rows, rules: [rule])
        let note = w.items[0].rule
        #expect(note?.reachable == 4)
        #expect(note?.agreement.agreed == 2)
        #expect(note?.agreement.agreedWaited == 180)
        #expect(w.items[0].offer == nil)
        let text = DecisionWeek.ruleClause(note!, now: Self.now)
        #expect(text == "watching allow rule in proj would have answered 3 of 4, about 3m"
                + " · you went the other way 1×")
    }

    @Test func aWatchingRuleCountsOnlyWhereItReaches() {
        let rule = RulesStore.Rule(id: "r-1", decision: "allow", shape: "bash:ls",
                                   cwd: Self.repo, mode: .watch, created: 0)
        let w = make([row("bash:ls", "allow"), row("bash:ls", "allow", cwd: "/elsewhere")],
                     rules: [rule])
        #expect(w.items[0].rule?.reachable == 1)
    }

    @Test func anAnsweringRuleSaysWhatItDid() {
        let rule = RulesStore.Rule(id: "r-2", decision: "deny", shape: "bash:curl", mode: .on)
        let w = make([row("bash:curl", "deny"),
                      row("bash:curl", "deny", via: "rule", rule: "r-2"),
                      row("bash:curl", "deny", via: "rule", rule: "r-2")], rules: [rule])
        let text = DecisionWeek.ruleClause(w.items[0].rule!, now: Self.now)
        #expect(text == "answering deny rule everywhere took 2 itself")
    }

    @Test func anOffRuleIsNamedAndNotOfferedAgain() {
        let rule = RulesStore.Rule(id: "r-3", decision: "deny", shape: "bash:rm", mode: .off)
        let w = make(Array(repeating: row("bash:rm", "deny"), count: 6), rules: [rule])
        #expect(w.items[0].offer == nil)
        #expect(DecisionWeek.ruleClause(w.items[0].rule!) == "deny rule everywhere is off")
    }

    // MARK: - Write a rule…

    @Test func theSameAnswerFiveTimesOffersARuleThatStartsWatching() throws {
        let w = make(Array(repeating: row("bash:git push", "allow"), count: 5))
        #expect(w.items[0].offer == "allow")
        let p = try #require(DecisionWeek.prefill(w.items[0]))
        #expect(p.decision == "allow")
        #expect(p.shape == "bash:git push")
        #expect(p.cwd == Self.repo)
        #expect(p.mode == .watch)
        #expect(p.id.isEmpty)
    }

    @Test func aMixedOrShortRecordOffersNothing() {
        var mixed = Array(repeating: row("bash:ls", "allow"), count: 5)
        mixed.append(row("bash:ls", "deny"))
        #expect(make(mixed).items[0].offer == nil)
        #expect(make(Array(repeating: row("bash:ls", "allow"), count: 4)).items[0].offer == nil)
    }

    @Test func anApprovalThatCouldNeverAnswerIsNotOffered() {
        let tool = Array(repeating: row("tool:WebFetch", "allow"), count: 5)
        #expect(make(tool).items[0].offer == nil)
        let nowhere = Array(repeating: row("bash:ls", "allow", cwd: ""), count: 5)
        #expect(make(nowhere).items[0].offer == nil)
        // A refusal may apply anywhere, so it is still offered.
        let deny = Array(repeating: row("tool:WebFetch", "deny"), count: 5)
        #expect(make(deny).items[0].offer == "deny")
    }
}
