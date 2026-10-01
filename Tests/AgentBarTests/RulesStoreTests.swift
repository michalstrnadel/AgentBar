import Foundation
import Testing
@testable import AgentBar

/// `rules.json` is a document a person edits by hand, so most of these are about
/// what happens when they get it wrong — and the answer is always the same: the
/// whole file is refused, loudly, and every prompt comes back to them.
@Suite struct RulesStoreTests {
    private func file() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-rules-\(UUID().uuidString).json")
    }

    private func write(_ text: String, to url: URL) {
        try? text.data(using: .utf8)!.write(to: url)
    }

    @Test func noFileIsTheOrdinaryState() {
        #expect(RulesStore.load(url: file()) == .none)
    }

    @Test func aRuleSurvivesARoundTrip() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let rule = RulesStore.Rule(id: "r-abc123", decision: "allow", shape: "bash:git status",
                                   cwd: "/repo", note: "read-only", created: 1_789_646_400)
        #expect(RulesStore.save([rule], to: url))
        #expect(RulesStore.load(url: url) == .rules([rule]))
    }

    @Test func savingTwiceReplacesRatherThanAppends() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = RulesStore.Rule(id: "r-a", decision: "deny", shape: "bash:curl")
        let b = RulesStore.Rule(id: "r-b", decision: "deny", shape: "bash:wget")
        #expect(RulesStore.save([a], to: url))
        #expect(RulesStore.save([a, b], to: url))
        #expect(RulesStore.load(url: url).rules.count == 2)
    }

    // MARK: - Refusals, each one whole-file

    @Test func junkIsRefused() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        write("{ not json", to: url)
        guard case .invalid(let why) = RulesStore.load(url: url) else {
            Issue.record("expected a refusal"); return
        }
        #expect(why.contains("not valid JSON"))
    }

    /// A file from a newer AgentBar may carry a field that NARROWS a rule. Reading
    /// it while ignoring that field would apply a wider rule than the person wrote.
    /// **F16**, the other half: a file from a later build is refused whole.
    @Test func aNewerVersionIsRefusedRatherThanGuessedAt() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        write(#"{"v":2,"rules":[]}"#, to: url)
        guard case .invalid(let why) = RulesStore.load(url: url) else {
            Issue.record("expected a refusal"); return
        }
        #expect(why.contains("version 2"))
    }

    /// The asymmetry that is the whole safety posture: a denial may cover the
    /// machine, an approval names one directory.
    @Test func anApprovalWithoutADirectoryIsRefused() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        write(#"{"v":1,"rules":[{"id":"r-1","decision":"allow","shape":"bash:git status"}]}"#, to: url)
        guard case .invalid(let why) = RulesStore.load(url: url) else {
            Issue.record("expected a refusal"); return
        }
        #expect(why.contains("must name one"))
    }

    @Test func aDenialWithoutADirectoryIsFine() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        write(#"{"v":1,"rules":[{"id":"r-1","decision":"deny","shape":"bash:curl"}]}"#, to: url)
        #expect(RulesStore.load(url: url).rules.count == 1)
    }

    /// One bad rule refuses the file. Applying the rest would leave a person
    /// believing they wrote four rules while three are in force, with nothing on
    /// screen saying which — worse than no rules at all.
    @Test func oneBadRuleRefusesTheWholeFile() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        write("""
        {"v":1,"rules":[
          {"id":"r-1","decision":"deny","shape":"bash:curl"},
          {"id":"r-2","decision":"maybe","shape":"bash:git status"}
        ]}
        """, to: url)
        guard case .invalid(let why) = RulesStore.load(url: url) else {
            Issue.record("expected a refusal"); return
        }
        #expect(why.contains("r-2"))
        #expect(RulesStore.load(url: url).rules.isEmpty)
    }

    @Test func aRepeatedIdIsRefused() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        write("""
        {"v":1,"rules":[
          {"id":"r-1","decision":"deny","shape":"bash:curl"},
          {"id":"r-1","decision":"deny","shape":"bash:wget"}
        ]}
        """, to: url)
        guard case .invalid(let why) = RulesStore.load(url: url) else {
            Issue.record("expected a refusal"); return
        }
        #expect(why.contains("repeats an `id`"))
    }

    @Test func aRelativeDirectoryIsRefused() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        write(#"{"v":1,"rules":[{"id":"r-1","decision":"allow","shape":"bash:ls","cwd":"repo"}]}"#,
              to: url)
        guard case .invalid(let why) = RulesStore.load(url: url) else {
            Issue.record("expected a refusal"); return
        }
        #expect(why.contains("absolute"))
    }

    /// The engine compares directories as text: a trailing slash would never match,
    /// and `..` would name a directory nobody wrote. Refused, with the plain spelling.
    @Test func aDirectoryNotWrittenPlainlyIsRefused() {
        for cwd in ["/x/repo/", "/x//repo", "/x/./repo", "/x/repo/../other"] {
            let url = file()
            defer { try? FileManager.default.removeItem(at: url) }
            write(#"{"v":1,"rules":[{"id":"r-1","decision":"allow","shape":"bash:ls","cwd":"\#(cwd)"}]}"#,
                  to: url)
            guard case .invalid(let why) = RulesStore.load(url: url) else {
                Issue.record("expected a refusal for \(cwd)"); continue
            }
            #expect(why.contains("not written plainly"))
        }
        #expect(RulesStore.normalisedCwd("/x/repo/../other") == "/x/other")
        #expect(RulesStore.normalisedCwd("/") == "/")
        #expect(RulesStore.validate(RulesStore.Rule(id: "a", decision: "allow", shape: "s",
                                                    cwd: "/x/repo"), index: 0, seen: []) == nil)
    }

    /// `json` writes `Int(created)`; a hand-edited `1e19` must not trap the next save.
    @Test func aCreatedTimeThatIsNotATimeIsReadAsNone() throws {
        let rule = try #require(RulesStore.Rule(json: ["id": "r-1", "decision": "deny",
                                                       "shape": "bash:curl", "created": 1e19]))
        #expect(rule.created == 0)
        #expect(rule.json["created"] as? Int == 0)
    }

    @Test func aMissingFieldIsRefusedByName() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        write(#"{"v":1,"rules":[{"decision":"deny","shape":"bash:curl"}]}"#, to: url)
        guard case .invalid(let why) = RulesStore.load(url: url) else {
            Issue.record("expected a refusal"); return
        }
        #expect(why.contains("`id`"))
    }

    // MARK: - The three modes

    @Test func aModeSurvivesARoundTrip() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let watching = RulesStore.Rule(id: "r-w", decision: "allow", shape: "bash:ls",
                                       cwd: "/repo", mode: .watch, created: 1)
        #expect(RulesStore.save([watching], to: url))
        #expect(RulesStore.load(url: url).rules.first?.mode == .watch)
    }

    /// A file written by hand without the field is the ordinary case, and the
    /// ordinary case is a rule that works.
    @Test func aMissingModeMeansAnswering() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        write(#"{"v":1,"rules":[{"id":"r-1","decision":"deny","shape":"bash:curl"}]}"#, to: url)
        #expect(RulesStore.load(url: url).rules.first?.mode == .on)
    }

    /// A typo in `mode` must not be read as "answering". It refuses the file — the
    /// one direction a guess is not allowed to go.
    /// **F17** of the fall-through contract in `SECURITY.md`: a mode nobody can
    /// read is never read as "answering".
    @Test func anUnreadableModeRefusesTheFile() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        write(#"{"v":1,"rules":[{"id":"r-1","decision":"deny","shape":"bash:curl","mode":"yes"}]}"#,
              to: url)
        guard case .invalid(let why) = RulesStore.load(url: url) else {
            Issue.record("expected a refusal"); return
        }
        #expect(why.contains("mode: yes"))
        #expect(RulesStore.load(url: url).rules.isEmpty)
    }

    @Test func onlyAnAnsweringRuleAnswers() {
        #expect(RulesStore.Rule(id: "a", decision: "allow", shape: "s", cwd: "/r", mode: .on).answers)
        #expect(!RulesStore.Rule(id: "a", decision: "allow", shape: "s", cwd: "/r", mode: .watch).answers)
        #expect(!RulesStore.Rule(id: "a", decision: "allow", shape: "s", cwd: "/r", mode: .off).answers)
    }

    @Test func idsAreShortAndDistinct() {
        let ids = (0..<200).map { _ in RulesStore.newID() }
        #expect(ids.allSatisfy { $0.hasPrefix("r-") && $0.count == 8 })
        #expect(Set(ids).count > 190)   // collisions are possible, a flood of them is a bug
    }
}
