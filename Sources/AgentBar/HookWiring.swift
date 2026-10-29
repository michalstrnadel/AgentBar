import Foundation

/// Which events AgentBar wires into each agent's config, and which of its scripts
/// answers each one.
///
/// One table with two readers: `HookInstaller` writes from it and `Diagnostics`
/// checks a config against it, so "wired" means the same thing to both. Before it,
/// Diagnostics called an agent wired when AgentBar's path appeared *anywhere* in the
/// file — in a comment, in a disabled block, under the wrong event — and the
/// installer and the doctor could disagree without either noticing.
///
/// The Linux CLI keeps the same table (`HOOK_WIRING` in `Scripts/cli/agentbar`), and
/// `Tests/Fixtures/hook-wiring/cases.json` holds both halves to it: the table itself
/// and the verdict on every config shape in it.
enum HookWiring {
    struct Event: Equatable {
        /// The name the agent fires, spelled as its config spells it.
        let event: String
        /// The script under `~/.agentbar/hooks/`, e.g. `claude/update.js`.
        let script: String
        /// What follows the script on the command line, space-separated; nil for nothing.
        let arg: String?
        /// Installer detail: a `"matcher": "*"` on the rule.
        var matcher = false
        /// Installer detail, in the agent's own unit (Claude and Codex: seconds;
        /// Qwen and Gemini: milliseconds; Copilot: `timeoutSec`).
        var timeout: Int?
        /// Wired only for a Claude Code known to be at least this version, and never
        /// called missing: an event an older build does not know is a settings file
        /// it may refuse, so an unknown version gets the table without it.
        var since: String?
    }

    /// Where every script lives; what says a command is AgentBar's.
    static let hooksPathMarker = "/.agentbar/hooks/"

    // MARK: - The table

    static let claude: [Event] = [
        .init(event: "SessionStart", script: "claude/lifecycle.js", arg: "start"),
        .init(event: "SessionEnd", script: "claude/lifecycle.js", arg: "end"),
        .init(event: "UserPromptSubmit", script: "claude/update.js", arg: "prompt"),
        .init(event: "PreToolUse", script: "claude/update.js", arg: "pre", matcher: true),
        .init(event: "PostToolUse", script: "claude/update.js", arg: "post", matcher: true),
        // Blocking approval hook: its own wait is 600s, so give Claude Code slack.
        // (No Notification hook: late permission notifications used to overwrite
        // newer state and strand sessions on "needs approval".)
        .init(event: "PermissionRequest", script: "claude/permission.js", arg: nil, matcher: true, timeout: 630),
        .init(event: "Stop", script: "claude/update.js", arg: "stop"),
        // "Compacting…" while the session summarises its context. There is no
        // PostCompact here on purpose: the SessionStart (source "compact") that
        // follows every compaction already ends it, and an event name an older
        // Claude Code does not know is a settings file it may refuse.
        .init(event: "PreCompact", script: "claude/update.js", arg: "compact"),
        // Auto mode's classifier refused a call (Claude Code 2.1.89). Observed only:
        // update.js prints nothing, and `{retry: true}` would be an answer.
        .init(event: "PermissionDenied", script: "claude/update.js", arg: "denied", matcher: true, since: "2.1.89"),
    ]

