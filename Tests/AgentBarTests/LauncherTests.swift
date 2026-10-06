import Foundation
import Testing
@testable import AgentBar

/// Starting a task. The prompt is the only place in this app where something a
/// person typed meets a shell, so most of this is about that meeting.
@Suite struct LauncherTests {
    private func agent(_ id: String) -> Agent { Agent.byID(id) }
    /// A stand-in for "the tool is installed". None of these agents exist on a CI
    /// runner, and the shape of the command is worth testing anyway.
    private let anywhere: (String) -> String? = { "/opt/agents/" + $0 }

    // MARK: - Quoting

    /// POSIX single-quoting: everything inside is literal, and the quote itself is
    /// the only character that needs care.
    @Test func quotingSurvivesTheThingsPeopleType() {
        #expect(Launcher.quote("fix the bug") == "'fix the bug'")
        #expect(Launcher.quote("it's broken") == "'it'\\''s broken'")
        #expect(Launcher.quote("delete $HOME") == "'delete $HOME'")
        #expect(Launcher.quote("`whoami`") == "'`whoami`'")
        #expect(Launcher.quote("a\"b") == "'a\"b'")
    }

    /// The one that matters, and it is checked by **asking a real shell** rather
    /// than by looking at the string: whatever a person types has to come back out
    /// of `/bin/sh` as one argument, byte for byte, and never as a command.
    @Test func aPromptCannotEscapeIntoTheShell() throws {
        for prompt in ["'; echo pwned; echo '", "$(id)", "`id`", "a\"b", "it's",
                       "two\nlines", "back\\slash", "~/$PATH"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "printf %s " + Launcher.quote(prompt)]
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            #expect(String(decoding: data, as: UTF8.self) == prompt)
        }
    }

    @Test func theCommandStartsByEnteringTheDirectory() throws {
        let task = Launcher.Task(agent: agent("claude"), cwd: "/tmp", prompt: "hi")
        let line = try #require(Launcher.shellCommand(for: task, using: anywhere))
        #expect(line.hasPrefix("cd '/tmp' && "))
    }

    @Test func theDirectoryIsQuotedToo() throws {
        let task = Launcher.Task(agent: agent("claude"),
                                 cwd: "/Users/me/Documents/Macbook M3/Warp/AgentBar",
                                 prompt: "hi")
        let line = try #require(Launcher.shellCommand(for: task, using: anywhere))
        #expect(line.hasPrefix("cd '/Users/me/Documents/Macbook M3/Warp/AgentBar' &&"))
    }

    // MARK: - Which agents get the prompt

    /// Each `takesPrompt` was read out of the tool's own `--help`. The ones that
    /// only document a prompt flag for their non-interactive mode get nothing:
    /// guessing would start a session that runs once and exits with the work half
    /// done.
    @Test func onlyVerifiedAgentsAreHandedThePrompt() {
        #expect(agent("claude").takesPrompt)
        #expect(agent("codex").takesPrompt)
        #expect(agent("cursor").takesPrompt)
        #expect(agent("gemini").takesPrompt)
        #expect(!agent("copilot").takesPrompt)
        #expect(!agent("opencode").takesPrompt)
        #expect(!agent("qwen").takesPrompt)
    }

    /// An agent that only exists as an app or in somebody's cloud has no command
    /// line to start, and the launcher must not offer one.
    @Test func agentsWithNoCommandLineAreNotOffered() {
        #expect(agent("antigravity").cli == nil)
        #expect(agent("devin").cli == nil)
        #expect(!Launcher.launchableAgents().contains { $0.id == "devin" })
    }

    /// An agent that takes no prompt still starts — in the right directory, with
    /// the prompt left for the person to type where the agent can hear it.
    @Test func anAgentWithoutAPromptArgumentStillOpens() throws {
        let task = Launcher.Task(agent: agent("copilot"), cwd: "/tmp", prompt: "do the thing")
        let argv = try #require(Launcher.argv(for: task, using: anywhere))
        #expect(argv == ["/opt/agents/copilot"])

        let claude = Launcher.Task(agent: agent("claude"), cwd: "/tmp", prompt: "do the thing")
        #expect(Launcher.argv(for: claude, using: anywhere)
                == ["/opt/agents/claude", "do the thing"])
    }

    /// A prompt that starts with `-` is an option to the agent's own parser.
    @Test func aPromptThatLooksLikeAnOptionStaysAPrompt() throws {
        let task = Launcher.Task(agent: agent("claude"), cwd: "/tmp", prompt: "--dangerously-skip-permissions")
        #expect(Launcher.argv(for: task, using: anywhere)
                == ["/opt/agents/claude", " --dangerously-skip-permissions"])
    }

    /// Only http(s) and the vendors' own schemes open from a row.
    @Test func aRowOpensOnlyTheSchemesOnTheList() throws {
        for ok in ["https://app.devin.ai/s/1", "cursor://anysphere.cursor-deeplink/x", "ssh://box"] {
            #expect(AgentActions.openableCloudURL(try #require(URL(string: ok))), "\(ok)")
        }
        for bad in ["file:///etc/passwd", "x-man-page://ls", "applescript://x", "vnc://h", "ftp://h"] {
            #expect(!AgentActions.openableCloudURL(try #require(URL(string: bad))), "\(bad)")
        }
    }

    // MARK: - Recent projects

    private func record(_ project: String, cwd: String, ended: TimeInterval)
    -> HistoryStore.Record {
        let json = #"{"agent":"claude","sessionId":"\#(project)","project":"\#(project)","state":"done","cwd":"\#(cwd)","endedAt":\#(Int(ended))}"#
        return HistoryStore.Record(jsonLine: json)!
    }

    /// Newest first, one row per directory, and nothing that is no longer there —
    /// offering a folder somebody deleted last week is offering a failure.
    @Test func recentProjectsAreDedupedAndStillOnDisk() throws {
        let tmp = NSTemporaryDirectory()
        let gone = tmp + "/agentbar-gone-\(UUID().uuidString)"
        let rows = [record("Old", cwd: tmp, ended: 100),
                    record("Same", cwd: tmp, ended: 200),
                    record("Gone", cwd: gone, ended: 300)]
        let out = Launcher.recentProjects(sessions: [], history: rows)
        #expect(out.count == 1)
        #expect(out[0].cwd == tmp)
        #expect(out[0].project == "Same")     // the newer of the two rows for it
    }

    @Test func aProjectWithNoNameFallsBackToItsFolder() throws {
        let out = Launcher.recentProjects(sessions: [],
                                          history: [record("", cwd: "/tmp", ended: 1)])
        #expect(out.first?.project == "tmp")
    }

    // MARK: - Resolving the tool

    @Test func aToolThatIsNotInstalledResolvesToNothing() {
        #expect(Launcher.resolve("definitely-not-a-real-agent-cli") == nil)
    }

    @Test func anInstalledToolResolvesToItsPath() throws {
        let path = try #require(Launcher.resolve("ls"))
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }

    /// AppleScript literals need their own escaping, and a prompt with a quote in
    /// it reaches one on the Terminal.app path.
    @Test func appleScriptLiteralsAreEscaped() {
        #expect(Launcher.appleScriptString("say \"hi\"") == "\"say \\\"hi\\\"\"")
        #expect(Launcher.appleScriptString("back\\slash") == "\"back\\\\slash\"")
    }
}
