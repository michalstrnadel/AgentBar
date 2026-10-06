import Foundation

/// Watches `~/.agentbar/requests.d/` — one JSON per permission request a blocking
/// hook is currently waiting on. Same folder-is-the-protocol pattern as SessionStore.
final class RequestStore {
    static let requestsDir = AgentBarHome.url("requests.d", isDirectory: true)
    static let answersDir = AgentBarHome.url("answers.d", isDirectory: true)

    /// Longest a request can be pending: the hook's default 600s wait plus slack.
    /// (A raised AGENTBAR_APPROVAL_TIMEOUT outlives this and gets pruned early —
    /// accepted: the hook still answers the terminal prompt path on its own.)
    private static let maxAge: TimeInterval = 660

    private(set) var requests: [ApprovalRequest] = []
    var onChange: (() -> Void)?
    /// Asked about every request before it is published. Returning true means it
    /// has been answered already — by a rule the human wrote — and must not be
    /// shown as pending. Asked *before* publication on purpose: a card that
    /// appears and vanishes 100 ms later is a worse way to learn a rule fired than
    /// never seeing it, and the rule's own trace is where that belongs.
    ///
    /// The store itself knows nothing about rules; `main.swift` supplies this.
    var answeredElsewhere: ((ApprovalRequest) -> Bool)?

    private var dirSource: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var lastSnapshot: [String] = []

    func start() {
        // A request carries the whole command and the tool's input, and an answer
        // decides one: both folders are this user's alone, including ones an older
        // version made with the default mode.
        for dir in [Self.requestsDir, Self.answersDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        watchDirectory()
        // Fallback poll, same as SessionStore: dead-hook pruning, maxAge expiry, and
        // orphan-answer GC are time-based and must run without a directory event —
        // and it re-arms a dropped watch (see SessionStore).
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.dirSource == nil { self.watchDirectory() }
            self.refresh()
        }
        refresh()
    }

    private func watchDirectory() {
        dirSource?.cancel()
        dirSource = nil
        let fd = open(Self.requestsDir.path, O_EVTONLY)
        guard fd >= 0 else { return } // dir missing right now; the poll retries
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
            guard Self.isLive(r) else {
                try? fm.removeItem(at: url)
                continue
            }
            found.append(r)
        }
        // Every live request, whoever ends up answering it: the memory that stops
        // a rule answering the same request twice is keyed off this.
        let live = Set(found.map(\.identity))
        if let answeredElsewhere {
            found.removeAll { answeredElsewhere($0) }
        }
        RuleEngine.shared.forget(keeping: live)
        found.sort { $0.ts > $1.ts }
        pruneOrphanAnswers(liveNames: Set(found.map(\.fileName)))

        // Name, timestamp AND the waiting hook's pid: a request replaced under
        // the same file name (the hook reuses session+prompt ids within a turn)
        // is a different request, and frontends must see it — stale wizard
        // state keyed to the old one has to reset. `ts` alone is not enough:
        // it has one-second resolution, so a fast replacement looks identical.
        // Two hook processes never share a pid.
        let snapshot = found.map { "\($0.fileName):\($0.ts):\($0.hookPid)" }
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        requests = found
        onChange?()
    }

    /// Whether a hook is still waiting on this request. Orphans are the ones whose
    /// hook died (SIGKILL leaves no cleanup) or that outlived the longest wait.
    static func isLive(_ r: ApprovalRequest) -> Bool {
        let watched = r.hookPid > 0 ? r.hookPid : r.pid
        let dead = watched > 0 && kill(watched, 0) != 0 && errno == ESRCH
        let expired = r.ts > 0 && Date().timeIntervalSince1970 - r.ts > Self.maxAge
        return !dead && !expired
    }

    /// Live requests on disk, read without a running store and without touching
    /// anything — for the updater at launch, before any store has started. A
    /// request a rule is about to answer still counts: waiting is the safe guess.
    static func pendingOnDisk() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: requestsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap(ApprovalRequest.init(fileURL:))
            .filter(isLive).count
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
