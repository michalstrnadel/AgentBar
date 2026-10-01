import Foundation

/// The rules a human wrote down, in `~/.agentbar/rules.json`.
///
/// This file is the one place in AgentBar where a decision can be made without a
/// click, so two properties matter more than convenience:
///
/// - **It is a document the person owns.** Hand-editable, no counters written back
///   into it, no field AgentBar mutates behind their back. How often a rule fired
///   is derived from the ledger (`DecisionLedger`), which is the audit — the rules
///   file is the intent.
/// - **It is all-or-nothing.** One malformed rule refuses the whole file rather
///   than applying the rest. A policy file that is half in force is worse than one
///   that is not in force at all: the person believes they wrote four rules, three
///   are running, and nothing on screen says which. A refusal is loud —
///   `Diagnostics` names the file and the reason — and every prompt simply comes
///   back to the human, which is where the product lives without rules anyway.
enum RulesStore {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentbar/rules.json", isDirectory: false)

    /// The master switch. On by default and inert by default: with no rules file
    /// there is nothing to fire, so "on" costs nothing and the switch exists to
    /// stop everything at once without deleting what you wrote.
    static var enabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "rulesEnabled") != nil else { return true }
            return UserDefaults.standard.bool(forKey: "rulesEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "rulesEnabled") }
    }

    // MARK: - One rule

    struct Rule: Equatable {
        var id = ""
        var created: TimeInterval = 0
        /// allow | deny
        var decision = ""
        /// The agent id this applies to; empty means any.
        var agent = ""
        /// The ledger's normalised key — `DecisionLedger.shape(of:)`. Deliberately
        /// the same vocabulary: a second one would be a second thing to keep in
        /// sync, and this one already excludes arguments, paths and URLs.
        var shape = ""
        /// The working directory this applies in. Empty means anywhere, which is
        /// legal only for a denial — see `validate`.
        var cwd = ""
        var note = ""
        /// What a **denying** rule says to the agent when it refuses — "use pnpm in
        /// this repo". `note` is the person's own memo and never leaves the file;
        /// this one is sent, which is why it is a separate field and not a reuse:
        /// a note written as a reminder to yourself must not start arriving in an
        /// agent's context because a release changed what the field meant.
        /// Legal only on a denial — an approval has nothing to explain.
        var tell = ""
        var mode = Mode.on

        /// Off, watching, or answering. The middle one is the whole reason this is
        /// three states and not a checkbox: a rule that **approves** cannot be
        /// checked by reading it — you find out whether it matched what you pictured
        /// by watching it not answer for a week. Everything that enforces anything
        /// gets this, and an approving rule is the one thing in AgentBar that does.
        enum Mode: String, CaseIterable {
            case on, watch, off

            var title: String {
                switch self {
                case .on:    return "Answering"
                case .watch: return "Watching"
                case .off:   return "Off"
                }
            }

            /// What it does when a matching request arrives.
            var explanation: String {
                switch self {
                case .on:    return "Answers, and writes down that it did."
                case .watch: return "Answers nothing — writes down what it would have done, so you can check it before trusting it."
                case .off:   return "Does nothing at all. Still here."
                }
            }
        }

        var isAllow: Bool { decision == "allow" }
        /// Only an `on` rule ever writes an answer.
        var answers: Bool { mode == .on }

        var json: [String: Any] {
            ["id": id, "created": Int(created), "decision": decision, "agent": agent,
             "shape": shape, "cwd": cwd, "note": note, "tell": tell, "mode": mode.rawValue]
        }

        init() {}

        init(id: String, decision: String, shape: String, cwd: String = "",
             agent: String = "", note: String = "", tell: String = "", mode: Mode = .on,
             created: TimeInterval = Date().timeIntervalSince1970) {
            self.id = id; self.decision = decision; self.shape = shape; self.cwd = cwd
            self.agent = agent; self.note = note; self.tell = tell; self.mode = mode
            self.created = created
        }

        init?(json o: [String: Any]) {
            guard let id = o["id"] as? String, let decision = o["decision"] as? String,
                  let shape = o["shape"] as? String else { return nil }
            self.id = id
            self.decision = decision
            self.shape = shape
            // A hand-edited `created` of NaN or `1e19` would trap in `json`'s `Int(_:)`
            // the next time the file is written; a time that is not one reads as none.
            created = Session.plausibleTime(o["created"])
            agent = o["agent"] as? String ?? ""
            cwd = o["cwd"] as? String ?? ""
            note = o["note"] as? String ?? ""
            tell = o["tell"] as? String ?? ""
            // An unreadable `mode` is not defaulted to `on`: a file somebody edited
            // by hand and got wrong must not silently start answering. `validate`
            // turns this into a refusal of the whole file.
            mode = Mode(rawValue: o["mode"] as? String ?? Mode.on.rawValue) ?? .off
            if o["mode"] != nil, Mode(rawValue: o["mode"] as? String ?? "") == nil {
                badMode = o["mode"] as? String ?? "(not a string)"
            }
        }

        /// Set when `mode` was present and unreadable, so `validate` can name it.
        var badMode: String?
    }

    // MARK: - Reading

    /// What the file says. `.none` is the ordinary state — most people have no
    /// rules — and is not an error.
    enum Load: Equatable {
        case none
        case rules([Rule])
        /// The file exists and cannot be trusted. The string is shown to the person.
        case invalid(String)

        var rules: [Rule] {
            if case .rules(let r) = self { return r }
            return []
        }
    }

    /// The version this build writes and the only one it will read. A file from a
    /// newer AgentBar is refused rather than half-understood: unknown fields could
    /// be the ones that narrow a rule.
    static let version = 1

    static func load(url: URL = RulesStore.fileURL) -> Load {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard let data = try? Data(contentsOf: url) else {
            return .invalid("~/.agentbar/rules.json could not be read.")
        }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalid("~/.agentbar/rules.json is not valid JSON.")
        }
        let v = (o["v"] as? NSNumber)?.intValue ?? 0
        guard v == version else {
            return .invalid("~/.agentbar/rules.json says version \(v); this AgentBar reads version \(version).")
        }
        guard let list = o["rules"] as? [[String: Any]] else {
            return .invalid("~/.agentbar/rules.json has no `rules` list.")
        }
        var out: [Rule] = []
        var seen = Set<String>()
        for (i, entry) in list.enumerated() {
            guard let rule = Rule(json: entry) else {
                return .invalid("Rule \(i + 1) in ~/.agentbar/rules.json is missing `id`, `decision` or `shape`.")
            }
            if let reason = validate(rule, index: i, seen: seen) { return .invalid(reason) }
            seen.insert(rule.id)
            out.append(rule)
        }
        return .rules(out)
    }

    /// Why a rule is refused. Returns nil when it is fine.
    static func validate(_ r: Rule, index i: Int, seen: Set<String>) -> String? {
        let where_ = "Rule \(i + 1) (\(r.id.isEmpty ? "no id" : r.id)) in ~/.agentbar/rules.json"
        if r.id.isEmpty { return "\(where_) has an empty `id`." }
        if seen.contains(r.id) { return "\(where_) repeats an `id` used above." }
        if r.decision != "allow" && r.decision != "deny" {
            return "\(where_) says `decision: \(r.decision)`; it must be \"allow\" or \"deny\"."
        }
        if r.shape.isEmpty { return "\(where_) has an empty `shape`." }
        // The asymmetry is the whole safety posture: refusing more is always safe,
        // approving more is not. A denial may cover every repository on the
        // machine; an approval names one.
        if r.isAllow && r.cwd.isEmpty {
            return "\(where_) approves without naming a directory. An approving rule must name one; only a denial may apply everywhere."
        }
        if !r.cwd.isEmpty && !r.cwd.hasPrefix("/") {
            return "\(where_) has a `cwd` that is not an absolute path."
        }
        // Refused rather than tidied, like everything else here. `RuleEngine` compares
        // directories as text, so `/x/repo/` would never match a session in `/x/repo`
        // and `/x/repo/../other` names somewhere the person did not write down.
        // Rewriting either behind their back would make the file say one thing and
        // the engine do another.
        if !r.cwd.isEmpty && normalisedCwd(r.cwd) != r.cwd {
            return "\(where_) has a `cwd` that is not written plainly — no trailing `/`, `//`, `.` or `..`. Write it as \(normalisedCwd(r.cwd))."
        }
        if r.isAllow && !r.tell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(where_) approves and carries `tell`; only a denial says anything to the agent."
        }
        if let bad = r.badMode {
            return "\(where_) says `mode: \(bad)`; it must be \"on\", \"watch\" or \"off\"."
        }
        return nil
    }

    /// An absolute path written the one way `RuleEngine` can compare: no empty,
    /// `.` or `..` components and no trailing slash. Purely textual — symlinks are
    /// not followed, because the engine sees the directory the agent reports, not
    /// the one the disk resolves it to.
    static func normalisedCwd(_ path: String) -> String {
        var out: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !out.isEmpty { out.removeLast() }
            default: out.append(part)
            }
        }
        return "/" + out.joined(separator: "/")
    }

    /// `load()` memoised on `(mtime, size)`, the same way `DecisionLedger.cached()`
    /// is: the engine is asked about every pending request on every directory event
    /// and every two-second poll, and none of those is a reason to re-read a file
    /// that has not changed.
    static func cached(url: URL = RulesStore.fileURL) -> Load {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                     (attrs?[.size] as? Int) ?? 0)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let c = cache, c.url == url.path, c.stamp == stamp { return c.load }
        let load = load(url: url)
        cache = (url.path, stamp, load)
        return load
    }

    private static let cacheLock = NSLock()
    private static var cache: (url: String, stamp: (TimeInterval, Int), load: Load)?

    // MARK: - Writing

    @discardableResult
    static func save(_ rules: [Rule], to url: URL = RulesStore.fileURL) -> Bool {
        let body: [String: Any] = ["v": version, "rules": rules.map(\.json)]
        guard let data = try? JSONSerialization.data(withJSONObject: body,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".\(ProcessInfo.processInfo.processIdentifier).tmp")
            try data.write(to: tmp)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
            return true
        } catch {
            NSLog("AgentBar: rules not written to \(url.path): \(error)")
            return false
        }
    }

    /// Short, readable, and unique enough for a file a person edits by hand.
    static func newID() -> String {
        "r-" + String(format: "%06x", Int.random(in: 0..<0x100_0000))
    }
}
