import Foundation

/// Answers a permission request from a rule the human wrote, and records that it
/// did. The only code path in AgentBar that writes an answer nobody clicked.
///
/// The posture, in one line: **a rule is the person deciding in advance, so the
/// product's job is to make sure the thing it answers is the thing they pictured.**
/// A rule is keyed by the ledger's `shape` — `bash:git push` — which is coarse on
/// purpose, because arguments never repeat and are where a secret would be. Coarse
/// is fine for a denial: refusing more than you meant costs a prompt. It is not
/// fine for an approval, so every approval is checked a second time against the
/// **live command**, and `refusal(for:)` is what stands between a shape and a
/// silent yes.
///
/// Everything here degrades to the ordinary prompt. A rule that does not match, a
/// rules file that will not parse, a command that will not tokenise, a request with
/// no session: all of them mean nobody answers, and nobody answering is exactly the
/// product without rules.
final class RuleEngine {
    static let shared = RuleEngine()

    struct Verdict: Equatable {
        let behavior: String     // "allow" | "deny"
        let rule: RulesStore.Rule
    }

    /// One firing, kept in memory for this launch so a surface can say what just
    /// happened without re-reading the ledger. The ledger is the record; this is
    /// the glance.
    struct Firing: Equatable {
        let at: Date
        let ruleID: String
        /// allow | deny | watch
        let decision: String
        /// What a watching rule would have said. Empty for a real firing.
        let would: String
        let display: String
    }

    private let lock = NSLock()
    /// Requests already answered, by `ApprovalRequest.identity`. `refresh()` runs on
    /// every directory event and every two seconds, and the hook needs up to 100 ms
    /// to collect its answer — without this the same rule would write the same
    /// answer repeatedly and the ledger would count one decision many times.
    private var answered: Set<String> = []
    /// Requests a **watching** rule has already written a note about. Same problem,
    /// different verb: without this the two-second poll would file one "would have
    /// allowed" per tick for the whole ten minutes a request can be pending, and a
    /// mode meant for judging a rule would be unreadable after one prompt.
    private var noted: Set<String> = []
    private var firings: [Firing] = []

    /// Newest first, capped: a glance, not a log.
    var recent: [Firing] {
        lock.lock(); defer { lock.unlock() }
        return firings
    }

    /// True when this request was answered from a rule and must not be shown as
    /// pending. False for everything else, including every failure.
    func handle(_ request: ApprovalRequest, session: Session?,
                load: RulesStore.Load? = nil, now: Date = Date(),
                ledger: DecisionLedger = .shared) -> Bool {
        guard RulesStore.enabled else { return false }
        lock.lock()
        let seen = answered.contains(request.identity)
        lock.unlock()
        if seen { return true }

        let rules = (load ?? RulesStore.cached()).rules
        let cwd = request.cwd.isEmpty ? (session?.cwd ?? "") : request.cwd
        guard let verdict = Self.verdict(for: request, cwd: cwd, rules: rules) else { return false }

        // Watching: work out the answer, write it down, and do not give it. The
        // card appears, the human decides, and a week of these is how somebody
        // learns whether the rule matches what they pictured — before it has
        // approved anything.
        guard verdict.rule.answers else {
            lock.lock()
            let alreadyNoted = noted.contains(request.identity)
            if !alreadyNoted {
                noted.insert(request.identity)
                firings.insert(Firing(at: now, ruleID: verdict.rule.id, decision: "watch",
                                      would: verdict.behavior, display: request.display), at: 0)
                if firings.count > 20 { firings.removeLast(firings.count - 20) }
            }
            lock.unlock()
            if !alreadyNoted {
                ledger.record("watch", request: request, session: session,
                              via: "rule", rule: verdict.rule.id,
                              would: verdict.behavior,
                              now: now.timeIntervalSince1970)
            }
            return false
        }

        // A denying rule may say why, in the person's words — the refusal then
        // steers the agent instead of leaving it to guess and try the next thing.
        let tell = verdict.behavior == "deny" ? verdict.rule.tell : ""
        // The row first. If it cannot be written the rule does not answer: an
        // answer with no row naming its rule is the one thing rule 3 forbids, and
        // the human deciding instead costs a click.
        guard ledger.recordNow(verdict.behavior, request: request, session: session,
                               via: "rule", rule: verdict.rule.id,
                               now: now.timeIntervalSince1970)
        else { return false }
        guard AnswerWriter.write(behavior: verdict.behavior,
                                 message: tell.isEmpty ? nil : tell, for: request)
        else { return false }

        lock.lock()
        answered.insert(request.identity)
        firings.insert(Firing(at: now, ruleID: verdict.rule.id, decision: verdict.behavior,
                              would: "", display: request.display), at: 0)
        if firings.count > 20 { firings.removeLast(firings.count - 20) }
        lock.unlock()
        return true
    }

