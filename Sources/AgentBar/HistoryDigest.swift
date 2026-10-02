import Foundation

/// What your agents did today, read back out of `history.jsonl`.
///
/// The menu bar answers "what is happening"; this answers "what happened", which
/// is the question you have at the end of a day and which nothing in AgentBar
/// could answer before — `state.d` deletes a session the moment its process dies.
///
/// Pure functions over already-loaded records: no file watching, no store, no
/// state. The menu reads it when it opens and the CLI when it is asked, which is
/// as often as a digest needs recomputing.
enum HistoryDigest {
    struct Entry: Equatable {
        let agent: String
        let project: String
        let cwd: String
        let state: String
        let startedAt: TimeInterval
        let endedAt: TimeInterval
        /// Nil when the writer never carried `started_at` — older rows, and agents
        /// that report no session start at all. A duration guessed from one
        /// timestamp would be a fabrication.
        var duration: TimeInterval? {
            guard startedAt > 0, endedAt >= startedAt else { return nil }
            return endedAt - startedAt
        }
        /// What the session cost, when its agent keeps a readable number. Nil for the
        /// seven agents that keep none — and for the three that do, whenever the file
        /// was not there. Never zero standing in for "unknown".
        var weight: Weight?
        /// What moved in the repo while it ran. Nil unless the whole span was
        /// observed — see `WorkDiff`, and note the wording it insists on.
        var change: RepoChange?
        /// The record's `agentName` — see `HistoryStore.Record`.
        var agentName = ""
        var resolvedAgent: Agent { Agent.byID(agent, name: agentName) }
        var failed: Bool { state == "error" }
    }

    struct Summary: Equatable {
        var sessions = 0
        var failed = 0
        /// Summed over the entries that *have* a duration, and `measured` says how
        /// many those were — "3h 40m" over 12 sessions when only 4 were timed would
        /// read as a total it is not.
        var seconds: TimeInterval = 0
        var measured = 0
        /// Same pair again, for weight. Most days will have `tokensMeasured` lower
        /// than `sessions`, because most agents publish nothing to measure.
        var tokens = 0
        var tokensMeasured = 0

        var isEmpty: Bool { sessions == 0 }
    }

    /// Everything that ended since local midnight, newest first.
    ///
    /// Local midnight, not "the last 24 hours": a digest called Today that starts
    /// counting from whenever you happen to look at it is not a day.
    static func today(_ records: [HistoryStore.Record],
                      now: TimeInterval = Date().timeIntervalSince1970,
                      calendar: Calendar = .current) -> (Summary, [Entry]) {
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        return digest(records, since: midnight, until: now)
    }

    static func digest(_ records: [HistoryStore.Record],
                       since: TimeInterval, until: TimeInterval) -> (Summary, [Entry]) {
        let entries = records
            .filter { $0.endedAt >= since && $0.endedAt <= until }
            .sorted { $0.endedAt > $1.endedAt }
            .map { Entry(agent: $0.agent, project: $0.project, cwd: $0.cwd, state: $0.state,
                         startedAt: $0.startedAt, endedAt: $0.endedAt,
                         weight: $0.weight, change: $0.change, agentName: $0.agentName) }

        var summary = Summary()
        summary.sessions = entries.count
        summary.failed = entries.filter(\.failed).count
        for d in entries.compactMap(\.duration) {
            summary.seconds += d
            summary.measured += 1
        }
        for w in entries.compactMap(\.weight) {
            summary.tokens += w.total
            summary.tokensMeasured += 1
        }
        return (summary, entries)
    }

    /// "12 sessions · 3h 40m · 1 failed" — the one line the menu row carries.
    /// Each clause is dropped when it would say nothing rather than shown as zero.
    static func headline(_ s: Summary) -> String {
        guard !s.isEmpty else { return "Nothing finished yet today" }
        var parts = ["\(s.sessions) session\(s.sessions == 1 ? "" : "s")"]
        // Only when every session was timed. A partial total presented as the day's
        // work is a number someone would quote.
        if s.measured == s.sessions, s.seconds > 0 { parts.append(duration(s.seconds)) }
        else if s.measured > 0 { parts.append("\(duration(s.seconds)) across \(s.measured)") }
        // The same rule a third time. Only three of the ten agents publish a number
        // at all, so a partial total is the normal case here rather than the
        // exception — and quoting it as the day's spend would be wrong most days.
        if s.tokensMeasured == s.sessions, s.tokens > 0 {
            parts.append("\(UsageCenter.compact(s.tokens)) tokens")
        } else if s.tokensMeasured > 0 {
            parts.append("\(UsageCenter.compact(s.tokens)) tokens across \(s.tokensMeasured)")
        }
        if s.failed > 0 { parts.append("\(s.failed) failed") }
        return parts.joined(separator: " · ")
    }

    /// "3h 40m" / "12m" / "<1m" — the same vocabulary `Session.elapsed` uses, so the
    /// live rows and the digest do not describe time two different ways.
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(s / 60)m" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// One row: "AgentBar · 34m · 1.2M · 7 files +210 −80".
    ///
    /// Every clause after the name is dropped when it is not known, so a row never
    /// pads itself out with zeroes to look complete.
    static func line(_ e: Entry) -> String {
        var parts = [e.project.isEmpty ? e.resolvedAgent.name : e.project]
        if let d = e.duration { parts.append(duration(d)) }
        if let w = e.weight, w.total > 0 { parts.append(UsageCenter.compact(w.total)) }
        if let c = e.change { parts.append(WorkDiff.describe(c)) }
        return parts.joined(separator: " · ")
    }
}
