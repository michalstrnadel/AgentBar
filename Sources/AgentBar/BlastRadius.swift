import Foundation

/// What a permission request can reach, said in a few words above the buttons:
/// `deletes`, `outside repo`, `network`, `secrets`. The person reads the command
/// either way; these say where to look first, and how much a yes can cost.
///
/// Display only. Nothing here answers anything or feeds a rule — `RuleEngine`
/// decides what a rule may approve, from its own tables, and stops at the first
/// reason. This reads the same tables and keeps going, because a card should name
/// every reach a command has, not the first one that disqualifies it. Where the two
/// could disagree, this one errs toward saying more: a chip too many costs a
/// glance, a chip too few is a yes nobody weighed.
///
/// The severity sets how deliberate Allow has to be on the island
/// (`HoldButton`): `.low` is a click, `.medium` and `.high` are held.
enum BlastRadius {
    enum Severity: Int, Comparable {
        case low = 0, medium, high
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

        /// How long Allow is held before it answers. Zero is a plain click.
        var hold: TimeInterval {
            switch self {
            case .low: return 0
            case .medium: return 0.6
            case .high: return 1.2
            }
        }
    }

    enum Kind: String, CaseIterable {
        case privileged, deletes, discards, publishes, pipesToShell, network
        case agentConfig, secrets, system, outsideRepo, inlineCode
        case processes, machineSettings, permissions, substitution
        case truncated, invisible
    }

    struct Chip: Equatable {
        let kind: Kind
        let label: String
        let severity: Severity
    }

    /// The highest severity among `chips`, `.low` when there are none.
    static func severity(of chips: [Chip]) -> Severity {
        chips.map(\.severity).max() ?? .low
    }

    /// Every reach this request has, most severe first, each kind once.
    /// `cwd` is the session's directory; when it is empty nothing can be called
    /// outside it, and that check is skipped rather than guessed.
    static func chips(for request: ApprovalRequest, cwd: String) -> [Chip] {
        var found: [Chip] = []
        if request.droppedInvisible { found.append(chip(.invisible)) }
        switch request.context {
        case .bash(let command):
            if command.utf16.count >= RuleEngine.maxCommandLength { found.append(chip(.truncated)) }
            found += commandChips(command, cwd: cwd)
        case .diff, .write, .none:
            if let path = DecisionLedger.filePath(of: request) {
                found += pathChips(path, cwd: cwd)
            }
            if networkTools.contains(request.toolName) { found.append(chip(.network)) }
        case .question, .plan:
            break
        }
        return ordered(found)
    }

    /// Tools whose whole job is to reach off the machine.
    static let networkTools: Set<String> = ["WebFetch", "WebSearch"]

    // MARK: - Commands

    static func commandChips(_ command: String, cwd: String) -> [Chip] {
        var found: [Chip] = []
        if RuleEngine.carries(command, "$(") || RuleEngine.carries(command, "`") {
            found.append(chip(.substitution))
        }
        let segments = split(command)
        for (index, segment) in segments.enumerated() {
            let words = segment.words
            let afterPipe = index > 0 && segments[index - 1].joiner == "|"
            found += segmentChips(words, afterPipe: afterPipe, cwd: cwd)
        }
        return found
    }

