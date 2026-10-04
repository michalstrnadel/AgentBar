import Foundation
import Testing
@testable import AgentBar

/// `via: "claude"` rows are Claude Code deciding, not you. Every number that is a
/// claim about the person must come out the same with a flood of them in the
/// ledger as without — and the rows themselves must still say what they are.
struct ClaudeRowsTests {
    private static let shape = "bash:git status"

    private func row(_ decision: String, via: String, ts: TimeInterval = 1_000,
                     session: String = "s1", waited: TimeInterval = 0) -> DecisionLedger.Record {
        var r = DecisionLedger.Record()
        r.ts = ts; r.sessionId = session; r.cwd = "/repo"; r.tool = "Bash"
        r.shape = Self.shape; r.display = "Bash: git status"
        r.decision = decision; r.via = via; r.waited = waited
        if via == "claude" {
            r.by = "rule"; r.claudeRule = "Bash(git status:*)"; r.toolUseId = "toolu_\(UUID().uuidString)"
        }
        return r
    }

    private var flood: [DecisionLedger.Record] {
        (0..<500).map { row("allow", via: "claude", ts: 1_000 + Double($0)) }
    }

    @Test func aFloodRaisesNoAllowedHere() {
        let s = DecisionLedger.summary(shape: Self.shape, cwd: "/repo", in: flood)
        #expect(s.isEmpty)
        #expect(DecisionLedger.hint(s) == nil)
        // One decision of yours among them is still one.
        let mixed = flood + [row("allow", via: "app")]
        #expect(DecisionLedger.summary(shape: Self.shape, cwd: "/repo", in: mixed).allowed == 1)
    }

    @Test func aFloodEarnsNoAlwaysAndNoRuleOffer() {
        let s = DecisionLedger.summary(shape: Self.shape, cwd: "", in: flood)
        #expect(!DecisionLedger.shouldPromoteAlways(s, hasRule: true))
        #expect(DecisionLedger.shouldOfferRule(s) == nil)
    }

    /// A watching rule is judged on what **you** did. Claude Code allowing the same
    /// command moments later is not you agreeing with it.
    @Test func aClaudeRowNeverPairsWithAWatchRow() {
        var watch = row("watch", via: "rule", ts: 1_000)
        watch.would = "allow"; watch.rule = "r-1"
        let a = DecisionLedger.agreement(rule: "r-1", in: [watch, row("allow", via: "claude", ts: 1_001)])
        #expect(a.agreed == 0)
        #expect(a.unwitnessed == 1)
        // …while your own answer to the same prompt still does.
        let b = DecisionLedger.agreement(rule: "r-1", in: [watch, row("allow", via: "claude", ts: 1_001),
                                                         row("allow", via: "cli", ts: 1_002)])
        #expect(b.agreed == 1)
    }

    /// Nobody waited and nobody was asked: the day's "answered" and "waited" stay
    /// yours, and rules keep their own count.
    @Test func theDaysAccountLeavesThemOut() {
        let rows = flood + [row("deny", via: "app", ts: 1_100, waited: 40),
                            row("allow", via: "rule", ts: 1_200)]
        let day = DecisionLedger.waiting(in: rows, since: 0, until: 10_000)
        #expect(day.answered == 1)
        #expect(day.waited == 40)
        #expect(DecisionLedger.byRules(in: rows, since: 0, until: 10_000) == 1)
    }

    @Test func aRuleIsNeverOfferedFromThem() {
        var other = row("allow", via: "claude")
        other.shape = "bash:npm test"
        let offered = RuleSheet.offeredShapes(in: [other], common: [])
        #expect(offered.isEmpty)
        #expect(RuleSheet.knownDirectories(decisions: [other], history: []).isEmpty)
    }

    // MARK: - The rows themselves

    @Test func theNewFieldsRoundTripAndStayOutOfOtherRows() throws {
        let claude = row("deny", via: "claude")
        let line = String(data: try JSONSerialization.data(withJSONObject: claude.json, options: [.sortedKeys]),
                          encoding: .utf8)!
        let back = try #require(DecisionLedger.Record(jsonLine: line))
        #expect(back == claude)

        // A row of any other kind is what it was before: no new keys at all.
        let mine = row("allow", via: "app")
        for key in ["by", "claudeRule", "reason", "toolUseId"] {
            #expect(mine.json[key] == nil, "\(key)")
        }
    }

    @Test func theExportSaysWhoInClaudeCodeDecided() {
        let csv = DecisionLedger.csv([row("allow", via: "claude")])
        let lines = csv.split(separator: "\n")
        #expect(lines[0] == "when,agent,directory,tool,shape,what,decision,would have,answered by,rule,by,claude rule,waited (s)")
        #expect(lines[1].contains("\"claude\",\"\",\"rule\",\"Bash(git status:*)\",\"0\""))
    }

    /// A busy day of Claude Code's own decisions must not push the person's record
    /// out of the file: the two halves have ceilings of their own.
    @Test func pruneCapsClaudeRowsWithoutTouchingYours() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-claude-prune-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let now: TimeInterval = 1_789_646_400
        let mine = (0..<3).map { row("allow", via: "app", ts: now - 100 + Double($0)) }
        let theirs = (0..<(DecisionLedger.maxClaudeRecords + 10)).map {
            row("allow", via: "claude", ts: now - 50 + Double($0) / 1_000)
        }
        DecisionLedger.append(mine + theirs, to: url)
        DecisionLedger.prune(url: url, now: now)
        let kept = DecisionLedger.read(url: url)
        #expect(kept.filter { $0.via == "app" }.count == 3)
        #expect(kept.filter { $0.via == "claude" }.count == DecisionLedger.maxClaudeRecords)
        #expect(kept.first?.via == "app")    // file order kept
    }
}
