import Foundation

/// How the AgentBar Claude Code mod gets loaded: one entry in
/// `env.CLAUDE_CODE_PLUGIN_DIRS` of a Claude config dir's `settings.json` — the
/// absolute path of `~/.agentbar/mods/claude`, beside whatever plugin directories
/// the person lists there themselves (`:`-separated).
///
/// Pure, so the promises are tests: the person's own entries survive in order, a
/// second wiring changes nothing, wiring and unwiring gives back the object it
/// started from, and a value that is not what Claude Code reads (an `env` that is
/// not an object, a list where a string belongs) is refused, never "repaired".
///
/// An integration, not an agent: `claude-mod` is in `Diagnostics.integrations` and
/// never in `Agent.all`, and it is off until somebody switches it on
/// (`WiringPrefs.defaultOff`).
enum ClaudeModWiring {
    static let id = "claude-mod"
    static let envKey = "CLAUDE_CODE_PLUGIN_DIRS"
    /// What says an entry is ours. Any AgentBar mod directory counts, so an entry
    /// left by another copy's home (or an older layout) is replaced, not doubled.
    static let marker = "/.agentbar/mods/"
    /// The first Claude Code that loads a directory named in `CLAUDE_CODE_PLUGIN_DIRS`.
    static let minimumVersion = "2.1.287"

    /// `root` with our directory in `env.CLAUDE_CODE_PLUGIN_DIRS`: the person's own
    /// entries first and untouched, any AgentBar mod entry dropped, ours last.
    static func wired(_ root: [String: Any], modDir: String) -> (plan: PlanKind, root: [String: Any]) {
        var env: [String: Any]
        switch root["env"] {
        case nil: env = [:]
        case let e as [String: Any]: env = e
        default: return (.refused("`env` is not an object"), root)
        }
        let current: String?
        switch env[envKey] {
        case nil: current = nil
        case let s as String: current = s
        default: return (.refused("`env.\(envKey)` is not a string"), root)
        }
        let theirs = entries(current).filter { !$0.contains(marker) }
        let next = (theirs + [modDir]).joined(separator: ":")
        guard next != current else { return (.unchanged, root) }
        env[envKey] = next
        var out = root
        out["env"] = env
        return (.write, out)
    }

    /// `root` without any AgentBar mod entry; an emptied key goes, and an `env` left
    /// empty goes with it. Nothing of ours is `.unchanged` — never a rewrite.
    static func unwired(_ root: [String: Any]) -> (plan: PlanKind, root: [String: Any]) {
        guard var env = root["env"] as? [String: Any],
              let current = env[envKey] as? String else { return (.unchanged, root) }
        let all = entries(current)
        let theirs = all.filter { !$0.contains(marker) }
        guard theirs.count != all.count else { return (.unchanged, root) }
        if theirs.isEmpty { env.removeValue(forKey: envKey) } else { env[envKey] = theirs.joined(separator: ":") }
        var out = root
        if env.isEmpty { out.removeValue(forKey: "env") } else { out["env"] = env }
        return (.write, out)
    }

    enum PlanKind: Equatable {
        /// Nothing to write — already as it should be, or nothing of ours to remove.
        case unchanged
        case write
        /// A value of the wrong type where ours would go: left alone, with why.
        case refused(String)
    }

    /// The `:`-separated list, blanks dropped (`a::b` is two directories, not three).
    static func entries(_ value: String?) -> [String] {
        (value ?? "").split(separator: ":", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether this config already loads our mod.
    static func isWired(_ root: [String: Any]) -> Bool {
        guard let value = (root["env"] as? [String: Any])?[envKey] as? String else { return false }
        return entries(value).contains { $0.contains(marker) }
    }

    /// When the mod last wrote anything: the newest `mods.d/*.json` mtime. A file
    /// that does not parse still counts — the mod wrote it, which is the question.
    static func newestReport(in dir: URL = AgentBarHome.url("mods.d", isDirectory: true)) -> TimeInterval? {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 }
            .max()
    }

    // MARK: - The version gate

    /// Numeric dotted comparison; anything after the numbers (`-beta`) is ignored.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            let head = s.split(whereSeparator: { !$0.isNumber && $0 != "." }).first.map(String.init) ?? ""
            return head.split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// False only for a Claude Code known to be too old. Unknown is not a reason to
    /// refuse: the setting is an environment variable an older build simply ignores.
    static func supports(_ version: String?) -> Bool {
        guard let version, !version.isEmpty else { return true }
        return compare(version, minimumVersion) != .orderedAscending
    }

    /// `2.1.289` out of `claude --version`'s `2.1.289 (Claude Code)`.
    static func parseVersion(_ output: String) -> String? {
        output.split(whereSeparator: { $0 == " " || $0 == "\n" })
            .first { $0.first?.isNumber == true && $0.contains(".") }
            .map(String.init)
    }
}
