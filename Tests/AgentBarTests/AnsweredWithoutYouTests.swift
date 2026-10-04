import Foundation
import Testing
@testable import AgentBar

/// The Approvals card about what Claude Code decided without you, and the rules
/// list's note about it — as words, without a window.
struct AnsweredWithoutYouTests {
    private static let now = Date(timeIntervalSince1970: 1_789_646_400)   // a noon
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func row(_ decision: String = "allow", by: String = "rule", rule: String = "Bash(git:*)",
                     shape: String = "bash:git status", ago: TimeInterval = 60,
                     via: String = "claude", cwd: String = "/repo") -> DecisionLedger.Record {
        var r = DecisionLedger.Record()
        r.ts = Self.now.timeIntervalSince1970 - ago
        r.via = via; r.decision = decision; r.by = by; r.cwd = cwd
        r.claudeRule = by == "rule" ? rule : ""
        r.shape = shape
        return r
    }

    private func model(_ rows: [DecisionLedger.Record], installed: Bool = true,
                       ledgerOn: Bool = true) -> AnsweredWithoutYou.Model {
        AnsweredWithoutYou.model(rows, modInstalled: installed, ledgerOn: ledgerOn,
                                 now: Self.now, calendar: Self.calendar)
    }

    @Test func todayAndTheWeekAreCountedApart() {
        let m = model([row(), row("deny"), row(ago: 2 * 86_400), row(ago: 8 * 86_400)])
        #expect(m.today == .init(allowed: 1, denied: 1))
        #expect(m.week == .init(allowed: 2, denied: 1))   // eight days ago is out
        #expect(AnsweredWithoutYou.lines(m).first == "Today 1 run, 1 refused · last 7 days 2 run, 1 refused")
    }

