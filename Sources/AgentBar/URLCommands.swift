import Cocoa

/// `agentbar://` — the way Shortcuts, Raycast, Alfred and a shell script drive
/// AgentBar without a keystroke of their own.
///
/// **Any web page can open one of these links.** A browser asks once before it
/// hands a scheme to an app, people click "Always allow", and from then on a
/// hidden iframe on a page somebody was sent can fire `agentbar://…` as often as
/// it likes. So the scheme is built from what such a page may be allowed to do,
/// not from what a script author would find convenient:
///
/// - It **shows** things: a window, a page of Settings, the launcher, the session
///   that is waiting. Every one of those is something the person could have
///   clicked their way to, and every one of them waits for the person.
/// - It **never** approves, denies, answers a question, writes or edits a rule,
///   changes a setting, or runs a command. There is no host for any of that, and
///   the parser's job is to make sure there never quietly becomes one: anything it
///   does not recognise exactly is `nil`, and `nil` does nothing at all. Rule 3 in
///   `CLAUDE.md` — AgentBar answers nothing by itself — would mean little if a link
///   could answer on the person's behalf.
/// - `new-task` is the one that comes closest, and it stops short on purpose: it
///   opens the launcher **filled in**, and the person still presses Return. A link
///   that could start an agent in a directory of its choosing with a prompt of its
///   choosing is a link that runs code on this Mac. The launcher also says that
///   what is in it came from a link, so a prompt nobody typed is read before it is
///   sent.
///
/// A malformed or unknown URL is dropped with one `NSLog` line and nothing on
/// screen. A beep or an alert would be a way for a web page to make this Mac beep
/// or throw up dialogs, which is its own small attack.
enum URLCommands {
    /// What a link may ask for. Four things, all of them "show me", none of them
    /// "do it". A case added here is a case any web page can reach — see the top of
    /// this file before adding one.
    enum Command: Equatable {
        /// The session that most needs you, or a named one. `nil` means "pick".
        case focus(session: String?)
        /// The launcher, filled in, waiting for Return.
        case newTask(Prefill)
        /// Settings, on a page when one is named.
        case settings(page: SettingsWindow.Page?)
        case welcome
    }

    /// What a link may put in the launcher. Every field is optional: a link that
    /// names only a prompt leaves the project and agent to the launcher's own
    /// defaults.
    struct Prefill: Equatable {
        var cwd: String?
        var agent: String?
        var prompt: String?
    }

    static let scheme = "agentbar"

    /// Longer than anybody types into a one-line launcher, and short enough that a
    /// link cannot hide a second screenful behind the first — the field shows one
    /// line, and what it does not show is what nobody reads before pressing Return.
    /// A prompt over it refuses the whole link rather than being cut: a prompt cut
    /// in half is a different prompt, and nobody asked for that one.
    static let maxPrompt = 2_000
    /// Session ids are short (`codex-<uuid>` is the longest shape any writer uses);
    /// this is the same ceiling the hooks cut an id to, with room to spare.
    static let maxSessionID = 128
    /// A path no real checkout reaches, and a bound on how much a link can make
    /// the file system look at.
    static let maxPath = 1_024

    // MARK: - Parsing (pure)

