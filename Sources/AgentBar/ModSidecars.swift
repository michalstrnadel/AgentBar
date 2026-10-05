import Foundation

/// The `mods.d/` folder: one sidecar per Claude Code session the AgentBar mod
/// sees, read for `SessionStore` and tidied up after (`docs/protocol.md`, "mods.d").
///
/// Two things make it different from `state.d`. The mod rewrites its file **in
/// place** — Claude Code gives a mod no rename — so a read can land on half a
/// file; the answer is to keep the last report that parsed and wait for the next
/// write, which is never more than a few seconds off. And the mod **cannot delete**
/// its file, so this is where a sidecar is removed: once its session's `state.d`
/// row is gone and either the session ended or the file is a day old.
///
/// Polled, not watched. `SessionStore` already refreshes on every `state.d` event
/// — and Claude Code's hooks write `state.d` on every turn — plus a 2 s timer, and
/// that is the cadence this needs: a context percentage and a quota window move
/// over minutes. A directory watch would not even see the writes (an in-place
/// rewrite touches the file, not the folder), and one watch per file would fire
/// mid-write, which is exactly when the file is least worth reading. A pass costs
/// one `stat` per sidecar; a file is read again only when its size or mtime moved.
final class ModSidecars {
    static let defaultDirectory = AgentBarHome.url("mods.d", isDirectory: true)

    /// What a pass found. `reports` holds the last good report of every sidecar on
    /// disk; `changed` only those whose content differs from the previous pass, so
    /// the ledger ingest and the quota look at what moved; `pruned` the sessions
    /// whose files this pass removed.
    struct Pass {
        var reports: [String: ModReport] = [:]
        var changed: [ModReport] = []
        var pruned: [String] = []
    }

    /// The mod cannot remove its own file, so a frontend does once the session row
    /// is gone and the file has been quiet this long (or says the session ended).
    static let orphanAge: TimeInterval = 86_400
    /// A file that will not parse is read again on every pass for this long —
    /// long enough for the writer to finish — and then left alone until it changes.
    static let tornGrace: TimeInterval = 10

    let directory: URL
    private var stamps: [String: Stamp] = [:]
    private var reports: [String: ModReport] = [:]
    private var loggedUnreadable: Set<String> = []

    private struct Stamp: Equatable {
        var mtime: TimeInterval
        var size: Int
    }

    static let promptedPrefix = ".prompted-"

    init(directory: URL = ModSidecars.defaultDirectory) {
        self.directory = directory
    }

    /// One pass. `sessionIDs` are the `state.d` rows still on disk — whatever
    /// their state, started or not — because a sidecar is an orphan only once its
    /// row is gone.
    func refresh(sessionIDs: Set<String>, now: TimeInterval = Date().timeIntervalSince1970) -> Pass {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [])) ?? []
        var pass = Pass()
        var present: Set<String> = []
        // `.prompted-<id>`, the permission hook's note to the mod that a prompt was
        // due (docs/protocol.md, "mods.d"). Its session's row gone, it is done with.
        for url in files where url.lastPathComponent.hasPrefix(Self.promptedPrefix) {
            let id = String(url.lastPathComponent.dropFirst(Self.promptedPrefix.count))
            if !sessionIDs.contains(id) { try? fm.removeItem(at: url) }
        }
        for url in files where url.pathExtension == "json"
            && !url.lastPathComponent.hasPrefix(".") {     // our own `.ingested.json`
            let id = url.deletingPathExtension().lastPathComponent
            present.insert(id)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let stamp = Stamp(mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                              size: values?.fileSize ?? 0)
            if stamps[id] != stamp {
                if stamp.size <= ModReport.maxBytes, let data = try? Data(contentsOf: url),
                   let report = ModReport.decode(data, sessionId: id) {
                    if reports[id] != report { pass.changed.append(report) }
                    reports[id] = report
                    stamps[id] = stamp
                    loggedUnreadable.remove(id)
                } else if now - stamp.mtime > Self.tornGrace {
                    // Not a write in progress: it has been like this for a while.
                    // Left alone until it changes, and said once.
                    stamps[id] = stamp
                    if loggedUnreadable.insert(id).inserted {
                        NSLog("AgentBar: unreadable mod sidecar, skipped: \(url.lastPathComponent)")
                    }
                }
                // Otherwise a torn write: the last good report stands, and the
                // file is read again on the next pass.
            }
            if !sessionIDs.contains(id), Self.isOrphan(reports[id], fileMtime: stamp.mtime, now: now) {
                try? fm.removeItem(at: url)
                present.remove(id)
                pass.pruned.append(id)
            }
        }
        // Whatever is no longer on disk — pruned here, or by another frontend —
        // takes its memory with it.
        for id in Set(reports.keys).subtracting(present) { reports[id] = nil }
        for id in Set(stamps.keys).subtracting(present) { stamps[id] = nil }
        loggedUnreadable.formIntersection(present)
        pass.reports = reports
        return pass
    }

    /// A sidecar with no session row is removed once the session said it ended, or
    /// once it has been quiet for a day. One that never parsed goes by the file's
    /// own age, so junk does not stay forever.
    static func isOrphan(_ report: ModReport?, fileMtime: TimeInterval, now: TimeInterval) -> Bool {
        if let report {
            return report.ended || now - report.ts > orphanAge
        }
        return fileMtime > 0 && now - fileMtime > orphanAge
    }
}
