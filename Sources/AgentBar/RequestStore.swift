import Foundation

/// Watches `~/.agentbar/requests.d/` — one JSON per permission request a blocking
/// hook is currently waiting on. Same folder-is-the-protocol pattern as SessionStore.
final class RequestStore {
    static let requestsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentbar/requests.d", isDirectory: true)
    static let answersDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentbar/answers.d", isDirectory: true)

    /// Longest a request can be pending: the hook's 600s wait plus slack.
    private static let maxAge: TimeInterval = 660

    private(set) var requests: [ApprovalRequest] = []
    var onChange: (() -> Void)?

    private var dirSource: DispatchSourceFileSystemObject?
    private var lastSnapshot: [String] = []

    func start() {
        try? FileManager.default.createDirectory(at: Self.requestsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.answersDir, withIntermediateDirectories: true)
        watchDirectory()
        refresh()
    }

    private func watchDirectory() {
        dirSource?.cancel()
        let fd = open(Self.requestsDir.path, O_EVTONLY)
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
        let files = (try? fm.contentsOfDirectory(at: Self.requestsDir, includingPropertiesForKeys: nil)) ?? []
        var found: [ApprovalRequest] = []
        for url in files where url.pathExtension == "json" {
            guard let r = ApprovalRequest(fileURL: url) else { continue }
            // Orphans: the waiting hook died (SIGKILL leaves no cleanup), or expired.
            let watched = r.hookPid > 0 ? r.hookPid : r.pid
            let dead = watched > 0 && kill(watched, 0) != 0 && errno == ESRCH
            let expired = r.ts > 0 && Date().timeIntervalSince1970 - r.ts > Self.maxAge
            if dead || expired {
                try? fm.removeItem(at: url)
                continue
            }
            found.append(r)
        }
        found.sort { $0.ts > $1.ts }
        pruneOrphanAnswers(liveNames: Set(found.map(\.fileName)))

        let snapshot = found.map(\.fileName)
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        requests = found
        onChange?()
    }

    func requests(for sessionId: String) -> [ApprovalRequest] {
        requests.filter { $0.sessionId == sessionId }
    }

    /// Answers nobody consumed (hook died between click and pickup): delete after 60s.
    private func pruneOrphanAnswers(liveNames: Set<String>) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.answersDir,
                     includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where !liveNames.contains(url.lastPathComponent) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > 60 {
                try? fm.removeItem(at: url)
            }
        }
    }
}
