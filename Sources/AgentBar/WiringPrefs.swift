import Foundation

/// Which agents the user told AgentBar to leave alone.
///
/// The installer wires every agent it finds, on every launch — the right default,
/// and the wrong one for somebody who uses Cursor for one thing and wants AgentBar
/// nowhere near it. This is the list of exceptions, and it lives in a file rather
/// than in UserDefaults because the Linux CLI's `install-hooks` and `doctor` read
/// the same answer:
///
///     ~/.agentbar/wire-disabled
///     # comments and blank lines are ignored
///     cursor
///     gemini   # a trailing comment too
///
/// One agent id per line (the ids of `docs/protocol.md`). A token that is not an id
/// is skipped; an id this build does not know is kept, untouched, so a newer CLI's
/// agent survives an older app saving the file. Missing file means nothing is
/// disabled — exactly the behaviour before this existed. Written atomically, 0644.
enum WiringPrefs {
    static let fileName = "wire-disabled"

    static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        AgentBarHome.url(fileName, home: home)
    }

    /// The ids in `text`. Everything after a `#` is a comment; surrounding blanks go;
    /// anything that is not shaped like an agent id is ignored rather than trusted.
    static func parse(_ text: String) -> Set<String> {
        var out = Set<String>()
        // A byte-order mark in front of the first id: whether `String(contentsOf:)`
        // strips it depends on the Foundation underneath, so it is dropped here.
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let id = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard !id.isEmpty, id.range(of: #"^[a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil
            else { continue }
            out.insert(id)
        }
        return out
    }

    static func render(_ ids: Set<String>) -> String {
        (["# Agents AgentBar leaves unwired, one id per line.",
          "# Written by AgentBar (Settings > Agents) and the agentbar CLI."]
            + ids.sorted()).joined(separator: "\n") + "\n"
    }

    /// Unreadable reads as empty: the file is the user's opt-out, and failing to read
    /// it must not be worse than not having one — which is today's behaviour.
    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        guard let text = try? String(contentsOf: url(home: home), encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func isDisabled(_ id: String,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        load(home: home).contains(id)
    }

    /// An empty set removes the file, so "nothing disabled" has one spelling on disk.
    static func save(_ ids: Set<String>,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let fm = FileManager.default
        let target = url(home: home)
        guard !ids.isEmpty else {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            return
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(render(ids).utf8).write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
    }

    /// One integration on or off, everything else in both files — unknown ids
    /// included — kept. A default-off integration is switched by `wire-enabled`:
    /// on adds it there (and takes it out of `wire-disabled`, which would otherwise
    /// still win), off takes it out again — so "off" is, once more, the file not
    /// mentioning it.
    static func set(_ id: String, disabled: Bool,
                    home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        var ids = load(home: home)
        if defaultOff.contains(id) {
            var on = loadEnabled(home: home)
            if disabled { on.remove(id) } else { on.insert(id); ids.remove(id) }
            try saveEnabled(on, home: home)
            if ids != load(home: home) { try save(ids, home: home) }
            return
        }
        if disabled { ids.insert(id) } else { ids.remove(id) }
        try save(ids, home: home)
    }

    // MARK: - Integrations that start off

    /// Integrations nobody gets without asking. Every agent is wired the moment it is
    /// found; these are not, because what they put in place is more than a status
    /// bridge — the Claude Code mod runs inside Claude Code's own process.
    ///
    /// Opting in is a second file rather than a line seeded into `wire-disabled`, and
    /// that is deliberate. A seed has to remember it was planted: `wire-disabled`
    /// saved empty is *deleted*, so somebody who switched every agent back on would
    /// silently get the mod as well, and a fresh machine where the CLI runs first
    /// would need the CLI to plant it too. Here a missing line means off, in every
    /// reader, with nothing to remember. An older AgentBar never knew these ids,
    /// never wires them, and never reads `wire-enabled`.
    static let defaultOff: Set<String> = ["claude-mod"]
    static let enabledFileName = "wire-enabled"

    static func enabledURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        AgentBarHome.url(enabledFileName, home: home)
    }

    /// `wire-enabled`, read by exactly the rules of `wire-disabled`. Unreadable is
    /// empty: failing to read an opt-in must leave the integration off.
    static func loadEnabled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        guard let text = try? String(contentsOf: enabledURL(home: home), encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func renderEnabled(_ ids: Set<String>) -> String {
        (["# Integrations AgentBar wires only because you asked, one id per line.",
          "# Written by AgentBar (Settings > Agents) and the agentbar CLI."]
            + ids.sorted()).joined(separator: "\n") + "\n"
    }

    /// Empty removes the file, as `save` does.
    static func saveEnabled(_ ids: Set<String>,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let fm = FileManager.default
        let target = enabledURL(home: home)
        guard !ids.isEmpty else {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            return
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(renderEnabled(ids).utf8).write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
    }

    /// What every installer pass and every reader acts on: the ids switched off,
    /// plus each default-off integration nobody switched on. `wire-disabled` wins
    /// over `wire-enabled` — a line written there by hand turns anything off.
    static func effectiveDisabled(disabled: Set<String>, enabled: Set<String>) -> Set<String> {
        disabled.union(defaultOff.subtracting(enabled))
    }

    static func effectiveDisabled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        effectiveDisabled(disabled: load(home: home), enabled: loadEnabled(home: home))
    }
}