    /// Drops the memory of requests that no longer exist, so a long-running app
    /// does not accumulate identities for ever.
    func forget(keeping live: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        answered.formIntersection(live)
        noted.formIntersection(live)
    }

    // MARK: - Matching

    /// Which rule, if any, speaks for this request. Pure: every input is a
    /// parameter, which is what makes the table below testable.
    static func verdict(for request: ApprovalRequest, cwd: String,
                        rules: [RulesStore.Rule]) -> Verdict? {
        let shape = DecisionLedger.shape(of: request)
        let matching = rules.filter { matches($0, shape: shape, agent: request.agentID, cwd: cwd) }
        guard !matching.isEmpty else { return nil }
        // Deny wins. A person who wrote both meant the stricter one, and this is
        // how every access list on earth resolves the same collision.
        if let deny = matching.first(where: { $0.decision == "deny" }) {
            return Verdict(behavior: "deny", rule: deny)
        }
        guard let allow = matching.first(where: { $0.isAllow }) else { return nil }
        // The second look, at the live command rather than its shape.
        guard refusal(for: request, cwd: cwd) == nil else { return nil }
        return Verdict(behavior: "allow", rule: allow)
    }

    static func matches(_ rule: RulesStore.Rule, shape: String, agent: String, cwd: String) -> Bool {
        // A watching rule matches — being matched is the whole of what it does. An
        // `off` rule does not, which is what makes "off" different from "watch".
        guard rule.mode != .off, rule.shape == shape else { return false }
        if !rule.agent.isEmpty, rule.agent != agent { return false }
        if rule.cwd.isEmpty { return true }          // denials only; enforced at load
        // A directory inside the one that was named is still inside it — that is
        // what "in this repository" means to the person who picked it.
        return cwd == rule.cwd || cwd.hasPrefix(rule.cwd + "/")
    }

    // MARK: - What an approval will never do

    /// Why this request may not be approved by a rule, or nil when it may.
    ///
    /// Every clause here is a case where the shape is a true description of the
    /// request and still not enough to say yes. Denials never come through here:
    /// refusing more than you meant is safe, approving more than you meant is the
    /// failure this whole feature has to not have.
    static func refusal(for request: ApprovalRequest, cwd: String) -> String? {
        // A plan approval is a keystroke at a dialog, not a hook decision — the
        // hook would swallow an allow anyway (permission.js). A question is not a
        // permission at all.
        if request.isPlanRequest { return "a plan review is approved in the terminal, not by a rule" }
        if request.questions != nil { return "a question is not a permission" }
        if cwd.isEmpty { return "nobody knows which directory this ran in" }
        if request.droppedInvisible { return "a request carrying a character the reader drops" }

        switch request.context {
        case .bash(let command):
            return refusalInCommand(command, cwd: cwd)
        case .diff, .write, .none:
            // Every other tool is judged by the file it names. A tool that names
            // nothing this code understands is not understood, and a rule does not
            // get to approve what it cannot read.
            guard let path = DecisionLedger.filePath(of: request) else {
                return "this tool names nothing a rule can check"
            }
            return refusalInPath(path, cwd: cwd)
        case .question, .plan:
            return "not an ordinary permission"
        }
    }

    /// Commands whose presence anywhere on the line ends the matter. Some are
    /// destructive, some reach off the machine, some can run anything at all —
    /// the common property is that no argument makes them routine.
    static let refusedCommands: Set<String> = [
        "sudo", "doas", "su", "pkexec", "run0",
        "shred", "mkfs", "dd", "truncate", "chown", "chgrp",
        "curl", "wget", "nc", "ncat", "netcat", "ngrok", "ssh", "scp", "rsync", "sftp",
        "codesign", "spctl", "xattr", "csrutil", "diskutil", "launchctl", "systemsetup",
        "security", "op", "gpg", "keychain", "defaults", "crontab", "at",
        "osascript", "open", "eval", "exec", "source",
        "kill", "killall", "pkill", "shutdown", "reboot", "halt",
        // A shell, and the small family of tools whose entire job is to run some
        // other command, are the same case as `sudo`: the word says one thing and
        // the arguments do another, and no argument makes them routine. `sh -c`
        // carries a whole command line that never meets the clause above it.
        "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh",
        "xargs", "nohup", "timeout", "nice", "stdbuf", "watch", "script",
    ]

