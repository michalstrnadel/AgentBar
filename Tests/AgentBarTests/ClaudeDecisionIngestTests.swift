import Foundation
import Testing
@testable import AgentBar

/// What Claude Code decided without asking, into the ledger: one row per tool
/// call, ever — across restarts, a forgotten ledger, and a lost memory file.
struct ClaudeDecisionIngestTests {
    private let dir: URL
    private var ledger: URL { dir.appendingPathComponent("decisions.jsonl") }
    private var store: URL { dir.appendingPathComponent("mods.d/.ingested.json") }
    private let now = Date().timeIntervalSince1970

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func report(_ ids: [String], session: String = "s1", age: TimeInterval = 5) -> ModReport {
        var r = ModReport(sessionId: session, ts: now)
        r.cwd = "/work/proj"
        r.decisions = ids.map {
            ModReport.Decision(id: $0, ts: now - age, tool: "Bash", command: "git status --short",
                               verdict: "allow", by: "rule", rule: "Bash(git status:*)")
        }
        return r
    }

    private func ingest(_ reports: [ModReport], enabled: Bool = true,
                        onDisk: Set<String> = ["s1", "s2"]) {
        let i = ClaudeDecisionIngest(ledgerURL: ledger, storeURL: store, isEnabled: { enabled })
        i.ingest(reports, projects: ["s1": "proj"], onDisk: onDisk, now: now)
        i.flush()
    }

    private var ids: [String] { DecisionLedger.read(url: ledger).map(\.toolUseId) }

    @Test func aDecisionBecomesAClaudeRow() throws {
        ingest([report(["toolu_1"])])
        let row = try #require(DecisionLedger.read(url: ledger).first)
        #expect(row.via == "claude")
        #expect(row.agent == "claude")
        #expect(row.sessionId == "s1")
        #expect(row.project == "proj")
        #expect(row.cwd == "/work/proj")
        #expect(row.tool == "Bash")
        #expect(row.shape == "bash:git status")
        #expect(row.display == "Bash: git status --short")
        #expect(row.decision == "allow")
        #expect(row.waited == 0)
        #expect(row.by == "rule")
        #expect(row.claudeRule == "Bash(git status:*)")
        #expect(row.toolUseId == "toolu_1")
        #expect(row.rule == "")          // never an AgentBar rule's id
    }

    /// Restarting the app — a fresh instance reading the same files — writes
    /// nothing twice.
    @Test func aRestartWritesNothingTwice() {
        ingest([report(["a", "b"])])
        ingest([report(["a", "b", "c"])])
        ingest([report(["a", "b", "c"])])
        #expect(ids == ["a", "b", "c"])
    }

    /// Either memory alone is enough: the ledger's own ids when the small file is
    /// lost, the small file when the ledger was emptied by `agentbar forget`.
    @Test func eitherMemoryAloneIsEnough() throws {
        ingest([report(["a", "b"])])
        try FileManager.default.removeItem(at: store)
        ingest([report(["a", "b"])])
        #expect(ids == ["a", "b"])

        ingest([report(["a", "b"])])           // the small file is back
        try Data().write(to: ledger)           // agentbar forget
        ingest([report(["a", "b", "c"])])
        #expect(ids == ["c"])                  // forgotten stays forgotten
    }

    /// The switch the person's own clicks obey. Off, nothing is kept — and turning
    /// it back on does not backfill what happened meanwhile.
    @Test func rememberingOffKeepsNothingAndBackfillsNothing() {
        ingest([report(["a"])], enabled: false)
        #expect(ids.isEmpty)
        ingest([report(["a", "b"])], enabled: true)
        #expect(ids == ["b"])
    }

    @Test func aDecisionThePruneWouldDropIsNotWritten() {
        ingest([report(["old"], age: DecisionLedger.maxAge + 60)])
        #expect(ids.isEmpty)
    }

    /// The memory of a session whose sidecar is gone goes with it, so the small
    /// file stays the size of the folder it describes.
    @Test func theMemoryFollowsTheFolder() {
        ingest([report(["a"]), report(["b"], session: "s2")])
        #expect(Set(ClaudeDecisionIngest.load(store).keys) == ["s1", "s2"])
        ingest([report(["a", "c"])], onDisk: ["s1"])
        #expect(Set(ClaudeDecisionIngest.load(store).keys) == ["s1"])
        #expect(ClaudeDecisionIngest.load(store)["s1"] == ["a", "c"])
    }

    // MARK: - What a row says

    private func decision(_ tool: String, command: String = "", file: String = "", url: String = "",
                          description: String = "") -> ModReport.Decision {
        ModReport.Decision(id: "x", ts: 1, tool: tool, command: command, filePath: file, url: url,
                           description: description, verdict: "allow", by: "mode")
    }

    @Test func theLineReadsLikeThePromptWould() {
        #expect(ClaudeDecisionIngest.display(decision("Bash", command: "npm test\nmore"), cwd: "")
                == "Bash: npm test")
        #expect(ClaudeDecisionIngest.display(decision("Edit", file: "/work/proj/src/a.swift"),
                                             cwd: "/work/proj") == "Edit: src/a.swift")
        #expect(ClaudeDecisionIngest.display(decision("WebFetch", url: "https://x.dev"), cwd: "")
                == "WebFetch: https://x.dev")
        #expect(ClaudeDecisionIngest.display(decision("mcp__github__create_issue"), cwd: "")
                == "github: create_issue")
        #expect(ClaudeDecisionIngest.display(decision("Task", description: "Explore"), cwd: "")
                == "Task: Explore")
        #expect(ClaudeDecisionIngest.display(decision("Task"), cwd: "") == "Task")
        let long = String(repeating: "a", count: 100)
        let cut = ClaudeDecisionIngest.display(decision("Bash", command: long), cwd: "")
        #expect(cut == "Bash: " + String(repeating: "a", count: 59) + "…")
    }

    @Test func anEditIsShapedByFolder() {
        var r = ModReport(sessionId: "s", ts: now)
        r.decisions = [ModReport.Decision(id: "e", ts: now, tool: "Edit", filePath: "/w/Sources/x.swift",
                                          verdict: "deny", by: "hook")]
        let row = ClaudeDecisionIngest.rows(for: r, project: "", skipping: [], now: now)
        #expect(row.first?.shape == "edit:Sources/*.swift")
        #expect(row.first?.decision == "deny")
        #expect(row.first?.claudeRule == "")
    }
}
