import Foundation
import Testing
@testable import AgentBar

/// `mods.d/<id>.json` read the way the protocol says: the one file a reader can
/// catch half-written, from a folder anybody may write to.
struct ModReportTests {
    static let now: TimeInterval = 1_791_146_583

    /// The protocol's own example, nearly verbatim.
    static let example = """
    {"v":1,"agent":"claude","session_id":"s1","ts":1791146583,"mod":"1.36.0",
     "cwd":"/Users/me/AgentBar","ended":false,
     "context":{"percent":16,"tokens":31310,"window":200000},
     "rate_limits":[{"kind":"five_hour","percent_used":62,"resets_at":"2026-10-04T23:00:00Z"},
                    {"kind":"seven_day","percent_used":28,"resets_at":"2026-10-10T05:00:00Z"}],
     "subagents":2,
     "decisions":[{"id":"toolu_013T","ts":1791146581,"tool":"Bash",
                   "input":{"command":"git status --short"},
                   "verdict":"allow","by":"rule","rule":"Bash(git status:*)","reason":""}]}
    """

    private func decode(_ text: String, id: String = "s1") -> ModReport? {
        ModReport.decode(Data(text.utf8), sessionId: id)
    }

    private func sidecar(decisions: [[String: Any]] = [], extra: [String: Any] = [:]) -> String {
        var o: [String: Any] = ["v": 1, "agent": "claude", "session_id": "s1", "ts": Self.now,
                                "decisions": decisions]
        for (k, v) in extra { o[k] = v }
        return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    private func decision(_ id: String, verdict: String = "allow", by: String = "mode",
                          extra: [String: Any] = [:]) -> [String: Any] {
        var d: [String: Any] = ["id": id, "ts": Self.now - 5, "tool": "Bash",
                                "input": ["command": "ls"], "verdict": verdict, "by": by]
        for (k, v) in extra { d[k] = v }
        return d
    }

    @Test func theProtocolsExampleReadsInFull() throws {
        let r = try #require(decode(Self.example))
        #expect(r.sessionId == "s1")
        #expect(r.ts == Self.now)
        #expect(r.cwd == "/Users/me/AgentBar")
        #expect(r.mod == "1.36.0")
        #expect(!r.ended)
        #expect(r.context == ModReport.Context(percent: 16, tokens: 31_310, window: 200_000))
        #expect(r.rateLimits.map(\.kind) == ["five_hour", "seven_day"])
        #expect(r.rateLimits[0].percentUsed == 62)
        #expect(r.rateLimits[0].resetsAt == ISO8601DateFormatter().date(from: "2026-10-04T23:00:00Z"))
        #expect(r.subagents == 2)
        let d = try #require(r.decisions.first)
        #expect(d.id == "toolu_013T")
        #expect(d.command == "git status --short")
        #expect(d.verdict == "allow")
        #expect(d.by == "rule")
        #expect(d.rule == "Bash(git status:*)")
    }

    /// The mod rewrites in place, so a read can land on any prefix of a file.
    /// Every one of them is "no news", never a crash and never half a report.
    @Test func aTornWriteIsNoNewsAtEveryLength() {
        let bytes = Array(Self.example.utf8)
        for cut in stride(from: 0, to: bytes.count - 1, by: 7) {
            #expect(ModReport.decode(Data(bytes[0..<cut]), sessionId: "s1") == nil, "cut at \(cut)")
        }
    }

    @Test func onlyVersionOneIsRead() {
        #expect(decode(sidecar(extra: ["v": 2])) == nil)
        #expect(decode(sidecar(extra: ["v": true])) == nil)   // a bool is not a 1
        #expect(decode(sidecar(extra: ["v": "1"])) == nil)
        #expect(decode(#"[1,2]"#) == nil)
        #expect(decode("") == nil)
    }

    /// The file is joined to its session by its name. One that names another
    /// session, or another agent, is not this session's.
    @Test func aFileThatSaysItBelongsElsewhereIsNotRead() {
        #expect(decode(sidecar(), id: "other") == nil)
        #expect(decode(sidecar(extra: ["agent": "codex"])) == nil)
        #expect(decode(sidecar(extra: ["ts": 1e300])) == nil)       // no time, no freshness
        #expect(decode(sidecar(extra: ["ts": -5])) == nil)
    }

    @Test func numbersAreCheckedWhereTheyEnter() throws {
        let r = try #require(decode(sidecar(extra: [
            "context": ["percent": 140, "tokens": -3, "window": 1e300],
            "subagents": 1e12, "ended": 1,
            "rate_limits": [["kind": "five_hour", "percent_used": 130],
                            ["kind": "seven_day", "percent_used": -1],
                            ["kind": "bad kind!", "percent_used": 5],
                            ["kind": "x", "percent_used": "5"]],
        ])))
        #expect(r.context?.percent == 100)       // context is a share: clamped
        #expect(r.context?.tokens == nil)
        #expect(r.context?.window == nil)
        #expect(r.subagents == 999)
        #expect(!r.ended)                        // only `true` ends a session
        // A spend limit may pass 100 and says so; a negative or a word is not a reading.
        #expect(r.rateLimits.map(\.kind) == ["five_hour"])
        #expect(r.rateLimits.first?.percentUsed == 130)
    }

    @Test func aContextWithNothingInItIsNoContext() throws {
        let r = try #require(decode(sidecar(extra: ["context": ["percent": "high"]])))
        #expect(r.context == nil)
    }

    /// Only `allow` and `deny` are verdicts, and only `rule`, `mode`, `hook` and
    /// `auto` decide. Anything else costs that one decision, never the file.
    @Test func aDecisionThatIsNotOneIsDropped() throws {
        let r = try #require(decode(sidecar(decisions: [
            decision("a"), decision("b", verdict: "ask"), decision("c", by: "user"),
            decision("d", extra: ["id": ""]), decision("e", extra: ["tool": 5]),
            decision("f", extra: ["id": "has space"]), decision("g", verdict: "deny", by: "hook"),
            decision("h", by: "auto"), ["not": "a decision"],
        ])))
        #expect(r.decisions.map(\.id) == ["a", "g", "h"])
    }

    @Test func aHeldCallIsReadAndCapped() throws {
        let r = try #require(decode(sidecar(extra: ["held": ["tool": "Bash", "since": Self.now,
                                                             "input": ["command": "rm -r build\nsecond"]]])))
        #expect(r.held == .init(tool: "Bash", command: "rm -r build", since: Self.now))   // the first line: a label is one
        #expect(try #require(decode(sidecar(extra: ["held": ["tool": "Bash"]]))).held == nil)
        #expect(try #require(decode(sidecar(extra: ["held": "yes"]))).held == nil)
    }

    @Test func aRuleIsNamedOnlyWhenARuleDecided() throws {
        let r = try #require(decode(sidecar(decisions: [
            decision("a", by: "mode", extra: ["rule": "Bash(*)"]),
            decision("b", by: "rule", extra: ["rule": "Bash(npm test:*)\nsecond line"]),
        ])))
        #expect(r.decisions[0].rule == "")
        #expect(r.decisions[1].rule == "Bash(npm test:*)")
    }

    @Test func fieldsAreCappedAtWhatTheModKeeps() throws {
        let long = String(repeating: "x", count: 5_000)
        let r = try #require(decode(sidecar(decisions: [
            decision("a", extra: ["input": ["command": long, "file_path": long, "url": long,
                                            "description": long],
                                  "reason": long]),
        ])))
        let d = try #require(r.decisions.first)
        #expect(d.command.count == ModReport.maxField)
        #expect(d.filePath.count == ModReport.maxField)
        #expect(d.url.count == ModReport.maxField)
        #expect(d.description.count == ModReport.maxField)
        #expect(d.reason.count == ModReport.maxReason)
    }

    /// The ring holds 200; a file listing more loses the oldest, as the ring would.
    @Test func moreThanTheRingKeepsTheNewest() throws {
        let many = (0..<250).map { decision("t\($0)") }
        let r = try #require(decode(sidecar(decisions: many)))
        #expect(r.decisions.count == ModReport.maxDecisions)
        #expect(r.decisions.first?.id == "t50")
        #expect(r.decisions.last?.id == "t249")
    }

    @Test func anIdListedTwiceIsOneDecision() throws {
        let r = try #require(decode(sidecar(decisions: [decision("a"), decision("a", verdict: "deny")])))
        #expect(r.decisions.count == 1)
        #expect(r.decisions[0].verdict == "allow")
    }

    @Test func aDecisionWithoutATimeTakesTheFilesTime() throws {
        let r = try #require(decode(sidecar(decisions: [decision("a", extra: ["ts": "soon"])])))
        #expect(r.decisions[0].ts == Self.now)
    }
}
