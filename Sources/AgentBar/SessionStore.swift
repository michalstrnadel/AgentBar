import Foundation

/// Watches `~/.agentbar/state.d/` and publishes the current set of live sessions.
/// The folder is the whole protocol: hooks write one JSON per session, remove it on end.
final class SessionStore {
    static let stateDir = AgentBarHome.url("state.d", isDirectory: true)

    /// Called on the main queue with sessions sorted by (priority, recency), most urgent first.
    var onChange: (([Session]) -> Void)?

    private let stateDir: URL
    /// What the AgentBar Claude Code mod reports beside the rows (`mods.d`): context,
    /// the account's live quota, and what Claude Code decided without asking. Read
    /// on the same passes as the rows, never on a schedule of its own — see
    /// `ModSidecars` for why that is enough.
    private let mods: ModSidecars
    private let liveQuota: ClaudeLiveQuota
    private let ingest: ClaudeDecisionIngest

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

    init(stateDir: URL = SessionStore.stateDir, mods: ModSidecars = ModSidecars(),
         liveQuota: ClaudeLiveQuota = .shared, ingest: ClaudeDecisionIngest = .shared) {
        self.stateDir = stateDir
        self.mods = mods
        self.liveQuota = liveQuota
        self.ingest = ingest
    }

    func start() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
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
        let fd = open(stateDir.path, O_EVTONLY)
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
        let files = (try? fm.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil)) ?? []
        var sessions: [Session] = []
        var present: Set<String> = []
        // Every row still on disk, shown or not: a sidecar is an orphan only once
        // its row is gone, and a row that is unreadable or not started is not gone.
        var rowIDs: Set<String> = []
        for url in files where url.pathExtension == "json" {
            present.insert(url.path)
            rowIDs.insert(url.deletingPathExtension().lastPathComponent)
            guard let s = Session(fileURL: url) else {
                // A torn write self-heals on the next hook write; a corrupt one would
                // otherwise make the session invisible with no trace at all.
                if loggedUnreadable.insert(url.path).inserted {
                    NSLog("AgentBar: unreadable session file, skipped: \(url.lastPathComponent)")
                }
                continue
            }
            loggedUnreadable.remove(url.path)
            if !Self.isLive(s) {
                try? fm.removeItem(at: url)
                rowIDs.remove(s.id)
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
        sessions = mergeMods(into: sessions, rowIDs: rowIDs)

        // Only notify when something visible changed, so the menu bar isn't rebuilt every
        // poll. Branch is part of the row, so a checkout must count as a visible change;
        // recap too — a second Stop can rewrite it while the state stays "done". Prompt
        // and model as well: the island titles rows by prompt and shows a model chip,
        // and both can change while state and label stay put (a queued prompt lands
        // while the session is already "Thinking…"). The agent's own name too: a
        // generic agent's row and mark are drawn from it. And what the mod reports: a
        // context percentage climbs while everything else on the row holds still.
        let snapshot = sessions.map {
            "\($0.id):\($0.agentName):\($0.state.rawValue):\($0.label):\($0.project):\($0.gitBranch ?? ""):\($0.recap):\($0.prompt):\($0.model)"
                + ":\($0.contextPercent ?? -1):\($0.subagents)"
        }
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onChange?(sessions)
    }

    /// One pass over `mods.d`: the figures onto the rows they belong to, the
    /// windows to the live quota, new decisions to the ledger, and orphans out of
    /// the folder. Rows the mod never wrote for come back untouched.
    private func mergeMods(into sessions: [Session], rowIDs: Set<String>) -> [Session] {
        let pass = mods.refresh(sessionIDs: rowIDs)
        liveQuota.update(Array(pass.reports.values))
        if !pass.changed.isEmpty {
            var projects: [String: String] = [:]
            for s in sessions { projects[s.id] = s.project }
            ingest.ingest(pass.changed, projects: projects, onDisk: Set(pass.reports.keys))
        }
        return Self.merge(pass.reports, into: sessions)
    }

    static func merge(_ reports: [String: ModReport], into sessions: [Session]) -> [Session] {
        guard !reports.isEmpty else { return sessions }
        return sessions.map { s in
            guard let r = reports[s.id] else { return s }
            var out = s
            out.modSeen = true
            out.contextPercent = r.context?.percent
            out.subagents = r.subagents
            return out
        }
    }

    /// Prune rule: the owning agent process is gone, or the file is ancient (24h).
    static func isLive(_ s: Session) -> Bool {
        let dead = s.pid > 0 && kill(s.pid, 0) != 0 && errno == ESRCH
        let stale = s.ts > 0 && Date().timeIntervalSince1970 - s.ts > 86_400
        return !dead && !stale
    }

    /// Live sessions on disk that are waiting on the human, read without a running
    /// store and without pruning anything — for the updater at launch.
    static func waitingOnDisk() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap(Session.init(fileURL:))
            .filter { isLive($0) && $0.state.waitsOnHuman }.count
    }
}
