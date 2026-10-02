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

    /// One agent on or off, everything else in the file — unknown ids included — kept.
    static func set(_ id: String, disabled: Bool,
                    home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        var ids = load(home: home)
        if disabled { ids.insert(id) } else { ids.remove(id) }
        try save(ids, home: home)
    }
}