    /// Codex speaks Claude's hook dialect, so these are the `claude/` scripts, reached
    /// through `codex/hook.js` — Codex's handler has no `env` field and runs the command
    /// without a shell, so the shim is where `AGENTBAR_AGENT` and the row prefix get set.
    ///
    /// Timeouts are per event and Codex clamps them: `SessionEnd`'s ceiling is 3s, so
    /// asking for 5 there would earn a warning on every session. `PermissionRequest`
    /// keeps its 630 — above `permission.js`'s own 600s wait, so the hook is the thing
    /// that gives up first and exits silently into Codex's own prompt, rather than being
    /// killed mid-wait. Verified against codex-cli 0.155.0; see Scripts/hooks/codex/README.md.
    static let codex: [Event] = [
        .init(event: "SessionStart", script: "codex/hook.js", arg: "lifecycle.js start", timeout: 5),
        .init(event: "SessionEnd", script: "codex/hook.js", arg: "lifecycle.js end", timeout: 3),
        .init(event: "UserPromptSubmit", script: "codex/hook.js", arg: "update.js prompt", timeout: 5),
        .init(event: "PreToolUse", script: "codex/hook.js", arg: "update.js pre", timeout: 5),
        .init(event: "PostToolUse", script: "codex/hook.js", arg: "update.js post", timeout: 5),
        .init(event: "Stop", script: "codex/hook.js", arg: "update.js stop", timeout: 5),
        .init(event: "PermissionRequest", script: "codex/hook.js", arg: "permission.js", timeout: 630),
    ]

    /// Observational events only: its PermissionRequest decision contract is
    /// unverified against permission.js, and a blocking hook must never be wired on
    /// faith. Timeouts here are milliseconds.
    static let qwen: [Event] = [
        .init(event: "SessionStart", script: "claude/lifecycle.js", arg: "start", timeout: 5000),
        .init(event: "SessionEnd", script: "claude/lifecycle.js", arg: "end", timeout: 5000),
        .init(event: "UserPromptSubmit", script: "claude/update.js", arg: "prompt", timeout: 5000),
        .init(event: "PreToolUse", script: "claude/update.js", arg: "pre", matcher: true, timeout: 5000),
        .init(event: "PostToolUse", script: "claude/update.js", arg: "post", matcher: true, timeout: 5000),
        // Qwen splits the failure paths into their own events; without them a turn
        // that errors out keeps animating as if it were still working.
        .init(event: "PostToolUseFailure", script: "claude/update.js", arg: "post", matcher: true, timeout: 5000),
        .init(event: "Stop", script: "claude/update.js", arg: "stop", timeout: 5000),
        .init(event: "StopFailure", script: "claude/update.js", arg: "fail", timeout: 5000),
    ]

    /// `timeout` is `timeoutSec`. `permissionRequest` sits above permission.js's own
    /// 600s wait for the same reason Claude's does.
    static let copilot: [Event] = [
        .init(event: "SessionStart", script: "claude/lifecycle.js", arg: "start", timeout: 5),
        .init(event: "SessionEnd", script: "claude/lifecycle.js", arg: "end", timeout: 5),
        .init(event: "UserPromptSubmit", script: "claude/update.js", arg: "prompt", timeout: 5),
        .init(event: "PreToolUse", script: "claude/update.js", arg: "pre", timeout: 5),
        .init(event: "PostToolUse", script: "claude/update.js", arg: "post", timeout: 5),
        // A failed tool call is still mid-turn: keep the session working.
        .init(event: "PostToolUseFailure", script: "claude/update.js", arg: "post", timeout: 5),
        .init(event: "Stop", script: "claude/update.js", arg: "stop", timeout: 5),
        // Only Copilot reports errors as their own event; update.js reads the
        // payload's `recoverable` so a retry doesn't end the turn early.
        .init(event: "ErrorOccurred", script: "claude/update.js", arg: "fail", timeout: 5),
        .init(event: "permissionRequest", script: "claude/permission.js", arg: nil, timeout: 630),
    ]

    /// Only observational events: the before* hooks gate permissions and belong to
    /// the user, not to a status bridge. The command is the script itself (shebang).
    static let cursor: [Event] = ["sessionStart", "sessionEnd", "preToolUse", "postToolUse",
                                  "afterAgentResponse", "stop"]
        .map { .init(event: $0, script: "cursor/cursor.js", arg: nil) }

