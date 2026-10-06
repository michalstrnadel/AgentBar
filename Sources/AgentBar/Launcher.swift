import Cocoa

/// Starting a task, rather than starting an agent.
///
/// The menu's **Open** submenu has always been able to bring an agent forward; it
/// could never put it in a particular repository with a particular job. So this:
/// pick a project you have worked in, type what you want, press return. The agent
/// opens in a terminal, in that directory, with the prompt already given.
///
/// Two rules shape everything here.
///
/// **The prompt is never typed as keystrokes.** `KeystrokeApprover` exists for a
/// couple of fixed approval keys under strict frontmost checks; synthesising
/// arbitrary text into whatever happens to be in front is a foot-gun with somebody
/// else's shell on the other end. The prompt goes in as an argument, through one
/// escaper, or it does not go in at all.
///
/// **A half-started session is worse than an unstarted one.** Not every terminal
/// can be told to run a command — Warp has no scriptable way in — and not every
/// agent documents a prompt argument. Where either is missing, the launcher says
/// so: it opens the terminal at the directory and puts the exact command on the
/// clipboard for you to paste. Refusing out loud beats a window that opens on the
/// wrong thing.
enum Launcher {
    struct Task: Equatable {
        let agent: Agent
        let cwd: String
        let prompt: String

        static func == (a: Task, b: Task) -> Bool {
            a.agent.id == b.agent.id && a.cwd == b.cwd && a.prompt == b.prompt
        }
    }

    enum Outcome: Equatable {
        /// The terminal was asked to run it and agreed.
        case started
        /// Nothing here could start it; the command is on the clipboard and the
        /// terminal is open at the right place.
        case copied(String)
        /// The agent has no command-line tool on this machine at all.
        case noCLI
    }

    // MARK: - Building the command

    /// `["claude", "fix the auth bug"]` — the tool and, when the agent documents
    /// one, the prompt as a single argument.
    ///
    /// Only agents whose CLI actually takes a positional prompt get one. `copilot`
    /// and `opencode` document a prompt flag for their *non-interactive* modes,
    /// which is a different thing entirely, and guessing would start a session that
    /// exits immediately with the work undone.
    ///
    /// `using` is how the tool is found, injectable so the shape of the command can
    /// be tested on a machine that has none of these agents installed — which is
    /// every CI runner, and was how this first went red.
    static func argv(for task: Task,
                     using find: (String) -> String? = { resolve($0) }) -> [String]? {
        guard let cli = task.agent.cli, let tool = find(cli) else { return nil }
        let prompt = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.agent.takesPrompt, !prompt.isEmpty else { return [tool] }
        // A prompt starting with `-` is read as an option by the agent's own parser,
        // and every one of these CLIs has an option that widens what it may do. One
        // space in front keeps it a prompt to all of them; `--` is not read the same
        // way by every parser.
        return [tool, prompt.hasPrefix("-") ? " " + prompt : prompt]
    }

    /// One line a shell will run: into the directory, then the agent. Used where a
    /// terminal takes a command string rather than an argument vector.
    static func shellCommand(for task: Task,
                             using find: (String) -> String? = { resolve($0) }) -> String? {
        guard let argv = argv(for: task, using: find) else { return nil }
        return "cd " + quote(task.cwd) + " && " + argv.map(quote).joined(separator: " ")
    }