    @Test func eachSourceIsNamed() {
        let m = model([row(), row(), row(rule: "Bash(npm test:*)"), row(by: "mode"),
                       row("deny", by: "hook")])
        #expect(AnsweredWithoutYou.lines(m) == [
            "Today 4 run, 1 refused · last 7 days 4 run, 1 refused",
            "Your Claude Code rule `Bash(git:*)` — 2 run",
            "Your Claude Code rule `Bash(npm test:*)` — 1 run",
            "Claude Code's permission mode — 1 run",
            "A hook or another mod — 1 refused",
            "Most often: git status 4×",
            AnsweredWithoutYou.blindSpotText,
        ])
    }

    /// The mod cannot see what auto mode settles after an `ask`, and the card says
    /// so every time it shows a number — never "everything that ran".
    @Test func theBlindSpotIsAlwaysSaid() {
        let m = model([row()])
        #expect(AnsweredWithoutYou.lines(m).last == AnsweredWithoutYou.blindSpotText)
        #expect(!AnsweredWithoutYou.nothingText.contains("everything"))
    }

    @Test func atMostFiveRulesThenTheRestTogether() {
        var rows: [DecisionLedger.Record] = []
        for i in 0..<7 { rows += Array(repeating: row(rule: "Bash(r\(i):*)"), count: 10 - i) }
        let m = model(rows)
        let ruleSources = m.sources.map(\.title)
        #expect(ruleSources.count == 6)
        #expect(ruleSources.first == "Your Claude Code rule `Bash(r0:*)`")
        #expect(ruleSources.last == "2 more of your rules")
        #expect(m.sources.last?.tally.allowed == 5 + 4)
    }

    @Test func theCommonestShapesComeFirstAndOnlyAllowsCount() {
        let m = model([row(shape: "bash:npm test"), row(shape: "bash:npm test"), row(),
                       row("deny", shape: "bash:rm"), row(shape: "edit:src/*.swift")])
        #expect(m.shapes.map(\.shape) == ["bash:npm test", "bash:git status", "edit:src/*.swift"])
    }

    @Test func yourOwnRowsAreNotOnThisCard() {
        let m = model([row(via: "app"), row(via: "rule"), row(via: "cli")])
        #expect(m.week.total == 0)
        #expect(m.empty == AnsweredWithoutYou.nothingText)
    }

    @Test func emptySaysWhy() {
        #expect(model([], installed: false).empty == AnsweredWithoutYou.modOffText)
        #expect(model([], installed: true).empty == AnsweredWithoutYou.nothingText)
        #expect(model([], installed: true, ledgerOn: false).empty == AnsweredWithoutYou.ledgerOffText)
        #expect(AnsweredWithoutYou.lines(model([], installed: false)) == [AnsweredWithoutYou.modOffText])
        #expect(AnsweredWithoutYou.modOffText.contains("Settings ▸ Agents"))
    }

    @Test func theModCountsAsInstalledByItsFolders() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-awy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!AnsweredWithoutYou.modInstalled(root: root))
        let mods = root.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: mods.appendingPathComponent(".ingested.json"))
        #expect(!AnsweredWithoutYou.modInstalled(root: root))   // our own file is not the mod
        try Data("{}".utf8).write(to: mods.appendingPathComponent("s1.json"))
        #expect(AnsweredWithoutYou.modInstalled(root: root))
    }

    // MARK: - The rules list's note

    private func rule(_ decision: String = "allow", shape: String = "bash:git status",
                      cwd: String = "/repo") -> RulesStore.Rule {
        var r = RulesStore.Rule()
        r.id = "r-1"; r.decision = decision; r.shape = shape; r.cwd = cwd
        return r
    }

    @Test func anApprovingRuleHearsThatClaudeCodeAlreadyAllowsIt() {
        let rows = [row(rule: "Bash(git status:*)"), row(rule: "Bash(git status:*)"), row(rule: "Bash(git:*)"),
                    row(rule: "Bash(*)", cwd: "/elsewhere")]
        #expect(AnsweredWithoutYou.claudeAlreadyAllows(rule(), in: rows, now: Self.now) == "Bash(git status:*)")
        #expect(AnsweredWithoutYou.alreadyAllowsNote("Bash(git status:*)")
                == "Claude Code already allows this itself (`Bash(git status:*)`)")
        // A subdirectory of the rule's directory is inside it.
        #expect(AnsweredWithoutYou.claudeAlreadyAllows(rule(), in: [row(cwd: "/repo/sub")], now: Self.now) != nil)
    }

    @Test func theNoteNeedsAnAllowByARuleThisWeekForTheSameShapeHere() {
        #expect(AnsweredWithoutYou.claudeAlreadyAllows(rule("deny"), in: [row()], now: Self.now) == nil)
        #expect(AnsweredWithoutYou.claudeAlreadyAllows(rule(), in: [row(by: "mode")], now: Self.now) == nil)
        #expect(AnsweredWithoutYou.claudeAlreadyAllows(rule(), in: [row("deny")], now: Self.now) == nil)
        #expect(AnsweredWithoutYou.claudeAlreadyAllows(rule(), in: [row(ago: 8 * 86_400)], now: Self.now) == nil)
        #expect(AnsweredWithoutYou.claudeAlreadyAllows(rule(), in: [row(shape: "bash:git push")],
                                                       now: Self.now) == nil)
        #expect(AnsweredWithoutYou.claudeAlreadyAllows(rule(), in: [row(cwd: "/repository")],
                                                       now: Self.now) == nil)
        #expect(AnsweredWithoutYou.claudeAlreadyAllows(rule(), in: [row(via: "app")], now: Self.now) == nil)
    }

    @Test func theRulesTrailCarriesTheNote() {
        var r = rule()
        r.mode = .on
        let trail = RulesView.trail(r, ledger: [row(rule: "Bash(git status:*)")], now: Self.now)
        #expect(trail.text.hasSuffix("· Claude Code already allows this itself (`Bash(git status:*)`)"))
        #expect(trail.tooltip?.contains("Claude Code already allows") == true)
    }
}