    /// Timeouts in milliseconds. BeforeAgent gives "thinking" at turn start, so a
    /// no-tool turn still shows life.
    static let gemini: [Event] = ["SessionStart", "SessionEnd", "BeforeAgent", "BeforeTool",
                                  "AfterTool", "AfterAgent"]
        .map { .init(event: $0, script: "gemini/gemini.js", arg: nil, timeout: 5000) }

    /// The stdin payload carries no event name, so it rides along as the argument.
    /// PreToolUse is not decision-free — agy is fail-closed on it, so antigravity.js
    /// prints `{"decision":"allow"}` first.
    static let antigravity: [Event] = ["PreInvocation", "PreToolUse", "PostToolUse",
                                       "PostInvocation", "Stop"]
        .map { .init(event: $0, script: "antigravity/antigravity.js", arg: $0,
                     matcher: $0.hasSuffix("ToolUse"), timeout: 5) }

    /// Every agent wired through hook events. OpenCode is a plugin file, not events,
    /// and has no entry.
    static let agents: [String: [Event]] = [
        "claude": claude, "codex": codex, "qwen": qwen, "copilot": copilot,
        "cursor": cursor, "gemini": gemini, "antigravity": antigravity,
    ]

    static func events(for agent: String) -> [Event] { agents[agent] ?? [] }

    /// Whether the installer writes this event for an agent at `version`.
    static func wires(_ e: Event, version: String?) -> Bool {
        guard let since = e.since else { return true }
        guard let version, !version.isEmpty else { return false }
        return ClaudeModWiring.compare(version, since) != .orderedAscending
    }

    /// The command line for one event: `"<node>" "<hooks>/<script>" <arg>`, or the
    /// script alone when it runs through its own shebang.
    static func command(_ e: Event, hooksDir: String, node: String?) -> String {
        let script = "\"\(hooksDir)/\(e.script)\""
        let head = node.map { "\"\($0)\" \(script)" } ?? script
        return e.arg.map { "\(head) \($0)" } ?? head
    }

    // MARK: - Reading a config back

    /// One command found in a config, under the event it is filed under.
    struct Entry: Equatable {
        let event: String
        let words: [String]
    }

    struct Verdict: Equatable {
        enum Status: String { case ok, warn, fail }
        /// Something in the config runs one of AgentBar's scripts at all.
        var ours = false
        /// Events AgentBar needs that no entry answers with the right script.
        var missing: [String] = []
        /// Events where AgentBar's script sits but is not what belongs there.
        var misplaced: [String] = []

        var status: Status {
            guard ours else { return .fail }
            return missing.isEmpty && misplaced.isEmpty ? .ok : .warn
        }
    }

    /// The verdict on a config's text, or nil when it does not parse — the caller
    /// reports that on its own row. Comments, other keys and other tables are never
    /// read: only what the agent itself would run.
    static func verdict(agent: String, text: String) -> Verdict? {
        let needed = events(for: agent)
        let entries: [Entry]
        var ours = false
        if agent == "codex" {
            entries = codexEntries(text)
            // The notify bridge is AgentBar's too: Codex still reports through it.
            ours = codexNotifyIsOurs(text)
        } else {
            guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            else { return nil }
            entries = jsonEntries(root, agent: agent)
        }
        let dirs = Set(needed.map { hooksPathMarker + ($0.script.split(separator: "/").first.map(String.init) ?? "") + "/" })
        let mine = entries.filter { e in e.words.contains { w in dirs.contains { w.contains($0) } } }
        ours = ours || !mine.isEmpty

        var satisfied = Set<String>(), misplaced = Set<String>()
        for entry in mine {
            if needed.contains(where: { $0.event == entry.event && matches(entry.words, $0) }) {
                satisfied.insert(entry.event)
            } else {
                misplaced.insert(entry.event)
            }
        }
        return Verdict(ours: ours,
                       missing: needed.filter { $0.since == nil }.map(\.event).filter { !satisfied.contains($0) },
                       misplaced: misplaced.subtracting(satisfied).sorted())
    }

