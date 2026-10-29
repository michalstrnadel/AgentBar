import Foundation
import Testing
@testable import AgentBar

/// A suggestion comes only from the person's own repeated, unanimous answers, in
/// one directory, and never for what a rule already speaks for.
@Suite struct RuleSuggestionsTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let repo = "/Users/someone/Projects/AgentBar"

    private func row(_ shape: String, _ decision: String = "allow", via: String = "app",
                     cwd: String = RuleSuggestionsTests.repo, ago: TimeInterval = 3_600) -> DecisionLedger.Record {
        var r = DecisionLedger.Record()
        r.ts = Self.now.timeIntervalSince1970 - ago
        r.shape = shape; r.decision = decision; r.via = via; r.cwd = cwd; r.display = shape
        return r
    }

    private func make(_ rows: [DecisionLedger.Record], rules: [RulesStore.Rule] = [],
                      dismissed: Set<String> = []) -> [RuleSuggestions.Suggestion] {
        RuleSuggestions.make(ledger: rows, rules: rules, dismissed: dismissed, now: Self.now)
    }

    @Test func aHabitBecomesASuggestion() {
        let s = make(Array(repeating: row("bash:npm test"), count: 6))
        #expect(s.map(\.shape) == ["bash:npm test"])
        #expect(s.first?.decision == "allow")
        #expect(s.first?.count == 6)
    }

    @Test func oneRefusalAmongTheAllowsIsNoHabit() {
        let rows = Array(repeating: row("bash:npm test"), count: 8) + [row("bash:npm test", "deny")]
        #expect(make(rows).isEmpty)
    }

    @Test func onlyThePersonsOwnAnswersCount() {
        let rows = Array(repeating: row("bash:git status", via: "rule"), count: 9)
            + Array(repeating: row("bash:git status", via: "claude"), count: 9)
        #expect(make(rows).isEmpty)
    }

    @Test func oldAnswersAreNotAHabitAnyMore() {
        #expect(make(Array(repeating: row("bash:ls", ago: 40 * 86_400), count: 9)).isEmpty)
    }

    @Test func aRuleAlreadySpeaksForIt() {
        let rows = Array(repeating: row("bash:npm test"), count: 6)
        let rule = RulesStore.Rule(id: "r", decision: "allow", shape: "bash:npm test", cwd: Self.repo,
                                   mode: .off)
        #expect(make(rows, rules: [rule]).isEmpty)
        let denyServer = RulesStore.Rule(id: "s", decision: "deny", shape: "tool:mcp__slack__*", cwd: "")
        let mcp = Array(repeating: row("tool:mcp__slack__post", "deny"), count: 6)
        #expect(make(mcp, rules: [denyServer]).isEmpty)
    }

    @Test func noApprovalForAToolThatNamesNoFile() {
        #expect(make(Array(repeating: row("tool:mcp__github__get_issue"), count: 9)).isEmpty)
        #expect(make(Array(repeating: row("tool:mcp__github__get_issue", "deny"), count: 9)).first?.decision == "deny")
    }

    @Test func dismissedStaysAway() {
        let rows = Array(repeating: row("bash:npm test"), count: 6)
        #expect(make(rows, dismissed: ["bash:npm test|\(Self.repo)"]).isEmpty)
    }

    @Test func eachDirectoryIsItsOwnHabit() {
        let rows = Array(repeating: row("bash:make"), count: 5)
            + Array(repeating: row("bash:make", "deny", cwd: "/elsewhere"), count: 5)
        let s = make(rows)
        #expect(Set(s.map(\.decision)) == ["allow", "deny"])
    }

    @Test func aSuggestionOpensInWatching() {
        let s = make(Array(repeating: row("bash:npm test"), count: 6))[0]
        #expect(RuleSuggestions.prefill(s).mode == .watch)
    }
}
