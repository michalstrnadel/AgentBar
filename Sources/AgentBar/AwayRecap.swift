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

    var isEmpty: Bool { done == 0 && failed == 0 && waiting == 0 && byRules == 0 }

    static func make(since: TimeInterval, until: TimeInterval,
                     history: [HistoryStore.Record], ledger: [DecisionLedger.Record],
                     requests: [ApprovalRequest]) -> AwayRecap {
        let (summary, _) = HistoryDigest.digest(history, since: since, until: until)
        let waitingSince = requests.map(\.ts).filter { $0 > 0 }
        return AwayRecap(since: since,
                         done: summary.sessions - summary.failed,
                         failed: summary.failed,
                         waiting: requests.count,
                         longestWait: waitingSince.min().map { max(0, until - $0) } ?? 0,
                         byRules: DecisionLedger.byRules(in: ledger, since: since, until: until))
    }

    /// For the pill, which is narrower than the notch: "away · 3 done · 1 waiting".
    var pill: String {
        var parts = ["away"]
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if done > 0 { parts.append("\(done) done") }
        if failed > 0 { parts.append("\(failed) failed") }
        if parts.count == 1, byRules > 0 { parts.append("rules: \(byRules)") }
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
        let minutes = max(1, Int((until - since) / 60))
        return "While you were away (\(minutes) min): " + parts.joined(separator: ", ") + "."
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
