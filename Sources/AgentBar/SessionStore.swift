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
    /// nil until the first refresh, so the launch snapshot always reaches
    /// onChange — even when it is empty. Consumers that prime on the first
    /// delivery (SoundCenter) would otherwise mistake the first real session
    /// for the launch state.
    private var lastSnapshot: [String]?
    /// Paths already reported as unreadable — `refresh()` runs on every fs event, so a
    /// permanently corrupt file must be logged once, not on every tick.
    private var loggedUnreadable: Set<String> = []

    func start() {
        try? FileManager.default.createDirectory(at: Self.stateDir, withIntermediateDirectories: true)
        watchDirectory()
        // Fallback poll: catches editor-less writes and pid deaths — and re-arms a
        // dropped watch (the directory can be gone at the moment the re-open runs;
        // without a retry, fs-event responsiveness would silently stay dead).
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
        let fd = open(Self.stateDir.path, O_EVTONLY)
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
        let files = (try? fm.contentsOfDirectory(at: Self.stateDir, includingPropertiesForKeys: nil)) ?? []
        var sessions: [Session] = []
        var present: Set<String> = []
        for url in files where url.pathExtension == "json" {
            present.insert(url.path)
            guard let s = Session(fileURL: url) else {
                // A torn write self-heals on the next hook write; a corrupt one would
                // otherwise make the session invisible with no trace at all.
                if loggedUnreadable.insert(url.path).inserted {
                    NSLog("AgentBar: unreadable session file, skipped: \(url.lastPathComponent)")
                }
                continue
            }
            loggedUnreadable.remove(url.path)
            // Prune: the owning agent process is gone, or the file is ancient (24h).
            let dead = s.pid > 0 && kill(s.pid, 0) != 0 && errno == ESRCH
            let stale = s.ts > 0 && Date().timeIntervalSince1970 - s.ts > 86_400
            if dead || stale {
                try? fm.removeItem(at: url)
                continue
            }
            guard s.started else { continue } // opened but never used: stays out of the menu
            var live = s
            // Antigravity emits no terminal event (2.3.1 fires only PostToolUse), so a
            // working session that has gone quiet decays to done instead of animating
            // the bar forever.
            if live.agentID == "antigravity", live.state.isWorking,
               Date().timeIntervalSince1970 - live.ts > 90 {
                live.state = .done
                live.decayed = true // a watchdog guess, not a reported finish
            }
            sessions.append(live)
        }
        sessions.sort { ($0.priority, $0.ts) > ($1.priority, $1.ts) }
        loggedUnreadable.formIntersection(present)   // a file that came back may log again

        // Only notify when something visible changed, so the menu bar isn't rebuilt every
        // poll. Branch is part of the row, so a checkout must count as a visible change;
        // recap too — a second Stop can rewrite it while the state stays "done". Prompt
        // and model as well: the island titles rows by prompt and shows a model chip,
        // and both can change while state and label stay put (a queued prompt lands
        // while the session is already "Thinking…").
        let snapshot = sessions.map {
            "\($0.id):\($0.state.rawValue):\($0.label):\($0.project):\($0.gitBranch ?? ""):\($0.recap):\($0.prompt):\($0.model)"
        }
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onChange?(sessions)
    }
}