    /// The script, then its arguments, word for word.
    static func matches(_ words: [String], _ e: Event) -> Bool {
        guard let i = words.firstIndex(where: { $0.hasSuffix(hooksPathMarker + e.script) }) else { return false }
        let expected = e.arg.map { $0.split(separator: " ").map(String.init) } ?? []
        return Array(words[(i + 1)...].prefix(expected.count)) == expected
    }

    /// Every command under an event: `hooks.<Event>` for everyone, except Antigravity,
    /// whose top level is named rule groups. A rule carries its command itself
    /// (Cursor), in `hooks[]` (Claude, Qwen, Gemini, Antigravity), or as
    /// `exec` + `args` (Copilot).
    static func jsonEntries(_ root: [String: Any], agent: String) -> [Entry] {
        let tables: [[String: Any]] = agent == "antigravity"
            ? root.keys.sorted().compactMap { root[$0] as? [String: Any] }
            : [root["hooks"] as? [String: Any] ?? [:]]
        var out: [Entry] = []
        for table in tables {
            for (event, value) in table {
                guard let rules = value as? [[String: Any]] else { continue }
                for rule in rules {
                    for hook in [rule] + ((rule["hooks"] as? [[String: Any]]) ?? []) {
                        if let words = words(of: hook) { out.append(Entry(event: event, words: words)) }
                    }
                }
            }
        }
        return out
    }

    private static func words(of hook: [String: Any]) -> [String]? {
        if let command = hook["command"] as? String { return shellWords(command) }
        if let exec = hook["exec"] as? String {
            return [exec] + ((hook["args"] as? [Any]) ?? []).compactMap { $0 as? String }
        }
        if let bash = hook["bash"] as? String { return shellWords(bash) }
        return nil
    }

    /// Split the way a shell would for the commands the installers write: on
    /// whitespace, with single or double quotes holding a word together.
    static func shellWords(_ s: String) -> [String] {
        var out: [String] = [], word = "", quote: Character?, inWord = false
        var it = s.makeIterator()
        while let c = it.next() {
            if let q = quote {
                if c == q { quote = nil }
                else if c == "\\" && q == "\"", let n = it.next() { word.append(n) }
                else { word.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c; inWord = true
            } else if c == "\\", let n = it.next() {
                word.append(n); inWord = true
            } else if c.isWhitespace {
                if inWord { out.append(word); word = ""; inWord = false }
            } else {
                word.append(c); inWord = true
            }
        }
        if inWord { out.append(word) }
        return out
    }

    /// `command = "…"` lines under a `[[hooks.<Event>.hooks]]` header. A line-level
    /// reader rather than TOML: it only has to find what AgentBar's block (or a
    /// person copying its shape) writes, and a commented-out line starts with `#`
    /// and is never read.
    static func codexEntries(_ text: String) -> [Entry] {
        var current: String?
        var out: [Entry] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = capture(#"^\[\[\s*hooks\.([A-Za-z]+)\.hooks\s*\]\]"#, in: line)
                continue
            }
            guard let event = current,
                  let value = capture(#"^command\s*=\s*"((?:[^"\\]|\\.)*)""#, in: line) else { continue }
            out.append(Entry(event: event, words: shellWords(tomlUnescaped(value))))
        }
        return out
    }

    /// A top-level `notify = [...]` naming AgentBar's Codex bridge.
    static func codexNotifyIsOurs(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            String(line).range(of: #"^[ \t]*notify[ \t]*="#, options: .regularExpression) != nil
                && line.contains(hooksPathMarker + "codex/")
        }
    }

    /// The first capture group of `pattern` in `s`, if it matches.
    private static func capture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func tomlUnescaped(_ s: String) -> String {
        var out = "", it = s.makeIterator()
        while let c = it.next() {
            if c == "\\", let n = it.next() {
                switch n {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(n)
                }
            } else { out.append(c) }
        }
        return out
    }
}
