import Foundation

/// What AgentBar keeps before it writes into an agent's settings, and what it
/// remembers having written.
///
/// The installer has always been careful about *how* it writes — it refuses a file
/// it cannot parse, it writes atomically, it skips a write that changes nothing.
/// What it never did was leave the person a way back or a way to look. It runs on
/// every launch, it edits `~/.claude/settings.json` and half a dozen files like it,
/// and the only trace was one line in Console.app. A user who found their settings
/// reformatted had no original to compare against and no record of what moved.
///
/// So every real write goes through here, and three things happen in order:
///
/// 1. The file as it was is copied **next to itself**, named
///    `settings.json.agentbar-bak-20261001-142233` (local time). Next to it rather
///    than under `~/.agentbar`, because that is where somebody looks for it, and
///    because Claude's settings can carry API keys in `env` — a copy that stays in
///    the same directory, with the same permissions, is not a new place for a
///    secret to live. The suffix also matters for the two directories an agent
///    *scans*: Copilot loads every `*.json` under `hooks/`, and a name ending in a
///    timestamp is not one of them.
/// 2. Only the newest `keep` of AgentBar's own backups of that file stay. A launch
///    that rewrote a file every time would otherwise grow a directory of them; and
///    nothing that does not carry exactly this suffix-and-stamp is ever deleted.
/// 3. The unified diff is appended to `~/.agentbar/config-changes.json`, which is
///    what **Settings ▸ Diagnostics ▸ What changed…** reads.
///
/// None of it happens on a write that would change nothing: no backup, no record,
/// no mtime touched. A launch that finds everything already wired leaves no trace,
/// which is the only way a backup directory stays worth reading.
enum ConfigBackup {
    static let marker = ".agentbar-bak-"
    /// Three: enough to step back past a launch that went wrong and the one before
    /// it, few enough that nobody has to clean up after AgentBar.
    static let keep = 3
    /// The record keeps the last this-many writes. Old ones go; the backups beside
    /// each file outlive them anyway.
    static let recordLimit = 20
    /// A diff bigger than this is stored cut, with a line saying so. A first install
    /// into a large hand-formatted file is the whole file twice over, and the record
    /// is a list for reading, not an archive — the backup is the archive.
    static let diffLimit = 64 * 1024