    /// URL → command, or `nil` for anything that is not exactly one of the four.
    ///
    /// Strict in the ways that matter and nowhere else: the scheme and the host
    /// must be ours, there is no user, password, port or fragment, a path appears
    /// only where a page is named, and a query key appears at most once. Keys a
    /// command does not read are ignored rather than refused, because none of them
    /// can do anything — there is no `approve=1` to honour, so there is nothing to
    /// guard against in seeing one.
    ///
    /// `isDirectory` is how `cwd` is checked, injectable so the tests can say what
    /// exists without touching the disk.
    static func parse(_ url: URL,
                      isDirectory: (String) -> Bool = URLCommands.isExistingDirectory) -> Command? {
        guard url.scheme?.lowercased() == scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil,
              let host = parts.host?.lowercased(), !host.isEmpty
        else { return nil }

        // Duplicate keys are refused, not resolved: which of two `cwd`s wins is
        // exactly the kind of question an attacker gets to pick the answer to.
        var query: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard query[item.name] == nil else { return nil }
            query[item.name] = item.value ?? ""
        }
        // `agentbar://focus/` is the same link as `agentbar://focus`; anything
        // longer is a path, and only Settings has a use for one.
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        switch host {
        case "focus":
            guard path.isEmpty else { return nil }
            guard let raw = query["session"] else { return .focus(session: nil) }
            guard let id = sessionID(raw) else { return nil }
            return .focus(session: id)

        case "new-task":
            guard path.isEmpty else { return nil }
            var prefill = Prefill()
            if let raw = query["cwd"] {
                guard let cwd = directory(raw, isDirectory: isDirectory) else { return nil }
                prefill.cwd = cwd
            }
            if let raw = query["agent"] {
                guard let agent = agentID(raw) else { return nil }
                prefill.agent = agent
            }
            if let raw = query["prompt"] {
                guard let prompt = prompt(raw) else { return nil }
                prefill.prompt = prompt
            }
            return .newTask(prefill)

        case "settings":
            switch path.count {
            case 0: return .settings(page: nil)
            case 1:
                guard let page = SettingsWindow.Page(rawValue: path[0].lowercased()) else { return nil }
                return .settings(page: page)
            default: return nil
            }

        // The window the menu calls Appearance, by either name.
        case "welcome", "appearance":
            guard path.isEmpty else { return nil }
            return .welcome

        default:
            // `approve`, `deny`, `answer`, `rule`, `run`, `set` — and everything else
            // anybody thinks of. There is no host that decides anything.
            return nil
        }
    }

    /// A session id is only ever compared against the ids of rows on screen, so it
    /// cannot reach anything by itself — but it is still kept to the characters
    /// the writers use, so a link cannot carry a path or a control character into
    /// a log line.
    static func sessionID(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= maxSessionID,
              raw.unicodeScalars.allSatisfy({ allowedID.contains($0) }) else { return nil }
        return raw
    }

    /// Agent ids are the table's own (`claude`, `codex`, …). An id that is well
    /// formed but not installed is dropped later, by the launcher, which is the one
    /// that knows what is installed.
    static func agentID(_ raw: String) -> String? {
        let id = raw.lowercased()
        guard !id.isEmpty, id.count <= 32,
              id.unicodeScalars.allSatisfy({ allowedAgent.contains($0) }) else { return nil }
        return id
    }

    /// An absolute path to a directory that exists, spelled plainly.
    ///
    /// Plainly means no `.` or `..` component and nothing a shell or a terminal
    /// would read differently from the file system: a link has no business naming
    /// `/Users/you/project/../../..`, even though it resolves, because what the
    /// launcher shows the person should be where the agent will actually start.
    /// A trailing slash is dropped so the same folder is the same string. `~` is
    /// refused — it is not absolute, and expanding it is a guess about whose home.
    static func directory(_ raw: String, isDirectory: (String) -> Bool) -> String? {
        guard raw.hasPrefix("/"), raw.count <= maxPath,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        // Index 0 is the empty string before the leading slash; an empty one later
        // is a doubled slash, which is refused along with the dots.
        for (i, c) in components.enumerated() where i > 0 {
            if c == "." || c == ".." { return nil }
            if c.isEmpty && i != components.count - 1 { return nil }
        }
        var path = raw
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard isDirectory(path) else { return nil }
        return path
    }

    /// The prompt as the launcher's field will show it.
    ///
    /// Control characters become spaces — the field is one line, and a newline in
    /// it would hide everything after it. Invisible format characters (right-to-left
    /// overrides, zero-width joiners) are removed outright: they are how a string
    /// is made to *read* differently from what it *says*, and the one thing the
    /// person has to go on before pressing Return is what it reads. Nothing here
    /// tries to judge the content; `javascript:` or `rm -rf` in a prompt are just
    /// words in a text field, and the launcher never hands them to a shell except
    /// as one quoted argument (`Launcher.quote`).
    static func prompt(_ raw: String) -> String? {
        guard raw.count <= maxPrompt else { return nil }
        var out = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                // `controlCharacters` includes the Cf format class; those vanish,
                // true control characters (Cc) become a space.
                if scalar.properties.generalCategory == .control { out.append(" ") }
                continue
            }
            out.append(scalar)
        }
        let text = String(out).trimmingCharacters(in: .whitespaces)
        // Any web page can open a link. A prompt that is an option to the agent's
        // CLI is not one a link gets to fill in.
        return text.isEmpty || text.hasPrefix("-") ? nil : text
    }

    private static let allowedID = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
    private static let allowedAgent = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")

    static func isExistingDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Choosing a session (pure)

    /// The session that most needs you: one waiting on a permission, then one
    /// asking a question, then whichever working session moved last. A finished or
    /// idle session is never "the one that needs you" — a link that jumps to
    /// yesterday's terminal is a link that did nothing useful and moved your focus.
    static func mostNeeded(_ sessions: [Session]) -> Session? {
        linkable(sessions)
            .filter { $0.state == .permission || $0.state == .question || $0.state.isWorking }
            .max { a, b in
                // Working sessions all share one rank; within a rank, newest wins.
                let (ra, rb) = (rank(a), rank(b))
                return ra != rb ? ra < rb : a.ts < b.ts
            }
    }

    /// What a link may jump to: local sessions only. Focusing a cloud row opens its
    /// `url` — a string whoever wrote the row chose, a remote host over ssh
    /// included — so a link that could reach one is a link that launches things.
    static func linkable(_ sessions: [Session]) -> [Session] {
        sessions.filter { $0.entrypoint != "cloud" }
    }

    private static func rank(_ s: Session) -> Int {
        switch s.state {
        case .permission: return 2
        case .question:   return 1
        default:          return 0
        }
    }

    // MARK: - Dispatching

    /// Fed by the app delegate, the same poll every surface reads.
    static var sessions: () -> [Session] = { [] }

    /// A link that launched the app arrives before the first poll has read
    /// `state.d`, when "the session that needs you" is nobody. It is held here —
    /// one of them, the latest — until the app delegate says the stores are live.
    private static var pending: Command?
    private static var ready = false

    /// Called once the first poll has landed. Anything held since launch runs now.
    static func storesReady() {
        guard !ready else { return }
        ready = true
        if let command = pending {
            pending = nil
            run(command)
        }
    }

    /// Everything `application(_:open:)` receives. Not every URL handed to the app
    /// is ours — the delegate method also gets files — and a URL that is not a
    /// command is logged and forgotten.
    static func handle(_ urls: [URL]) {
        for url in urls {
            guard let command = parse(url) else {
                // The scheme only, never the rest: a query can carry a prompt, and a
                // prompt is somebody's words, not the system log's.
                NSLog("AgentBar: ignored an unrecognised %@: link", url.scheme ?? "")
                continue
            }
            guard ready else { pending = command; continue }
            run(command)
        }
    }

    private static func run(_ command: Command) {
        switch command {
        case .focus(let id):
            let all = linkable(sessions())
            let target = id.map { id in all.first { $0.id == id } } ?? mostNeeded(all)
            // A row click without its hand-off. A click hands a waiting prompt back
            // to its terminal (`defer`); a link does not, because any web page can
            // open one, and a link must not move a pending decision anywhere — the
            // card stays on the island, answerable, and the terminal comes forward.
            guard let target else { return }
            AgentActions.focus(target, requests: [])
        case .newTask(let prefill):
            LauncherPanel.shared.show(prefill: prefill)
        case .settings(let page):
            SettingsWindow.shared.show(page: page)
        case .welcome:
            WelcomeWindow.shared.show()
        }
    }
}