    /// One command of a line: its head word decides most of it, its paths the rest.
    private static func segmentChips(_ words: [String], afterPipe: Bool, cwd: String) -> [Chip] {
        var found: [Chip] = []
        var rest = words[...]
        // Assignments and wrappers sit in front of the command the line is about.
        while let w = rest.first {
            if w.contains("="), !w.hasPrefix("-"), !w.hasPrefix("/"),
               w.firstIndex(of: "=")! > w.startIndex { rest = rest.dropFirst(); continue }
            let name = (w as NSString).lastPathComponent
            if privileged.contains(name) {
                found.append(chip(.privileged, name))
                rest = rest.dropFirst()
                while let flag = rest.first, flag.hasPrefix("-") { rest = rest.dropFirst() }
                continue
            }
            if passThrough.contains(name) {
                rest = rest.dropFirst()
                while let flag = rest.first, flag.hasPrefix("-") { rest = rest.dropFirst() }
                continue
            }
            break
        }
        guard let head = rest.first else { return found }
        let name = (head as NSString).lastPathComponent
        let args = Array(rest.dropFirst())
        let sub = subcommand(of: args)
        let flags = Set(args.filter { $0.hasPrefix("-") })
        let refusedFlag = RuleEngine.refusedSpelling(of: name, in: args) != nil
            || !(RuleEngine.refusedArguments[name] ?? []).isDisjoint(with: args)

        if shells.contains(name), afterPipe { found.append(chip(.pipesToShell)) }
        switch name {
        case "rm", "rmdir", "unlink", "shred", "srm":
            found.append(refusedFlag || name == "shred" ? chip(.deletes, "deletes", .high) : chip(.deletes))
        case "dd", "mkfs", "truncate":
            found.append(chip(.deletes, "overwrites", .high))
        case "find" where !flags.isDisjoint(with: ["-delete"]):
            found.append(chip(.deletes, "deletes", .high))
        case "find" where !flags.isDisjoint(with: ["-exec", "-execdir", "-ok", "-okdir"]):
            found.append(chip(.inlineCode, "find -exec"))
        case "git":
            if sub == "push" {
                let forced = !flags.isDisjoint(with: ["--force", "-f", "--force-with-lease", "--mirror", "--delete", "-d"])
                found.append(forced ? chip(.discards, "force push", .high) : chip(.publishes, "git push"))
            } else if discardingGit.contains(sub) || flags.contains("--hard") {
                found.append(chip(.discards, "discards changes", .high))
            } else if historyGit.contains(sub) {
                found.append(chip(.discards, "rewrites history"))
            } else if ["clone", "fetch", "pull"].contains(sub) {
                found.append(chip(.network))
            }
        case "gh" where ["release", "repo", "secret", "auth", "ssh-key", "api"].contains(sub):
            found.append(chip(.publishes, "gh \(sub)", sub == "secret" || sub == "auth" ? .high : .medium))
        case let tool where publishers.contains(tool) && ["publish", "unpublish", "push"].contains(sub):
            found.append(chip(.publishes, "\(tool) \(sub)", .high))
        case "docker" where sub == "push":
            found.append(chip(.publishes, "docker push", .high))
        case "kubectl" where ["delete", "apply", "drain", "exec"].contains(sub):
            found.append(chip(.publishes, "kubectl \(sub)", .high))
        case "chmod" where args.contains(where: RuleEngine.refusedMode) || flags.contains("-R"):
            found.append(chip(.permissions))
        case "chown", "chgrp":
            found.append(chip(.permissions))
        default:
            break
        }
        if networkCommands.contains(name) { found.append(chip(.network)) }
        if processCommands.contains(name) { found.append(chip(.processes)) }
        if settingsCommands.contains(name) { found.append(chip(.machineSettings)) }
        if let flag = inlineFlags[name]?.intersection(flags).sorted().first {
            found.append(chip(.inlineCode, "\(name) \(flag)"))
        } else if name == "eval" || name == "osascript" {
            found.append(chip(.inlineCode, name))
        }
        for word in args where RuleEngine.looksLikePath(word) && !word.hasPrefix("-") {
            found += pathChips(word, cwd: cwd)
        }
        return found
    }

    // MARK: - Paths

    static func pathChips(_ path: String, cwd: String) -> [Chip] {
        let base = cwd.isEmpty ? "/" : cwd
        let full = RuleEngine.absolute(path, in: base)
        var found: [Chip] = []
        if let hit = agentConfigPaths.first(where: { full.contains($0) }) {
            found.append(chip(.agentConfig, hit == "/.git/hooks" || hit == "/.git/config" ? "git config" : "agent config"))
        }
        if secretPaths.contains(where: { full.contains($0) }) { found.append(chip(.secrets)) }
        if systemPaths.contains(where: { full.hasPrefix($0) })
            || full.contains("/Library/LaunchAgents") || full.contains("/Library/LaunchDaemons") {
            found.append(chip(.system))
        }
        if !cwd.isEmpty, !RuleEngine.isInside(full, cwd), !scratchPaths.contains(where: { full.hasPrefix($0) }) {
            found.append(chip(.outsideRepo))
        }
        return found
    }

    // MARK: - Tables

    static let privileged: Set<String> = ["sudo", "doas", "su", "pkexec", "run0"]
    /// Words that run the command after them: stepped over, not judged.
    static let passThrough: Set<String> = ["command", "env", "time", "nice", "nohup",
                                            "timeout", "stdbuf", "caffeinate", "exec"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh"]
    static let networkCommands: Set<String> = ["curl", "wget", "nc", "ncat", "netcat", "ngrok",
                                                "ssh", "scp", "rsync", "sftp", "ftp", "telnet"]
    static let processCommands: Set<String> = ["kill", "killall", "pkill", "shutdown", "reboot", "halt"]
    static let settingsCommands: Set<String> = ["launchctl", "defaults", "crontab", "systemsetup",
                                                 "diskutil", "csrutil", "security", "codesign",
                                                 "spctl", "xattr", "pmset", "networksetup"]
    static let inlineFlags: [String: Set<String>] = [
        "sh": ["-c"], "bash": ["-c"], "zsh": ["-c"],
        "python": ["-c"], "python3": ["-c"], "node": ["-e", "--eval", "-p", "--print"],
        "perl": ["-e", "-E"], "ruby": ["-e"], "php": ["-r"],
    ]
    static let discardingGit: Set<String> = ["clean", "reset", "checkout", "restore", "stash", "rm"]
    static let historyGit: Set<String> = ["rebase", "filter-branch", "update-ref", "reflog", "gc", "prune"]

    /// How permission itself is configured: an agent editing these edits its own leash.
    static let agentConfigPaths = RuleEngine.refusedPaths.prefix { $0 != "/.ssh/" }
    static let secretPaths: [String] = ["/.ssh/", "/.aws/", "/.gnupg/", "/.netrc", "/.npmrc", "/.pypirc",
                                        "authorized_keys", "id_rsa", "id_ed25519", ".pem", ".p12",
                                        ".keychain", "credentials", "/.env", ".env."]
    static let systemPaths: [String] = ["/etc/", "/private/etc/", "/System/", "/Library/"]
    static let publishers: Set<String> = ["npm", "pnpm", "yarn", "cargo", "twine", "gem", "pod"]
    /// Where reaching outside the project is routine: temp space and device sinks.
    static let scratchPaths: [String] = ["/tmp/", "/private/tmp/", "/var/folders/", "/dev/null",
                                         "/dev/stdout", "/dev/stderr"]

    // MARK: - Small helpers

    /// The first word that is not an option — for git, after stepping over the
    /// options that take a value (`-C dir`, `-c key=value`).
    static func subcommand(of args: [String]) -> String {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-C" || a == "-c" { i += 2; continue }
            if !a.hasPrefix("-") { return a }
            i += 1
        }
        return ""
    }