    /// Words `DecisionLedger.verb` steps over on its way to the command the shape is
    /// named after. This table has to step over the same ones, or the two disagree
    /// about which word is the command — and the half that disagrees here is the half
    /// that says yes. `sudo` is on verb's list too and is refused outright above,
    /// which is why it is not on this one.
    static let wrappers: Set<String> = ["command", "env"]

    /// Where a tool may legitimately live outside the rule's directory. `/usr/bin/git`
    /// is outside every repository on the machine and is still just git; a binary
    /// anywhere else is not the tool the rule was written for, whatever its name says.
    static let toolDirectories: [String] = [
        "/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/usr/libexec/",
        "/usr/local/bin/", "/opt/homebrew/bin/", "/opt/local/bin/",
    ]

    /// Flags and words that turn one of these tools into a different kind of act.
    /// Per command, not global: `-r` is a catastrophe for the remover and routine
    /// for `grep`.
    static let refusedArguments: [String: Set<String>] = [
        "rm": ["-r", "-rf", "-fr", "-R", "-f", "--recursive", "--force", "-drf"],
        "git": ["--force", "-f", "--force-with-lease", "--hard"],
        "chmod": ["777", "666", "+s", "-R", "--recursive", "a+w"],
        "mv": ["-f", "--force"],
        "cp": ["-f", "--force"],
        "npm": ["--force", "-f"],
        "brew": ["--force", "-f"],
        // A search that deletes what it finds, or runs something on it, is not a
        // search. `find . -delete` reads like the most harmless line in this file.
        "find": ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprintf", "-fls"],
        // An interpreter handed a snippet on the command line is a shell by another
        // name; the same interpreter handed a file in the repository is ordinary work.
        "python": ["-c"], "python3": ["-c"], "node": ["-e", "--eval", "-p", "--print"],
        "perl": ["-e", "-E"], "ruby": ["-e"], "php": ["-r"], "deno": ["eval"],
    ]

    /// Subcommands that discard work, rewrite history, or hand out rights. A rule
    /// may still be written for `git status`; it may not cover these by accident.
    static let refusedSubcommands: [String: Set<String>] = [
        "git": ["clean", "reset", "checkout", "restore", "rm", "stash", "filter-branch",
                "update-ref", "reflog", "gc", "prune", "push", "remote", "config",
                "submodule", "worktree", "apply", "am", "rebase", "cherry-pick", "revert"],
        "gh": ["auth", "secret", "ssh-key", "repo", "release", "api"],
        "npm": ["publish", "login", "adduser", "token", "unpublish"],
        "docker": ["run", "exec", "rm", "rmi", "system", "login"],
        "kubectl": ["delete", "apply", "exec", "drain", "cordon"],
        "brew": ["uninstall", "remove", "services"],
    ]

    /// Places a rule may never reach, whatever the command. The first group is how
    /// permission itself is configured — a rule that could approve an edit to the
    /// rules, the hooks or an agent's settings would be a rule that can widen
    /// itself. The second is where credentials live.
    static let refusedPaths: [String] = [
        "/.agentbar/", "/.claude/", "/.claude-", "/.codex/", "/.copilot/", "/.cursor/",
        "/.gemini/", "/.qwen/", "/.config/opencode/", "/.git/hooks", "/.git/config",
        "/.ssh/", "/.aws/", "/.gnupg/", "/.netrc", "/.npmrc", "/.pypirc",
        "/etc/", "/dev/", "/System/", "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "authorized_keys", "id_rsa", "id_ed25519", ".pem", ".p12", ".keychain",
        "credentials", ".env",
    ]

    /// The reason a bash command may not be approved from a rule, or nil.
    static func refusalInCommand(_ command: String, cwd: String) -> String? {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return "an empty command" }

        // FIRST, and the reason the rest is safe to reason about as one command:
        // `DecisionLedger.verb` takes the shape from the FIRST command on the line,
        // so a chained line carries the shape of its head. A rule must never answer
        // for the tail it never saw.
        // Searched by code unit, never by Character: Swift reads `\r\n` as ONE
        // Character, so `"ls x\r\nreboot".contains("\n")` is false and the second
        // command walked past this clause under the first one's shape. A lone `\r` is
        // refused too — it is a line break to everything that is not bash.
        for marker in ["|", ";", "&", "\n", "\r", "$(", "`", ">", "<"] where carries(line, marker) {
            return "more than one command, a redirect or a substitution on one line"
        }
        // SECOND: every word below is judged as the literal text it is, and the shell
        // does not run the literal text. A parameter (`$HOME/.ssh`, `${HOME}`, the
        // ANSI-C `$'-r'`), a backslash escape (`\-r`), a brace (`{..,.}/x`) or a
        // glob (`.?/x` is `../x`) is rewritten before the command sees it, so the
        // path and flag clauses would be checking a word that never arrives. A rule
        // does not approve what this code cannot read; the human still can.
        for marker in ["$", "\\", "{", "*", "?", "["] where carries(line, marker) {
            return "a word the shell rewrites before the command sees it"
        }
        // A quote that never closes is a line the shell refuses to run as written —
        // and the words below were cut on spaces the shell would have read as part of
        // the quote. Backslashes are already refused above, so no quote is escaped.
        if hasUnterminatedQuote(line) { return "a command that will not tokenise" }

