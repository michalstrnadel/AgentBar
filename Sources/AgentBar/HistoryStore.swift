import Foundation

/// What each session did, kept after the session itself is gone.
///
/// `state.d/` cannot answer this. It is a *live* set: a row is deleted when its
/// process dies or its `ts` passes 24 h, so an agent that ran yesterday and exited
/// cleanly leaves nothing at all behind. That is fine for a status bar and useless
/// for two things that need a past — "when did this agent last report anything",
/// which is how a broken integration is told apart from an idle one, and any
/// account of a day's work.
///
/// So one append-only line per session in `~/.agentbar/history.jsonl`. Append-only
/// because a crash mid-write must cost at most the last line, and because the CLI
/// can append to the same file on Linux without a lock. A session is written more
/// than once — once per turn that ends, once more when it disappears — and the
/// reader keeps the **last** line for a given `sessionId`, so the newest wins and
/// duplicates are harmless rather than something to coordinate away.
///
/// Only a frontend writes here, never a hook: rule 3 says hooks exit fast, and a
/// session-ended line is exactly what several agents have no event for anyway.
final class HistoryStore {
    static let fileURL = AgentBarHome.url("history.jsonl")

    /// Dropped on launch. A month is long enough for "what did I do this sprint"
    /// and short enough that the file stays a file rather than an archive.
    static let maxAge: TimeInterval = 30 * 86_400
    /// A hard stop independent of age, in case a single day goes very wrong.
    static let maxRecords = 5_000

    private let url: URL
    /// The previous tick, by session id — the edge detector's left-hand side.
    private var previous: [String: Session] = [:]
    /// nil until the first tick: the launch snapshot is the baseline, not a set of
    /// sessions that just started. Same reasoning as `SessionStore.lastSnapshot`.
    private var primed = false

    init(url: URL = HistoryStore.fileURL) {
        self.url = url
    }

    /// One record. Field names match the state protocol's spelling where they overlap.
    struct Record: Equatable {
        var agent: String
        var sessionId: String
        var project: String
        var cwd: String
        var label: String
        var prompt: String
        var model: String
        var startedAt: TimeInterval
        var endedAt: TimeInterval
        var state: String
        /// True when a watchdog synthesized the end rather than the agent reporting
        /// it — a digest that counts those as clean finishes would be lying.
        var decayed: Bool
        /// What the session cost, when the agent keeps a number we can read. Nil is
        /// the common case and means "not measured", never zero — see `Weight`.
        var weight: Weight? = nil
        /// How much the repository moved while the session was open. Nil whenever the
        /// span cannot be measured honestly — see `WorkDiff`.
        var change: RepoChange? = nil
        /// `Session.agentName`: what a generic agent called itself, so a day-old
        /// record can still say "Aider" rather than its id. "" for known agents,
        /// and omitted from the line then, so older readers see no new field.
        var agentName = ""

        /// Who the record belongs to, resolved the way a live row is.
        var resolvedAgent: Agent { Agent.byID(agent, name: agentName) }

        var json: [String: Any] {
            var o: [String: Any] =
                ["v": 1, "agent": agent, "sessionId": sessionId, "project": project,
                 "cwd": cwd, "label": label, "prompt": prompt, "model": model,
                 "startedAt": Int(startedAt), "endedAt": Int(endedAt),
                 "state": state, "decayed": decayed]
            // Omitted rather than written empty: a reader must be able to tell
            // "nobody measured this" from "this cost nothing".
            if let weight { o["weight"] = weight.json }
            if let change { o["change"] = change.json }
            if !agentName.isEmpty { o["agentName"] = agentName }
            return o
        }

        init(_ s: Session, endedAt: TimeInterval) {
            agent = s.agentID
            agentName = s.agentName
            sessionId = s.id
            project = s.project
            cwd = s.cwd
            label = s.label
            prompt = s.prompt
            model = s.model
            startedAt = s.startedAt
            self.endedAt = endedAt
            state = s.state.rawValue
            decayed = s.decayed
        }
    }

    // MARK: - The edge detector, kept pure so it can be tested on its own

    /// Sessions that reached an end between two ticks.
    ///
    /// Two ways that happens and both count: a turn finishing (the row is still
    /// there, its state just became terminal) and the row disappearing (the process
    /// died, or the hook removed it). The first catches the data while the session
    /// is still readable; the second is the only signal several agents give at all.
    static func records(from previous: [String: Session], to current: [Session],
                        now: TimeInterval) -> [Record] {
        var out: [Record] = []
        let live = Set(current.map(\.id))

        for s in current where s.started {
            // `done` and `error` only — deliberately not `Session.State.isFinished`,
            // which also counts `idle`. Idle is "open and waiting", the state a
            // Claude session sits in between turns; treating it as an ending would
            // write a record every time someone paused to read the output.
            guard s.state == .done || s.state == .error else { continue }
            // Edge only: a row sitting in `done` for an hour must not be written on
            // every one of the 1800 ticks it survives. A session we have never seen
            // before that is already finished still counts — it ended, we just
            // missed the middle.
            let was = previous[s.id]?.state
            guard was != .done, was != .error else { continue }
            out.append(Record(s, endedAt: s.ts > 0 ? s.ts : now))
        }
        for (id, s) in previous where !live.contains(id) {
            guard s.started else { continue }
            out.append(Record(s, endedAt: s.ts > 0 ? s.ts : now))
        }
        // Stable order so a tick that ends several sessions writes them predictably.
        return out.sorted { ($0.endedAt, $0.sessionId) < ($1.endedAt, $1.sessionId) }
    }

    // MARK: - Wiring

