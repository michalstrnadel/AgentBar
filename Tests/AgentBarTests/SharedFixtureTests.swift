import Foundation
import Testing
@testable import AgentBar

/// The app's half of every rule the Linux CLI implements a second time. Each fixture
/// under `Tests/Fixtures/` is language-neutral JSON that `Scripts/test/shared-fixtures.js`
/// (run by `Scripts/test/cli-test.sh`) reads too, against the CLI's own functions —
/// so the two halves cannot drift apart without one of the two suites going red. A
/// new case goes into the fixture, never into one side's test.
struct SharedFixtureTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    private static func load(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("\(name)/cases.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func cases(_ fixture: [String: Any]) -> [[String: Any]] {
        fixture["cases"] as? [[String: Any]] ?? []
    }

    private static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Rule matching and the live-command refusal table

    /// A case without `request` is a Bash request built from `command`, `cwd` and
    /// `agent` — the same expansion the CLI half makes.
    private static func request(of c: [String: Any]) -> [String: Any] {
        if let r = c["request"] as? [String: Any] { return r }
        return ["agent": c["agent"] as? String ?? "claude", "toolName": "Bash",
                "cwd": c["cwd"] as? String ?? "/work/proj",
                "context": ["kind": "bash", "command": c["command"] as? String ?? ""]]
    }

    /// The request file's bytes: `requestText` exactly when the case has one (the
    /// only way to put a character JSONSerialization drops in front of the reader),
    /// otherwise the request serialised.
    private static func approval(of c: [String: Any], in dir: URL) throws -> ApprovalRequest {
        let url = dir.appendingPathComponent("req-\(UUID().uuidString).json")
        if let text = c["requestText"] as? String {
            try Data(raw(text).utf8).write(to: url)
        } else {
            try JSONSerialization.data(withJSONObject: request(of: c)).write(to: url)
        }
        return try #require(ApprovalRequest(fileURL: url))
    }

    /// `$FEFF` is a U+FEFF that has to reach the file as it is. Written as an escape
    /// in the fixture it never would: JSONSerialization drops it while reading the
    /// fixture itself. The CLI half fills it the same way.
    static func raw(_ text: String) -> String {
        text.replacingOccurrences(of: "$FEFF", with: "\u{FEFF}")
    }

    @Test func ruleMatchingAgreesWithTheFixture() throws {
        let fixture = try Self.load("rule-matching")
        let classes = try #require(fixture["refusals"] as? [String: String])
        let sets = try #require(fixture["rulesets"] as? [String: [[String: Any]]])
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Every rule set is a file the app would apply, or the cases prove nothing.
        var rulesets: [String: [RulesStore.Rule]] = [:]
        for (name, rules) in sets {
            let url = dir.appendingPathComponent("\(name).json")
            try JSONSerialization.data(withJSONObject: ["v": 1, "rules": rules]).write(to: url)
            let load = RulesStore.load(url: url)
            guard case .rules(let parsed) = load else {
                Issue.record("rule set \(name) does not load: \(load)"); continue
            }
            rulesets[name] = parsed
        }

        func refusalClass(_ reason: String?) -> String? {
            guard let reason else { return nil }
            if reason.hasPrefix("`"), reason.hasSuffix("` is never approved by a rule") {
                return "never:" + reason.dropFirst().prefix { $0 != "`" }
            }
            return classes.first { reason.hasPrefix($0.value) }?.key ?? "unclassified: \(reason)"
        }

        let all = Self.cases(fixture)
        #expect(all.count > 60)
        for c in all {
            let name = c["name"] as? String ?? "?"
            let expect = try #require(c["expect"] as? [String: Any])
            let rules = try #require(rulesets[c["rules"] as? String ?? ""], "\(name): no rule set")
            let req = try Self.approval(of: c, in: dir)

            #expect(DecisionLedger.shape(of: req) == expect["shape"] as? String, "\(name): shape")
            let verdict = RuleEngine.verdict(for: req, cwd: req.cwd, rules: rules)
            let answers = verdict?.rule.answers == true
            #expect((answers ? verdict?.behavior : "none") == expect["answer"] as? String, "\(name): answer")
            #expect((answers ? nil : verdict?.behavior) == expect["would"] as? String, "\(name): would")
            #expect(verdict?.rule.id == expect["rule"] as? String, "\(name): rule")
            #expect(refusalClass(RuleEngine.refusal(for: req, cwd: req.cwd)) == expect["refusal"] as? String,
                    "\(name): refusal")
        }
    }

    // MARK: - The rules file, whole-file refusals included

    @Test func rulesFileReadingAgreesWithTheFixture() throws {
        let fixture = try Self.load("rules-file")
        let classes = try #require(fixture["classes"] as? [String: [String: String]])
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for (i, c) in Self.cases(fixture).enumerated() {
            let name = c["name"] as? String ?? "?"
            let expect = try #require(c["expect"] as? [String: Any])
            let url = dir.appendingPathComponent("rules-\(i).json")
            if let text = c["file"] as? String { try Data(Self.raw(text).utf8).write(to: url) }
            let load = RulesStore.load(url: url)
            switch (expect["state"] as? String, load) {
            case ("none", .none):
                break
            case ("rules", .rules(let rules)):
                #expect(rules.map(\.id) == expect["ids"] as? [String], "\(name): ids")
            case ("invalid", .invalid(let why)):
                let cls = expect["class"] as? String ?? ""
                let needle = try #require(classes[cls]?["swift"], "\(name): unknown class \(cls)")
                #expect(why.contains(needle), "\(name): expected \(cls), got “\(why)”")
            default:
                Issue.record("\(name): expected \(expect["state"] ?? "?"), got \(load)")
            }
        }
    }

    // MARK: - wire-disabled

    @Test func wireDisabledReadingAgreesWithTheFixture() throws {
        for c in Self.cases(try Self.load("wire-disabled")) {
            let name = c["name"] as? String ?? "?"
            let home = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            if let text = c["file"] as? String {
                try FileManager.default.createDirectory(at: home.appendingPathComponent(".agentbar"),
                                                        withIntermediateDirectories: true)
                try Data(Self.raw(text).utf8).write(to: WiringPrefs.url(home: home))
            }
            #expect(WiringPrefs.load(home: home).sorted() == c["ids"] as? [String], "\(name)")
        }
    }

    // MARK: - Unwiring one agent

    /// One shape for comparing JSON: what the file holds, not how it is spaced.
    private static func canonical(_ object: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: object,
                                     options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private static func backups(of url: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.filter { $0.hasPrefix(url.lastPathComponent + ConfigBackup.marker) }
    }

    @Test func unwiringAgreesWithTheFixture() throws {
        for c in Self.cases(try Self.load("unwire")) {
            let name = c["name"] as? String ?? "?"
            let agent = try #require(c["agent"] as? String)
            let files = try #require(c["files"] as? [String: String])
            let expect = try #require(c["expect"] as? [String: [String: Any]])
            let home = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            for (rel, text) in files {
                let url = home.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            // An empty environment: the runner's own CLAUDE_CONFIG_DIR or COPILOT_HOME
            // must never reach a pass (HookInstallerTests says why).
            let ctx = HookInstaller.Context(home: home, environment: [:], node: "/opt/homebrew/bin/node",
                                            log: home.appendingPathComponent(".agentbar/config-changes.json"),
                                            disabled: [agent])
            _ = HookInstaller.runPass(ctx, preview: false, only: agent)

            for (rel, want) in expect {
                let url = home.appendingPathComponent(rel)
                let now = try? Data(contentsOf: url)
                let kept = Self.backups(of: url)
                if want["unchanged"] as? Bool == true {
                    #expect(now == files[rel].map { Data($0.utf8) }, "\(name): \(rel) was rewritten")
                    #expect(kept.isEmpty, "\(name): \(rel) was backed up for nothing")
                } else if want["removed"] as? Bool == true {
                    #expect(now == nil, "\(name): \(rel) is still there")
                    #expect(kept.count == 1, "\(name): \(rel) was not kept first")
                } else if let text = want["text"] as? String {
                    #expect(now.map { String(decoding: $0, as: UTF8.self) } == text, "\(name): \(rel)")
                    #expect(kept.count == 1, "\(name): \(rel) was not kept first")
                } else if let json = want["json"] {
                    let parsed = now.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                    #expect(parsed.flatMap(Self.canonical) == Self.canonical(json), "\(name): \(rel)")
                    #expect(kept.count == 1, "\(name): \(rel) was not kept first")
                } else {
                    Issue.record("\(name): \(rel) expects nothing the test knows")
                }
            }
        }
    }

    // MARK: - Session rows

    @Test func sessionRowsAgreeWithTheFixture() throws {
        let now = Int(Date().timeIntervalSince1970)
        let live = Int(ProcessInfo.processInfo.processIdentifier)
        for c in Self.cases(try Self.load("session-rows")) {
            let name = c["name"] as? String ?? "?"
            let expect = try #require(c["expect"] as? [String: Any])
            let row = Self.filled(try #require(c["row"] as? String), now: now, live: live)
            let dir = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("row.json")
            try Data(row.utf8).write(to: url)

            // SessionStore.refresh, decision for decision: unreadable is skipped and
            // left; not live is deleted; never started is left and not listed.
            let session = Session(fileURL: url)
            let kept = session.map(SessionStore.isLive) ?? true
            let visible = kept && session?.started == true
            #expect(kept == expect["kept"] as? Bool, "\(name): kept")
            #expect(visible == expect["visible"] as? Bool, "\(name): visible")
            #expect((session?.agentName ?? "") == expect["agentName"] as? String, "\(name): agentName")
        }
    }

    /// `$LIVE`, `$DEAD`, `$NOW` and `$NOW-N`, exactly as the CLI half fills them.
    static func filled(_ row: String, now: Int, live: Int) -> String {
        var out = row.replacingOccurrences(of: "$LIVE", with: "\(live)")
            .replacingOccurrences(of: "$DEAD", with: "999999")
        while let r = out.range(of: #"\$NOW-[0-9]+"#, options: .regularExpression) {
            let ago = Int(out[r].dropFirst("$NOW-".count)) ?? 0
            out.replaceSubrange(r, with: "\(now - ago)")
        }
        return out.replacingOccurrences(of: "$NOW", with: "\(now)")
    }
}