        var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { unquote(String($0)) }
            .filter { !$0.isEmpty }
        // A leading environment assignment is how the same command arrives wearing
        // a different hat, and an assignment in front of it is not the command the
        // rule was written for.
        if let first = words.first, first.contains("="), !first.hasPrefix("-") {
            return "an environment assignment in front of the command"
        }
        // The wrappers, for the reason `wrappers` gives: the shape was taken from the
        // word underneath them, so the table must read the same word.
        while let first = words.first.map({ ($0 as NSString).lastPathComponent }),
              wrappers.contains(first) {
            words.removeFirst()
            if let next = words.first, next.contains("="), !next.hasPrefix("-") {
                return "an environment assignment in front of the command"
            }
        }
        guard let head = words.first, !head.hasPrefix("-") else {
            return "a command that will not tokenise"
        }
        let name = (head as NSString).lastPathComponent
        if refusedCommands.contains(name) { return "`\(name)` is never approved by a rule" }
        // The command is itself a path whenever it is written as one, and "a path
        // outside the directory the rule names" is a published clause — the one path
        // nobody was checking it against was the command's own. The shape is taken
        // from the last component, so `/tmp/evil/npm test` matches a rule somebody
        // wrote for `npm test` while being a different program entirely.
        if looksLikePath(head) {
            let full = absolute(head, in: cwd)
            if let fragment = refusedFragment(in: full) {
                return "`\(fragment)` is never approved by a rule"
            }
            if !toolDirectories.contains(where: { full.hasPrefix($0) }),
               full != cwd, !full.hasPrefix(cwd + "/") {
                return "a command run from outside the directory the rule names"
            }
        }