    /// POSIX single-quoting: everything between the quotes is literal, and the only
    /// character that needs care is the quote itself. This is the single place a
    /// prompt meets a shell, and it is why the prompt is never pasted into one
    /// anywhere else.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The agent's tool, if this machine has it. `PATH` as the app sees it is not
    /// the one a login shell has, so the usual places are checked by hand — the
    /// same approach `WorkDiff.tool` takes to finding git.
    static func resolve(_ cli: String, fileManager: FileManager = .default) -> String? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in dirs {
            let path = dir + "/" + cli
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - Starting it

    @discardableResult
    static func start(_ task: Task, terminal: TerminalApp) -> Outcome {
        guard let argv = argv(for: task), let shell = shellCommand(for: task) else {
            return .noCLI
        }
        if spawn(argv: argv, shell: shell, cwd: task.cwd, terminal: terminal) {
            return .started
        }
        // The honest fallback: the terminal opens where the work is, the command is
        // on the clipboard, and the caller says so out loud.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shell, forType: .string)
        terminal.open()
        return .copied(shell)
    }

    /// True when the terminal was asked to run the command and did not refuse.
    /// Every branch here is one terminal's own documented way in; anything else —
    /// and anything that fails — falls through to the clipboard.
    private static func spawn(argv: [String], shell: String, cwd: String,
                              terminal: TerminalApp) -> Bool {
        switch terminal.bundleID {
        case "com.apple.Terminal":
            // `do script` needs Automation consent, which macOS asks for once. A
            // refusal comes back as a non-zero exit and lands on the clipboard.
            return osascript("""
                tell application "Terminal"
                    activate
                    do script \(appleScriptString(shell))
                end tell
                """)
        case "com.googlecode.iterm2":
            return osascript("""
                tell application "iTerm"
                    activate
                    create window with default profile command \(appleScriptString("/bin/sh -lc " + quote(shell)))
                end tell
                """)
        case "com.mitchellh.ghostty":
            return run("/usr/bin/open", ["-na", "Ghostty", "--args",
                                         "--working-directory=\(cwd)", "-e"] + argv)
        case "com.github.wez.wezterm":
            guard let wezterm = resolve("wezterm") else { return false }
            return run(wezterm, ["start", "--cwd", cwd, "--"] + argv)
        case "net.kovidgoyal.kitty":
            return run("/usr/bin/open", ["-na", "kitty", "--args", "--directory", cwd] + argv)
        case "org.alacritty":
            return run("/usr/bin/open", ["-na", "Alacritty", "--args",
                                         "--working-directory", cwd, "-e"] + argv)
        default:
            // Warp among others: no documented way to hand it a command. Saying so
            // is the feature.
            return false
        }
    }

    private static func osascript(_ script: String) -> Bool {
        run("/usr/bin/osascript", ["-e", script], timeout: 60)   // first run waits on consent
    }

    /// AppleScript string literal: quotes and backslashes escaped, nothing else.
    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 15) -> Bool {
        // Reuses the one runner in the app that actually enforces a deadline —
        // AppleScript can block for a minute on the consent dialog, and an
        // `open -na` against a missing app can hang on a spinning launch service.
        WorkDiff.run(tool, args, in: NSTemporaryDirectory(), timeout: timeout) != nil
    }

    // MARK: - Where you have been working

    /// Projects worth offering, newest first: whatever is running now, then what
    /// the history remembers. Deduped by directory, and only directories that are
    /// still there — a launcher offering a folder somebody deleted last week is
    /// offering a failure.
    static func recentProjects(sessions: [Session], history: [HistoryStore.Record],
                               limit: Int = 6,
                               fileManager: FileManager = .default) -> [(project: String, cwd: String)] {
        var seen = Set<String>()
        var out: [(project: String, cwd: String)] = []
        func add(project: String, cwd: String) {
            guard !cwd.isEmpty, out.count < limit, seen.insert(cwd).inserted,
                  fileManager.fileExists(atPath: cwd)
            else { return }
            out.append((project.isEmpty ? (cwd as NSString).lastPathComponent : project, cwd))
        }
        for s in sessions { add(project: s.project, cwd: s.cwd) }
        for r in history.sorted(by: { $0.endedAt > $1.endedAt }) {
            add(project: r.project, cwd: r.cwd)
        }
        return out
    }

    /// The agents this machine can actually start, in the table's order. An agent
    /// with no tool installed is not an option, and offering it would be offering a
    /// dead end.
    static func launchableAgents() -> [Agent] {
        Agent.all.filter { $0.cli != nil && resolve($0.cli!) != nil }
    }
}
