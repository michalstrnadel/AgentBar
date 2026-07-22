import Foundation

/// Watches `~/.agentbar/state.d/` and publishes the current set of live sessions.
/// The folder is the whole protocol: hooks write one JSON per session, remove it on end.
final class SessionStore {
    static let stateDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentbar/state.d", isDirectory: true)

    /// Called on the main queue with sessions sorted by (priority, recency), most urgent first.
    var onChange: (([Session]) -> Void)?

    private var dirSource: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var lastSnapshot: [String] = []

    func start() {
        try? FileManager.default.createDirectory(at: Self.stateDir, withIntermediateDirectories: true)
        watchDirectory()
        // Fallback poll: catches editor-less writes, pid deaths, and a rebuilt watch after
        // the directory itself is replaced.
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    private func watchDirectory() {
        dirSource?.cancel()
        let fd = open(Self.stateDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            self?.refresh()
            if src.data.contains(.delete) || src.data.contains(.rename) {
                self?.watchDirectory() // directory replaced: re-arm on the new inode
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    func refresh() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.stateDir, includingPropertiesForKeys: nil)) ?? []
        var sessions: [Session] = []
        for url in files where url.pathExtension == "json" {
            guard let s = Session(fileURL: url) else { continue }
            // Prune: the owning agent process is gone, or the file is ancient (24h).
            let dead = s.pid > 0 && kill(s.pid, 0) != 0 && errno == ESRCH
            let stale = s.ts > 0 && Date().timeIntervalSince1970 - s.ts > 86_400
            if dead || stale {
                try? fm.removeItem(at: url)
                continue
            }
            guard s.started else { continue } // opened but never used: stays out of the menu
            sessions.append(s)
        }
        sessions.sort { ($0.priority, $0.ts) > ($1.priority, $1.ts) }

        // Only notify when something visible changed, so the menu bar isn't rebuilt every poll.
        let snapshot = sessions.map { "\($0.id):\($0.state.rawValue):\($0.label)" }
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onChange?(sessions)
    }
}