    /// Where the weight and the diff are measured, off the main queue. Serial on
    /// purpose: it is what keeps records in the order they happened without any
    /// locking, and what lets the enrichment take as long as it needs.
    ///
    /// Enriching *before* the append, rather than appending a second superseding
    /// line, is the difference between one record per ending and two. The protocol
    /// would tolerate two — the last line for a session wins — but the file is also
    /// the thing a person reads.
    private let writer = DispatchQueue(label: "agentbar.history", qos: .utility)

    /// Injected in tests, which must not shell out to git or read a home directory.
    var enrich: (Record) -> Record = HistoryStore.measure

    func observe(_ sessions: [Session]) {
        defer { previous = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
        guard primed else { primed = true; return }
        let due = Self.records(from: previous, to: sessions, now: Date().timeIntervalSince1970)
        guard !due.isEmpty else { return }
        writer.async { [weak self] in
            guard let self else { return }
            self.append(due.map(self.enrich))
        }
    }

    /// Blocks until everything queued has been written. For tests and for a clean
    /// shutdown; no surface ever waits on history.
    func flush() { writer.sync {} }

    /// The default enrichment: ask each agent's own files what the session cost, and
    /// git what moved. Both answer nil far more often than not.
    ///
    /// A turn-end total can undercount, because Claude Code flushes its last assistant
    /// message asynchronously and may not have written it yet. That corrects itself:
    /// every record for a session carries the running total, and the reader keeps the
    /// last line — so the next turn, or the row's disappearance, supersedes it.
    static func measure(_ record: Record) -> Record {
        var out = record
        out.weight = WeightReader.read(agent: record.agent, sessionId: record.sessionId,
                                       cwd: record.cwd)
        out.change = WorkDiff.shared.change(sessionId: record.sessionId, cwd: record.cwd)
        return out
    }

    private func append(_ records: [Record]) {
        let lines = records.compactMap { r -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: r.json, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8)
            else { return nil }
            return line + "\n"
        }
        guard !lines.isEmpty, let data = lines.joined().data(using: .utf8) else { return }

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // O_APPEND, not read-modify-write: two frontends (the app and `agentbar
        // watch` on a shared home) must not be able to truncate each other, and a
        // line-sized append is atomic.
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    // MARK: - Reading and pruning

    /// Every line that still parses, oldest first, one entry per `sessionId` — the
    /// last line for an id wins, which is how a re-written session collapses.
    static func read(url: URL = HistoryStore.fileURL) -> [Record] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var byID: [String: Record] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let r = Record(jsonLine: String(line)) else { continue }  // a torn line is skipped, not fatal
            if byID[r.sessionId] == nil { order.append(r.sessionId) }
            byID[r.sessionId] = r
        }
        return order.compactMap { byID[$0] }
    }

    /// `read()` memoised on the file's own `(mtime, size)`.
    ///
    /// The menu can afford a full parse — it happens when someone opens it. The
    /// island footer cannot: it is rebuilt about once a second while an agent works,
    /// and a month of history is up to 5000 lines of JSON. A `stat(2)` per rebuild
    /// instead, and a re-read only when the file actually moved.
    static func cached(url: URL = HistoryStore.fileURL) -> [Record] {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)).map {
            (($0[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
             ($0[.size] as? Int) ?? 0)
        } ?? (0, 0)
        cacheLock.lock()
        if let c = cache, c.url == url.path, c.stamp == stamp { cacheLock.unlock(); return c.records }
        cacheLock.unlock()
        let records = read(url: url)
        cacheLock.lock()
        cache = (url.path, stamp, records)
        cacheLock.unlock()
        return records
    }

    private static let cacheLock = NSLock()
    /// Held by append and prune, for the reason `DecisionLedger.fileLock` gives.
    static let fileLock = NSLock()
    private static var cache: (url: String, stamp: (TimeInterval, Int), records: [Record])?

    /// Called on launch and every few hours after. Rewrites the file only when
    /// something actually goes — an old session, or the earlier lines of one that
    /// was written more than once — so the common case costs a read and nothing else.
    static func prune(url: URL = HistoryStore.fileURL, now: TimeInterval = Date().timeIntervalSince1970) {
        fileLock.lock()
        defer { fileLock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        // Counted as lines, not as sessions: `read` collapses a session written on
        // every turn into one record, and comparing collapsed counts meant a file of
        // nothing but repeats was never compacted.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).count
        let all = read(url: url)
        var kept = all.filter { now - $0.endedAt <= maxAge }
        if kept.count > maxRecords { kept = Array(kept.suffix(maxRecords)) }
        guard kept.count != lines else { return }

        let body = kept.compactMap { r -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: r.json, options: [.sortedKeys])
            else { return nil }
            return String(data: d, encoding: .utf8)
        }.joined(separator: "\n")
        try? (body.isEmpty ? "" : body + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

extension HistoryStore.Record {
    init?(jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agent = o["agent"] as? String,
              let sessionId = o["sessionId"] as? String
        else { return nil }
        self.agent = agent
        self.sessionId = sessionId
        project = o["project"] as? String ?? ""
        cwd = o["cwd"] as? String ?? ""
        label = o["label"] as? String ?? ""
        prompt = o["prompt"] as? String ?? ""
        model = o["model"] as? String ?? ""
        startedAt = (o["startedAt"] as? NSNumber)?.doubleValue ?? 0
        endedAt = (o["endedAt"] as? NSNumber)?.doubleValue ?? 0
        state = o["state"] as? String ?? ""
        decayed = o["decayed"] as? Bool ?? false
        weight = Weight(json: o["weight"])
        change = RepoChange(json: o["change"])
        // Cleaned again on the way back in: the file is the user's to edit.
        agentName = Session.displayName(o["agentName"])
    }
}
