import Foundation

/// What happened while the person was away, said once when they come back: the
/// pill reads "away · 3 done · 1 waiting" for a minute and a half, and the open
/// island leads with the whole sentence until it closes. Never opens anything:
/// the pill is already there, and only its words change.
///
/// Away is the threshold the banners use (`Notifier.quietSettle`): two minutes
/// with no input. The span starts where the input stopped, not where the
/// threshold was crossed, so "while you were away" means all of it.
struct AwayRecap: Equatable {
    var since: TimeInterval = 0
    var done = 0
    var failed = 0
    var waiting = 0
    /// How long the longest of those has waited, in seconds.
    var longestWait: TimeInterval = 0
    var byRules = 0
    /// One clause naming what failed while away ("tests failed in agentbar"),
    /// nil when nothing measured did. See `AwayFailure`.
    var failure: String?

    var isEmpty: Bool { done == 0 && failed == 0 && waiting == 0 && byRules == 0 && failure == nil }

    static func make(since: TimeInterval, until: TimeInterval,
                     history: [HistoryStore.Record], ledger: [DecisionLedger.Record],
                     requests: [ApprovalRequest], failures: [AwayFailure] = []) -> AwayRecap {
        let (summary, _) = HistoryDigest.digest(history, since: since, until: until)
        let waitingSince = requests.map(\.ts).filter { $0 > 0 }
        return AwayRecap(since: since,
                         done: summary.sessions - summary.failed,
                         failed: summary.failed,
                         waiting: requests.count,
                         longestWait: waitingSince.min().map { max(0, until - $0) } ?? 0,
                         byRules: DecisionLedger.byRules(in: ledger, since: since, until: until),
                         failure: AwayFailure.clause(failures, since: since, until: until))
    }

    /// For the pill, which is narrower than the notch: "away · 3 done · 1 waiting".
    var pill: String {
        var parts = ["away"]
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if done > 0 { parts.append("\(done) done") }
        if failed > 0 { parts.append("\(failed) failed") }
        if parts.count == 1, byRules > 0 { parts.append("rules: \(byRules)") }
        if let failure { parts.append(failure) }
        return parts.joined(separator: " · ")
    }

    /// For the open island: the whole of it, in a sentence.
    func sentence(until: TimeInterval) -> String {
        var parts: [String] = []
        if done > 0 { parts.append("\(done) finished") }
        if failed > 0 { parts.append("\(failed) failed") }
        if waiting > 0 {
            let w = Int(longestWait / 60)
            parts.append("\(waiting) waiting on you" + (w >= 1 ? ", the longest \(w) min" : ""))
        }
        if byRules > 0 { parts.append("your rules answered \(byRules)") }
        if let failure { parts.append(failure) }
        let minutes = max(1, Int((until - since) / 60))
        return "While you were away (\(minutes) min): " + parts.joined(separator: ", ") + "."
    }
}

/// A failure a session showed while the person was away, from what the session
/// itself carries: its state went to `error`, or the newest finished shell command
/// in its transcript's current turn came back `is_error` (`LiveFeed`). "While
/// away" is the session's own `ts` — its last state write — falling inside the
/// span; the command's own time is not read, so a failed command only counts on a
/// session that has stopped working and last wrote while away.
struct AwayFailure: Equatable {
    var project: String
    /// The failed command's first line; nil for a session that went to `error`.
    var command: String?
    var at: TimeInterval

    /// What the sessions say, read once on coming back. A working session's
    /// failed command is not counted: the agent is likely still dealing with it.
    static func from(_ sessions: [Session], since: TimeInterval, until: TimeInterval,
                     feed: (Session) -> LiveFeed.Feed = LiveFeed.read) -> [AwayFailure] {
        sessions.compactMap { s in
            guard s.ts >= since, s.ts <= until else { return nil }
            var command: String?
            if s.agentID == "claude", !s.state.isWorking {
                let f = feed(s)
                if let out = f.output, out.isError, f.items.indices.contains(out.after),
                   case .tool("Bash", let arg) = f.items[out.after] {
                    command = arg
                }
            }
            guard command != nil || s.state == .error else { return nil }
            return AwayFailure(project: s.project, command: command, at: s.ts)
        }
    }

    /// One clause for the newest failure in the span, "+N more" for the rest;
    /// nil when none. Only a command with `test`, `tests` or `pytest` as a word
    /// is called a test run.
    static func clause(_ all: [AwayFailure], since: TimeInterval, until: TimeInterval) -> String? {
        let inSpan = all.filter { $0.at >= since && $0.at <= until }
        guard let f = inSpan.max(by: { $0.at < $1.at }) else { return nil }
        let what: String
        if let c = f.command {
            what = isTestRun(c) ? "tests failed" : "a command failed"
        } else {
            what = "an error"
        }
        let project = f.project.trimmingCharacters(in: .whitespaces)
        var out = project.isEmpty ? what : "\(what) in \(project)"
        if inSpan.count > 1 { out += " +\(inSpan.count - 1) more" }
        return out
    }

    static func isTestRun(_ command: String) -> Bool {
        command.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .contains { $0 == "test" || $0 == "tests" || $0 == "pytest" }
    }
}

/// Watches for the person leaving and coming back, and holds the recap between.
final class AwayWatch {
    static let awayAfter: TimeInterval = Notifier.quietSettle
    static let showFor: TimeInterval = 90

    private(set) var leftAt: TimeInterval?
    private(set) var current: AwayRecap?
    private var shownAt: TimeInterval = 0

    /// One look at the idle clock. Returns true when what the pill says changed.
    func tick(idle: TimeInterval, now: TimeInterval, make: (TimeInterval) -> AwayRecap) -> Bool {
        var changed = false
        if current != nil, now - shownAt > Self.showFor {
            current = nil; changed = true
        }
        if idle >= Self.awayAfter {
            if leftAt == nil { leftAt = now - idle }
            if current != nil { current = nil; changed = true }
        } else if let left = leftAt, idle < 5 {
            leftAt = nil
            let recap = make(left)
            if !recap.isEmpty {
                current = recap
                shownAt = now
                changed = true
            }
        }
        return changed
    }

    /// The person looked: the pill can stop repeating it.
    func seen() { current = nil }

    static var enabled: Bool { UserDefaults.standard.object(forKey: "awayRecap") as? Bool ?? true }
}
