import Foundation

/// The lock around every append to and every prune of the two journals,
/// `history.jsonl` and `decisions.jsonl`, shared with the Linux CLI.
///
/// A prune reads the file and renames a shorter copy over it. An append that lands
/// between the read and the rename goes into the file being replaced and is gone —
/// a rule's ledger row included, which is the row rule 3 promises always exists. An
/// `NSLock` closed that inside the app; the CLI on a shared home writes the same
/// files, so the lock has to be one both halves can see.
///
/// It is `flock(2)` on a sidecar, `<journal>.lock` (docs/protocol.md, "Locking the
/// journals"). A sidecar because the journal itself is replaced by every prune: a
/// lock on the old inode would not exclude a writer that opened the new one. `flock`
/// because the kernel drops it when its holder dies, so there is no stale lock to
/// detect and no pid to trust.
///
/// The wait is bounded. Nothing in the app may hang on a CLI that was stopped while
/// holding it: past `wait`, an append goes ahead the way it always did, and a prune
/// steps aside until next time — the other writer is the one pruning.
enum JournalLock {
    enum Outcome: Equatable {
        /// Held across processes for the whole body.
        case held
        /// Somebody else held it for the whole wait.
        case busy
        /// The sidecar could not be opened, so there is nothing to coordinate on.
        case unavailable
    }

    static let wait: TimeInterval = 2

    static func sidecar(for journal: URL) -> URL {
        journal.deletingLastPathComponent().appendingPathComponent(journal.lastPathComponent + ".lock")
    }

    /// Runs `body` holding `inProcess` and, if it can be had within `wait`, the
    /// cross-process lock on `journal`'s sidecar. `body` learns which.
    static func around<T>(_ journal: URL, inProcess: NSLock, wait: TimeInterval = JournalLock.wait,
                          _ body: (Outcome) -> T) -> T {
        inProcess.lock()
        defer { inProcess.unlock() }
        try? FileManager.default.createDirectory(at: journal.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let fd = open(sidecar(for: journal).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return body(.unavailable) }
        // Closing the descriptor is what releases the lock, so there is no unlock
        // path to forget.
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { return body(.unavailable) }
            guard Date() < deadline else { return body(.busy) }
            usleep(10_000)
        }
        return body(.held)
    }
}