    static var defaultLog: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentbar/config-changes.json")
    }

    /// One write AgentBar made (or, from a preview pass, would make).
    struct Record: Codable, Equatable {
        /// The file written.
        let path: String
        /// The copy of what was there before. Nil when there was nothing: a file
        /// AgentBar created has no original to keep.
        let backup: String?
        /// Seconds since 1970.
        let ts: Double
        /// `diff -u` of before → after.
        let diff: String
        /// The agent whose settings these are (`Agent` ids). Nil in records written
        /// before 1.32 — the key is simply absent there, and encoding leaves it out
        /// again when nil, so old and new `config-changes.json` read each other.
        var agent: String? = nil
    }

    // MARK: - Names

    /// `yyyyMMdd-HHmmss`, local time, fixed width — which is what makes the names
    /// sort by age as plain strings.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// The backup's file name. Two writes in the same second (a Re-install click on
    /// top of a launch) get `-1`, `-2` rather than one overwriting the other — the
    /// earlier copy is the one that is the person's original.
    static func backupName(for file: String, at date: Date, taken: Set<String> = []) -> String {
        let base = file + marker + stamp(date)
        guard taken.contains(base) else { return base }
        var n = 1
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// AgentBar's own backups of `file` among `names`, oldest first. Only names that
    /// are exactly `file` + marker + a stamp (+ an optional `-n`) count — a file the
    /// person called `settings.json.agentbar-bak-mine` is theirs and stays.
    static func backups(of file: String, among names: [String]) -> [String] {
        let prefix = file + marker
        let stamp = #"^[0-9]{8}-[0-9]{6}(-[0-9]+)?$"#
        return names.filter {
            $0.hasPrefix(prefix)
                && String($0.dropFirst(prefix.count)).range(of: stamp, options: .regularExpression) != nil
        }.sorted(by: olderFirst)
    }

    /// The backups past the newest `keep`, which is what rotation deletes.
    static func expired(of file: String, among names: [String], keep: Int = keep) -> [String] {
        let ours = backups(of: file, among: names)
        return Array(ours.prefix(max(0, ours.count - keep)))
    }

    /// By stamp, then by the same-second counter as a number — `-10` is newer than
    /// `-9`, which a plain string compare gets backwards.
    private static func olderFirst(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> (String, Int) {
            let tail = s.suffix(from: s.range(of: marker, options: .backwards)!.upperBound)
            let stamp = String(tail.prefix(15))
            let n = tail.count > 16 ? Int(tail.dropFirst(16)) ?? 0 : 0
            return (stamp, n)
        }
        let (ka, kb) = (key(a), key(b))
        return ka.0 != kb.0 ? ka.0 < kb.0 : ka.1 < kb.1
    }

    // MARK: - Writing

    /// One lock for every pass: a launch and a **Re-install** click can run at the
    /// same moment, and both append to the same record.
    private static let lock = NSLock()

    /// What writing `data` to `url` would change, without writing it. Nil when it
    /// would change nothing.
    static func preview(_ data: Data, for url: URL, now: Date = Date(),
                        agent: String? = nil) -> Record? {
        let before = try? Data(contentsOf: url)
        guard before != data else { return nil }
        return Record(path: url.path, backup: nil, ts: now.timeIntervalSince1970,
                      diff: diff(before: before, after: data, path: url.path), agent: agent)
    }

    /// What deleting `url` would change. Nil when there is no file to delete.
    static func previewRemoval(of url: URL, now: Date = Date(), agent: String? = nil) -> Record? {
        guard let before = try? Data(contentsOf: url) else { return nil }
        return Record(path: url.path, backup: nil, ts: now.timeIntervalSince1970,
                      diff: diff(before: before, after: nil, path: url.path), agent: agent)
    }

    /// Back up, write atomically, record. Returns nil — and has done nothing at all —
    /// when the file already holds exactly `data`.
    @discardableResult
    static func write(_ data: Data, to url: URL, now: Date = Date(),
                      log: URL? = defaultLog, keep: Int = keep,
                      agent: String? = nil) throws -> Record? {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        // A dotfiles setup makes `~/.claude/settings.json` a link into a repo, and an
        // atomic write *replaces* the path it is given — the link would become a
        // plain file and the repo would stop being the settings. So the write goes
        // to what the link points at. The backup still goes next to the link: that
        // is where somebody looks for it, and a copy of settings that can hold API
        // keys has no business appearing as a new untracked file in a git repo.
        let destination = linkTarget(of: url)
        let before = try? Data(contentsOf: destination)
        if before == data { return nil }

        var backup: URL?
        if before != nil {
            let dir = url.deletingLastPathComponent()
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let name = backupName(for: url.lastPathComponent, at: now, taken: Set(names))
            let target = dir.appendingPathComponent(name)
            // A copy, not a move: the original stays in place until the atomic write
            // replaces it, so an agent reading its settings mid-pass never finds none.
            // `copyItem` keeps the original's permissions.
            try fm.copyItem(at: destination, to: target)
            backup = target
        }
        try data.write(to: destination, options: .atomic)
        if backup != nil { rotate(url, keep: keep) }

        let record = Record(path: url.path, backup: backup?.path, ts: now.timeIntervalSince1970,
                            diff: diff(before: before, after: data, path: url.path), agent: agent)
        if let log { append(record, to: log) }
        return record
    }

    /// A file AgentBar owns outright (Copilot's `hooks/agentbar.json`, OpenCode's
    /// plugin) taken away when its agent is switched off: kept beside itself first,
    /// exactly as a rewrite would be, then deleted, then recorded. Nil — and nothing
    /// done — when there is no file.
    @discardableResult
    static func remove(_ url: URL, now: Date = Date(), log: URL? = defaultLog,
                       keep: Int = keep, agent: String? = nil) throws -> Record? {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let destination = linkTarget(of: url)
        guard let before = try? Data(contentsOf: destination) else { return nil }
        let dir = url.deletingLastPathComponent()
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let target = dir.appendingPathComponent(
            backupName(for: url.lastPathComponent, at: now, taken: Set(names)))
        try fm.copyItem(at: destination, to: target)
        // The path itself, not what a link points at: removing the link is what takes
        // the file out of the directory the agent scans.
        try fm.removeItem(at: url)
        rotate(url, keep: keep)
        let record = Record(path: url.path, backup: target.path, ts: now.timeIntervalSince1970,
                            diff: diff(before: before, after: nil, path: url.path), agent: agent)
        if let log { append(record, to: log) }
        return record
    }

    private static func rotate(_ url: URL, keep: Int) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for old in expired(of: url.lastPathComponent, among: names, keep: keep) {
            try? fm.removeItem(at: dir.appendingPathComponent(old))
        }
    }

    /// The file a path finally names, following links on its last component — the
    /// one an atomic write would replace. A relative link is relative to the
    /// directory holding it. A link whose target does not exist yet still names
    /// that target, so the write creates it there (or fails loudly) instead of
    /// replacing the link. Directory links need nothing: a write through them
    /// lands where they point already.
    static func linkTarget(of url: URL) -> URL {
        let fm = FileManager.default
        var current = url
        // A loop of links is not a file; forty hops is the kernel's own patience.
        for _ in 0..<40 {
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: current.path) else { break }
            current = dest.hasPrefix("/")
                ? URL(fileURLWithPath: dest)
                : current.deletingLastPathComponent().appendingPathComponent(dest)
        }
        return current.standardizedFileURL
    }

    /// `after` nil is a deletion, labelled the way `diff -u` labels one.
    static func diff(before: Data?, after: Data?, path: String) -> String {
        let old = before.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let new = after.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let text = LineDiff.unified(old: old, new: new,
                                    oldLabel: before == nil ? "/dev/null" : path,
                                    newLabel: after == nil ? "/dev/null" : path)
        guard text.utf8.count > diffLimit else { return text }
        let cut = String(decoding: text.utf8.prefix(diffLimit), as: UTF8.self)
        return cut + "\n⋯ cut here; the backup beside the file has all of it\n"
    }

    // MARK: - The record

    /// Newest first. An unreadable or missing record is an empty one — it is a
    /// convenience for reading, and the backups beside the files do not depend on it.
    static func recent(log: URL = defaultLog) -> [Record] {
        guard let data = try? Data(contentsOf: log),
              let rows = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return rows.reversed()
    }

    private static func append(_ record: Record, to log: URL) {
        var rows: [Record] = recent(log: log).reversed()
        rows.append(record)
        if rows.count > recordLimit { rows.removeFirst(rows.count - recordLimit) }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try data.write(to: log, options: .atomic)
            // The diffs quote the settings they came from, and those can hold a
            // token. The files themselves are the user's to permission; this copy of
            // their lines is ours, so it is readable by them alone.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
        } catch {
            NSLog("AgentBar: could not record a settings change in \(log.path): \(error)")
        }
    }
}