        words.removeFirst()
        if let bad = refusedArguments[name]?.intersection(Set(words)).sorted().first {
            return "`\(name) \(bad)` is never approved by a rule"
        }
        if let bad = refusedSpelling(of: name, in: words) {
            return "`\(name) \(bad)` is never approved by a rule"
        }
        if let subs = refusedSubcommands[name],
           let sub = words.first(where: { !$0.hasPrefix("-") }), subs.contains(sub) {
            return "`\(name) \(sub)` is never approved by a rule"
        }
        for word in words {
            // `--output=/tmp/x` and `PREFIX=/usr/local` carry their path after the
            // `=`; read whole, they are a relative name that lands inside the
            // directory on paper. An option with a path glued on and no `=`
            // (`-o/tmp/x`) has no edge this code can find, so it is not understood.
            if word.hasPrefix("-"), !word.contains("="), looksLikePath(word) {
                return "an option with a path glued to it"
            }
            if let eq = word.firstIndex(of: "=") {
                let value = String(word[word.index(after: eq)...])
                if looksLikePath(value), let reason = refusalInPath(value, cwd: cwd) {
                    return reason
                }
            }
            if looksLikePath(word) {
                if let reason = refusalInPath(word, cwd: cwd) { return reason }
            } else if let fragment = refusedFragment(in: "/" + word) {
                // A bare name is still the file it names. `cat .env` and `cat ./.env`
                // are one act; only one of them has a separator in it, and the table
                // that lists `.env` was only ever shown the other.
                return "`\(fragment)` is never approved by a rule"
            }
        }
        return nil
    }

    /// A refused flag in a spelling the table does not list, or nil. The table holds
    /// the flags; the shell accepts more ways of writing each. `-Rf`, `-rfv` and
    /// `-rv` are `-r` to the remover, `perl -le` is `perl -e`, and getopt takes any
    /// unambiguous prefix of a long option, so `--rec` is `--recursive`. A mode is
    /// the other half: `chmod 4755` sets setuid exactly as `+s` does.
    static func refusedSpelling(of name: String, in words: [String]) -> String? {
        let refused = refusedArguments[name] ?? []
        // Only single-letter entries can hide in a cluster; `find -delete` is one
        // long option written with one dash, not seven letters.
        let letters = Set(refused.filter { $0.count == 2 && $0.hasPrefix("-") && $0 != "--" }
            .compactMap { $0.last })
        let long = refused.filter { $0.hasPrefix("--") }
        for word in words {
            if word.hasPrefix("--") {
                let flag = String(word.prefix { $0 != "=" })
                if flag.count > 2, long.contains(where: { $0.hasPrefix(flag) }) { return word }
            } else if word.hasPrefix("-"), word.count > 2,
                      word.dropFirst().contains(where: { letters.contains($0) }) {
                return word
            }
        }
        guard name == "chmod" else { return nil }
        for word in words where !word.hasPrefix("-") && refusedMode(word) { return word }
        return nil
    }

    /// A chmod mode that hands out rights: setuid, setgid or sticky, or write for
    /// everybody. Numeric or symbolic; a clause that names nobody (`+w`) is read as
    /// naming everybody, because which bits the umask spares is not on the line.
    static func refusedMode(_ mode: String) -> Bool {
        if !mode.isEmpty, mode.count <= 4, mode.allSatisfy({ ("0"..."7").contains($0) }) {
            let digits = mode.compactMap { $0.wholeNumberValue }
            if digits.count == 4, digits[0] != 0 { return true }   // setuid / setgid / sticky
            return digits.last.map { $0 & 2 != 0 } ?? false        // world-writable
        }
        for clause in mode.split(separator: ",") {
            let who = clause.prefix { "ugoa".contains($0) }
            let rest = clause.dropFirst(who.count)
            guard let op = rest.first, "+=".contains(op) else { continue }
            let perms = rest.dropFirst()
            if perms.contains("s") || perms.contains("t") { return true }
            if perms.contains("w"), who.isEmpty || who.contains("o") || who.contains("a") {
                return true
            }
        }
        return false
    }

    /// The reason a file this request names puts it out of a rule's reach, or nil.
    static func refusalInPath(_ path: String, cwd: String) -> String? {
        let full = absolute(path, in: cwd)
        if let fragment = refusedFragment(in: full) {
            return "`\(fragment)` is never approved by a rule"
        }
        guard full == cwd || full.hasPrefix(cwd + "/") else {
            return "a path outside the directory the rule names"
        }
        return nil
    }

    /// Which forbidden fragment this text carries, if any. Split out because the
    /// same question is asked of three different things: a path an edit names, a
    /// path inside a command, and the command's own path.
    static func refusedFragment(in text: String) -> String? {
        refusedPaths.first { text.contains($0) }
    }

    // MARK: - Small, dull helpers the table leans on

    /// Whether `marker` occurs in `line`, compared code unit by code unit.
    static func carries(_ line: String, _ marker: String) -> Bool {
        (line as NSString).range(of: marker, options: .literal).location != NSNotFound
    }

    /// A `'` or `"` the line opens and never closes, read the way a POSIX shell
    /// reads them: inside single quotes nothing is special but the closing `'`,
    /// inside double quotes a `'` is just a letter.
    static func hasUnterminatedQuote(_ line: String) -> Bool {
        var open: Unicode.Scalar?
        for s in line.unicodeScalars {
            if let q = open { if s == q { open = nil } }
            else if s == "'" || s == "\"" { open = s }
        }
        return open != nil
    }

    /// A token worth checking as a path: anything with a separator in it, or a
    /// home-relative name. A bare word is an argument, not a place, except that
    /// `.` and `..` are places with no separator in them: `ls ..` lists the parent.
    static func looksLikePath(_ word: String) -> Bool {
        word.hasPrefix("/") || word.hasPrefix("~") || word.contains("/")
            || word == "." || word == ".."
    }

    static func absolute(_ path: String, in cwd: String) -> String {
        var p = path
        if p.hasPrefix("~") {
            p = FileManager.default.homeDirectoryForCurrentUser.path + String(p.dropFirst())
        }
        if !p.hasPrefix("/") { p = cwd + "/" + p }
        return (p as NSString).standardizingPath
    }

    /// Quotes are how a dangerous flag arrives looking like a word. Strip them
    /// before anything is compared; a quoted flag is still that flag. Curly ones
    /// too — a shell does not treat them as quotes, but a person who pasted a
    /// command out of a document may well have them, and the comparison must see
    /// the flag underneath either way.
    static let quotes: Set<Character> = ["\"", "'", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "`"]

    static func unquote(_ s: String) -> String {
        String(s.filter { !quotes.contains($0) })
    }
}