    static func chip(_ kind: Kind, _ label: String? = nil, _ severity: Severity? = nil) -> Chip {
        Chip(kind: kind, label: label ?? defaultLabel[kind]!, severity: severity ?? defaultSeverity[kind]!)
    }

    static let defaultLabel: [Kind: String] = [
        .privileged: "sudo", .deletes: "deletes", .discards: "discards changes",
        .publishes: "publishes", .pipesToShell: "pipes into a shell", .network: "network",
        .agentConfig: "agent config", .secrets: "secrets", .system: "system files",
        .outsideRepo: "outside repo", .inlineCode: "inline code", .processes: "kills processes",
        .machineSettings: "macOS settings", .permissions: "permissions",
        .substitution: "substitution", .truncated: "cut off", .invisible: "hidden characters",
    ]

    static let defaultSeverity: [Kind: Severity] = [
        .privileged: .high, .deletes: .medium, .discards: .high, .publishes: .medium,
        .pipesToShell: .high, .network: .medium, .agentConfig: .high, .secrets: .high,
        .system: .medium, .outsideRepo: .medium, .inlineCode: .medium, .processes: .medium,
        .machineSettings: .medium, .permissions: .medium, .substitution: .medium,
        .truncated: .high, .invisible: .high,
    ]

    /// One chip per kind, keeping the most severe; most severe first, then the
    /// order the kinds are declared in, so a card reads the same every time.
    static func ordered(_ chips: [Chip]) -> [Chip] {
        var best: [Kind: Chip] = [:]
        for c in chips where best[c.kind].map({ $0.severity < c.severity }) ?? true { best[c.kind] = c }
        let order = Kind.allCases
        return best.values.sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity
                : order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)!
        }
    }

    struct Segment { var words: [String]; var joiner: String }

    /// The line cut into commands at `|`, `||`, `&&`, `;`, `&` and line breaks
    /// outside quotes, each command cut into unquoted words. A redirect's target
    /// becomes a word of its own, so it is judged as a path like any other.
    static func split(_ line: String) -> [Segment] {
        var segments: [Segment] = []
        var words: [String] = [], word = "", inWord = false
        var open: Character?
        func endWord() { if inWord { words.append(word); word = ""; inWord = false } }
        func endSegment(_ joiner: String) {
            endWord()
            if !words.isEmpty { segments.append(Segment(words: words, joiner: joiner)) }
            words = []
        }
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if let q = open {
                if ch == q { open = nil } else { word.append(ch) }
            } else if ch == "'" || ch == "\"" {
                open = ch; inWord = true
            } else if ch == " " || ch == "\t" {
                endWord()
            } else if ch == "\n" || ch == "\r" || ch == ";" {
                endSegment(";")
            } else if ch == "|" || ch == "&" {
                let doubled = i + 1 < chars.count && chars[i + 1] == ch
                if ch == "&", i > 0, chars[i - 1] == ">" || (i + 1 < chars.count && chars[i + 1] == ">") {
                    // `2>&1`, `&>file`: a redirect, not a joiner.
                    word.append(ch); inWord = true
                } else {
                    endSegment(doubled ? String([ch, ch]) : String(ch))
                    if doubled { i += 1 }
                }
            } else if ch == ">" || ch == "<" {
                // `2>err.log`, `>>out`, `> file`: the descriptor stays behind, the
                // target starts a word of its own.
                if inWord, word.allSatisfy(\.isNumber) { word = ""; inWord = false }
                endWord()
                while i + 1 < chars.count, chars[i + 1] == ">" || chars[i + 1] == "&" { i += 1 }
            } else {
                word.append(ch); inWord = true
            }
            i += 1
        }
        endSegment("")
        return segments.filter { !$0.words.isEmpty }
    }
}
