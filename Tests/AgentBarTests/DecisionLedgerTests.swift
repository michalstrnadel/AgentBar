import Foundation
import Testing
@testable import AgentBar

/// The ledger of what the human decided. Most of these are about the two things it
/// must never do: claim a decision it did not witness, and keep an argument it was
/// never asked to keep.
///
/// Serialized: the on/off switch is one `UserDefaults` key shared by the whole
/// process, so a test that turns it off in parallel with one that writes makes the
/// writer fail for a reason that has nothing to do with it.
@Suite(.serialized) struct DecisionLedgerTests {
    private static let noon = Date(timeIntervalSince1970: 1_789_646_400)

    private func request(tool: String = "Bash", command: String? = "git status",
                         input: String = "{}", display: String = "Bash: git status",
                         filePath: String? = nil,
                         ts: TimeInterval = DecisionLedgerTests.noon.timeIntervalSince1970 - 30)
    -> ApprovalRequest {
        let context = command.map { #"{"kind":"bash","command":"\#($0)"}"# } ?? "null"
        let path = filePath.map { #""filePath":\#(quoted($0)),"# } ?? ""
        let json = """
        {"sessionId":"s1","agent":"claude","toolName":"\(tool)","display":"\(display)",\(path)
         "toolInputPretty":\(quoted(input)),"context":\(context),
         "pid":1,"hookPid":2,"ts":\(Int(ts))}
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("req-\(UUID().uuidString).json")
        try? json.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return ApprovalRequest(fileURL: url)!
    }

    private func quoted(_ s: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [s], options: []), encoding: .utf8)!
            .dropFirst().dropLast().description
    }

    private func ledgerFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-decisions-\(UUID().uuidString).jsonl")
    }

    // MARK: - The shape repeats are counted by

    /// A multiplexer's verb is its second word. Collapsing `git push` into `git`
    /// would count a status and a force-push as the same decision.
    @Test func multiplexersKeepTheirVerb() {
        #expect(DecisionLedger.verb(of: "git push origin main") == "git push")
        #expect(DecisionLedger.verb(of: "npm test") == "npm test")
        #expect(DecisionLedger.verb(of: "docker compose up -d") == "docker compose")
        #expect(DecisionLedger.verb(of: "ls -la /tmp") == "ls")
        #expect(DecisionLedger.verb(of: "/opt/homebrew/bin/rg pattern") == "rg")
    }

    /// The same command wearing a different hat is the same command.
    @Test func leadingNoiseIsStripped() {
        #expect(DecisionLedger.verb(of: "sudo apt-get install x") == "apt-get install")
        #expect(DecisionLedger.verb(of: "FOO=bar npm run build") == "npm run")
        #expect(DecisionLedger.verb(of: "env GIT_PAGER=cat git log") == "git log")
    }

    /// What follows a pipe or a chain is consequence, not the decision — and
    /// `echo hi && rm -rf /` must never be counted as `echo`'s well-behaved twin.
    @Test func onlyTheFirstCommandOfAChainCounts() {
        #expect(DecisionLedger.verb(of: "cat file | grep x") == "cat")
        #expect(DecisionLedger.verb(of: "make build && make test") == "make build")
    }

    /// Arguments never repeat, and they are where a path, a URL or a secret would
    /// be. The shape must carry none of them.
    @Test func theShapeCarriesNoArguments() {
        let shape = DecisionLedger.shape(of: request(command: "curl -H 'Authorization: Bearer sk-abc' https://x"))
        #expect(shape == "bash:curl")
        #expect(!shape.contains("sk-abc"))
        #expect(!shape.contains("https"))
    }

    /// An edit repeats by neighbourhood and file type, not by file name — and never
    /// by a full path, which is also somebody's home directory.
    @Test func editsCountByFolderAndExtension() {
        let r = request(tool: "Edit", command: nil,
                        input: #"{"file_path":"/Users/me/AgentBar/Sources/AgentBar/Weight.swift"}"#,
                        display: "Edit: Weight.swift")
        let shape = DecisionLedger.shape(of: r)
        #expect(shape == "edit:AgentBar/*.swift")
        #expect(!shape.contains("/Users/me"))
    }

    /// The hook cuts the tool input at 4 KB and a cut is not JSON, so a large edit
    /// used to lose its path and count as `tool:Edit` — out of reach of every
    /// `edit:` rule written for the same folder. The hook's own field keeps it.
    @Test func aLargeEditKeepsItsShape() {
        let cut = #"{"file_path":"/Users/me/AgentBar/Sources/AgentBar/Weight.swift","new_string":""#
            + String(repeating: "x", count: 5000) + "\n…"
        let r = request(tool: "Edit", command: nil, input: cut, display: "Edit: Weight.swift",
                        filePath: "/Users/me/AgentBar/Sources/AgentBar/Weight.swift")
        #expect(DecisionLedger.shape(of: r) == "edit:AgentBar/*.swift")
        // An older hook wrote no field; that request still falls back to parsing.
        let old = request(tool: "Edit", command: nil, input: cut, display: "Edit: Weight.swift")
        #expect(DecisionLedger.shape(of: old) == "tool:Edit")
    }

    @Test func anythingElseCountsByTool() {
        let r = request(tool: "WebFetch", command: nil, input: "{}", display: "WebFetch: example.com")
        #expect(DecisionLedger.shape(of: r) == "tool:WebFetch")
    }

    // MARK: - Counting

    private func record(_ decision: String, shape: String = "bash:git push",
                        cwd: String = "/repo", ts: TimeInterval = 0,
                        waited: TimeInterval = 0) -> DecisionLedger.Record {
        var r = DecisionLedger.Record()
        r.decision = decision
        r.shape = shape
        r.cwd = cwd
        r.ts = ts
        r.waited = waited
        return r
    }

    @Test func verdictsAreCountedAndHandOffsAreNot() {
        let rows = [record("allow"), record("always"), record("deny"),
                    record("defer"), record("answer")]
        let s = DecisionLedger.summary(shape: "bash:git push", cwd: "/repo", in: rows)
        #expect(s.allowed == 2)
        #expect(s.denied == 1)
        #expect(s.total == 3)   // defer is a hand-off, answer is a question
    }

    /// A command that is routine in one checkout can be the opposite in another.
    @Test func countsAreScopedToTheRepo() {
        let rows = [record("allow", cwd: "/repo"), record("allow", cwd: "/repo"),
                    record("allow", cwd: "/elsewhere")]
        #expect(DecisionLedger.summary(shape: "bash:git push", cwd: "/repo", in: rows).allowed == 2)
        #expect(DecisionLedger.summary(shape: "bash:git push", cwd: "", in: rows).allowed == 3)
    }

    /// "Allowed 1× here" is the thing you just did, and saying it would be noise on
    /// every first-time prompt.
    @Test func oneDecisionIsNotAHint() {
        let one = DecisionLedger.summary(shape: "bash:git push", cwd: "/repo", in: [record("allow")])
        #expect(DecisionLedger.hint(one) == nil)
        let two = DecisionLedger.summary(shape: "bash:git push", cwd: "/repo",
                                         in: [record("allow"), record("allow")])
        #expect(DecisionLedger.hint(two)?.hasPrefix("Allowed 2×") == true)
    }

    @Test func aMixedHistorySaysBothHalves() throws {
        let s = DecisionLedger.summary(shape: "bash:git push", cwd: "/repo",
                                       in: [record("allow"), record("allow"), record("deny")])
        let hint = try #require(DecisionLedger.hint(s))
        #expect(hint.contains("Allowed 2×"))
        #expect(hint.contains("denied 1×"))
    }

    /// The nudge appears only for a prompt allowed over and over and **never once
    /// refused** — and never without a rule Claude Code itself suggested, because
    /// there would be nothing for Always to persist.
    @Test func theAlwaysNudgeNeedsRepeatsAndACleanRecord() {
        let clean = DecisionLedger.summary(shape: "bash:git push", cwd: "",
                                           in: Array(repeating: record("allow"), count: 5))
        #expect(DecisionLedger.shouldPromoteAlways(clean, hasRule: true))
        #expect(!DecisionLedger.shouldPromoteAlways(clean, hasRule: false))

        var mixed = clean
        mixed.denied = 1
        #expect(!DecisionLedger.shouldPromoteAlways(mixed, hasRule: true))

        let few = DecisionLedger.summary(shape: "bash:git push", cwd: "",
                                         in: Array(repeating: record("allow"), count: 4))
        #expect(!DecisionLedger.shouldPromoteAlways(few, hasRule: true))
    }

    /// The other half of the day: how long agents sat blocked on the human.
    @Test func waitingAddsUpOverTheSpan() {
        let rows = [record("allow", ts: 100, waited: 30), record("deny", ts: 200, waited: 90),
                    record("allow", ts: 9_999, waited: 600)]
        let day = DecisionLedger.waiting(in: rows, since: 0, until: 1_000)
        #expect(day.answered == 2)
        #expect(day.waited == 120)
    }

    // MARK: - The file

    @Test func aDecisionRoundTripsThroughTheFile() throws {
        let url = ledgerFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = DecisionLedger(url: url)
        DecisionLedger.enabled = true
        ledger.record("allow", request: request(), session: nil,
                      now: Self.noon.timeIntervalSince1970)
        ledger.flush()

        let rows = DecisionLedger.read(url: url)
        #expect(rows.count == 1)
        #expect(rows[0].decision == "allow")
        #expect(rows[0].shape == "bash:git status")
        #expect(rows[0].waited == 30)      // the request was stamped 30s before
        #expect(rows[0].via == "app")
    }

    /// Nothing collapses here, unlike `history.jsonl`: two decisions about the same
    /// command are two decisions, and counting them is the whole point.
    @Test func repeatedDecisionsAllSurvive() throws {
        let url = ledgerFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = DecisionLedger(url: url)
        DecisionLedger.enabled = true
        for _ in 0..<3 {
            ledger.record("allow", request: request(), session: nil,
                          now: Self.noon.timeIntervalSince1970)
        }
        ledger.flush()
        #expect(DecisionLedger.read(url: url).count == 3)
    }

    /// The switch stops new rows immediately; it is the reason it exists.
    @Test func switchingItOffStopsWriting() throws {
        let url = ledgerFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = DecisionLedger(url: url)
        DecisionLedger.enabled = false
        defer { DecisionLedger.enabled = true }
        ledger.record("allow", request: request(), session: nil)
        ledger.flush()
        #expect(DecisionLedger.read(url: url).isEmpty)
    }

    /// …but not for a rule. The switch is about the human's clicks; an answer
    /// nobody clicked exists only on condition that it leaves a row naming the
    /// rule, and a watching rule with no rows could never be judged.
    @Test func aRuleFiringIsWrittenWithTheSwitchOff() throws {
        let url = ledgerFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = DecisionLedger(url: url)
        DecisionLedger.enabled = false
        defer { DecisionLedger.enabled = true }
        ledger.record("allow", request: request(), session: nil, via: "rule", rule: "r1")
        ledger.record("watch", request: request(), session: nil, via: "rule", rule: "r1",
                      would: "allow")
        ledger.flush()
        let rows = DecisionLedger.read(url: url)
        #expect(rows.map(\.decision) == ["allow", "watch"])
        #expect(rows.allSatisfy { $0.rule == "r1" })
    }

    /// A request with no timestamp contributes no wait rather than one measured
    /// from the epoch, which would put four decades into the day's total.
    @Test func aRequestWithoutATimestampContributesNoWait() throws {
        let url = ledgerFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = DecisionLedger(url: url)
        DecisionLedger.enabled = true
        ledger.record("allow", request: request(ts: 0), session: nil,
                      now: Self.noon.timeIntervalSince1970)
        ledger.flush()
        #expect(DecisionLedger.read(url: url).first?.waited == 0)
    }

    @Test func aTornLineCostsThatLineAndNothingElse() throws {
        let url = ledgerFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var good = DecisionLedger.Record()
        good.shape = "bash:ls"
        good.decision = "allow"
        DecisionLedger.append([good], to: url)
        try "{\"shape\":\"bash:incomp".appendLine(to: url)
        DecisionLedger.append([good], to: url)
        #expect(DecisionLedger.read(url: url).count == 2)
    }

    @Test func pruneDropsWhatIsPastItsAgeAndLeavesTheRestAlone() throws {
        let url = ledgerFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Self.noon.timeIntervalSince1970
        var old = DecisionLedger.Record()
        old.shape = "bash:ls"; old.decision = "allow"; old.ts = now - 40 * 86_400
        var fresh = old
        fresh.ts = now - 3_600
        DecisionLedger.append([old, fresh], to: url)
        DecisionLedger.prune(url: url, now: now)
        let kept = DecisionLedger.read(url: url)
        #expect(kept.count == 1)
        #expect(kept[0].ts == fresh.ts)
    }

    /// A row this version cannot read is not this version's to delete: prune used
    /// to rewrite the file from the rows it understood and drop the rest for good.
    @Test func pruneKeepsALineItCannotRead() throws {
        let url = ledgerFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Self.noon.timeIntervalSince1970
        var old = DecisionLedger.Record()
        old.shape = "bash:ls"; old.decision = "allow"; old.ts = now - 40 * 86_400
        DecisionLedger.append([old], to: url)
        let future = #"{"v":9,"ts":1,"kind":"something newer"}"#
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((future + "\n").utf8))
        try handle.close()
        DecisionLedger.prune(url: url, now: now)
        #expect(try String(contentsOf: url, encoding: .utf8) == future + "\n")
    }

    /// A hand-edited `ts` of `1e19` or NaN is read as no time: prune does `Int(ts)`
    /// on every row at launch, and one poisoned line must not trap it.
    @Test func aTimeThatIsNotATimeIsReadAsNone() throws {
        for ts in ["1e19", "-1e19"] {
            let line = #"{"v":1,"ts":\#(ts),"decision":"allow","shape":"bash:ls"}"#
            let row = try #require(DecisionLedger.Record(jsonLine: line))
            #expect(row.ts == 0)
            #expect(row.json["ts"] as? Int == 0)
        }
        let url = ledgerFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"v":1,"ts":1e19,"decision":"allow","shape":"bash:ls"}"#.utf8).write(to: url)
        DecisionLedger.prune(url: url, now: Self.noon.timeIntervalSince1970)
        #expect(DecisionLedger.read(url: url).isEmpty)
    }

    // MARK: - Handing the record to somebody else

    /// A record you cannot show anybody is only half a record, so it comes out as a
    /// spreadsheet. Oldest first, because that is the order it happened in.
    @Test func theExportIsOneRowPerDecisionOldestFirst() {
        var a = DecisionLedger.Record()
        a.ts = 1_789_646_500; a.agent = "codex"; a.cwd = "/repo"; a.tool = "Bash"
        a.shape = "bash:git status"; a.display = "Bash: git status"
        a.decision = "allow"; a.via = "app"; a.waited = 12
        var b = DecisionLedger.Record()
        b.ts = 1_789_646_400; b.agent = "claude"; b.decision = "watch"
        b.would = "allow"; b.via = "rule"; b.rule = "r-1"

        let lines = DecisionLedger.csv([a, b]).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0].hasPrefix("when,agent,directory"))
        #expect(lines[1].contains("\"claude\""))   // the older row first
        #expect(lines[2].contains("\"codex\""))
        #expect(lines[2].contains("\"bash:git status\""))
        #expect(lines[2].contains("\"12\""))
        // A watching rule's row is in the export and says what it would have done:
        // a week of that is exactly the evidence somebody would be asked for.
        #expect(lines[1].contains("\"watch\""))
        #expect(lines[1].contains("\"r-1\""))
    }

    /// The export carries commands an agent wanted to run. A spreadsheet reads a
    /// leading `=`, `+`, `-` or `@` as a formula to evaluate, so it is defused —
    /// handing somebody a file that runs their own agent's command on open is not
    /// a thing an audit trail does.
    @Test func theExportSurvivesBeingOpenedInASpreadsheet() {
        #expect(DecisionLedger.quoted("=cmd|'/bin/sh'!A1") == "\"'=cmd|'/bin/sh'!A1\"")
        #expect(DecisionLedger.quoted("+1") == "\"'+1\"")
        #expect(DecisionLedger.quoted("@x") == "\"'@x\"")
        // …and only at the start: a command that merely contains one is untouched.
        #expect(DecisionLedger.quoted("git log --oneline") == "\"git log --oneline\"")
        // Quotes, commas and newlines are ordinary CSV business.
        #expect(DecisionLedger.quoted("say \"hi\", now") == "\"say \"\"hi\"\", now\"")
        #expect(DecisionLedger.quoted("") == "\"\"")
    }

    /// `decisions.jsonl` is a file on somebody's disk that another tool can append
    /// to and a person can edit, and `1e19` is an ordinary JSON number that `Int(_:)`
    /// traps on rather than rounds. A wait longer than a year is not a wait, so the
    /// row is read as having none instead of taking the export down with it.
    @Test func aWaitNobodyCouldHaveWaitedIsReadAsNoWait() throws {
        let line = #"{"v":1,"ts":1789646400,"decision":"allow","shape":"bash:git status","waited":1e19}"#
        let row = try #require(DecisionLedger.Record(jsonLine: line))
        #expect(row.waited == 0)
        #expect(DecisionLedger.csv([row]).hasSuffix(",\"0\"\n"))
    }

    @Test func anOrdinaryWaitIsKept() throws {
        let line = #"{"v":1,"ts":1789646400,"decision":"allow","shape":"bash:git status","waited":42}"#
        let row = try #require(DecisionLedger.Record(jsonLine: line))
        #expect(row.waited == 42)
    }
}

private extension String {
    func appendLine(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((self + "\n").utf8))
    }
}
