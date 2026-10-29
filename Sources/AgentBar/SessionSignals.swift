import Foundation

/// How a session's tools have been going, as the Claude Code hook writes it
/// (`fails`, `tests`, `comeback` in docs/protocol.md; `edits` is `Session.edits`). Read off the row
/// and nothing more: the mascot sweats on a streak and celebrates a comeback, and
/// both decisions are taken elsewhere (`ClawdScene`, `Comeback`).
struct SessionSignals: Equatable {
    /// Failed tool calls in a row, and when the newest failed; nil once a call
    /// has gone through.
    struct FailStreak: Equatable {
        let streak: Int
        let at: TimeInterval
    }

    /// A file the session changed, and when.
    var fails: FailStreak?
    /// The newest test run's verdict: true red, false green, nil none seen.
    var testsRed: Bool?
    /// When a test run last went green after a red one, or a pull request was
    /// opened; 0 when neither has happened.
    var comeback: TimeInterval = 0
    /// How many comebacks the session has had in all.
    var comebacks = 0

    init() {}

    init(_ o: [String: Any]) {
        if let f = o["fails"] as? [String: Any], let n = (f["streak"] as? NSNumber)?.intValue, n > 0 {
            fails = FailStreak(streak: min(n, 99), at: Session.plausibleTime(f["at"]))
        }
        switch (o["tests"] as? [String: Any])?["last"] as? String {
        case "red": testsRed = true
        case "green": testsRed = false
        default: break
        }
        comeback = Session.plausibleTime(o["comeback"])
        if let n = (o["comebacks"] as? NSNumber)?.intValue, n > 0 { comebacks = min(n, 999) }
    }

    /// How many failures in a row make him sweat, and for how long after the
    /// newest one: a streak the session walked away from an hour ago is not
    /// what it is struggling with now.
    static let sweatsAt = 3
    static let sweatFor: TimeInterval = 5 * 60

    func sweating(now: TimeInterval) -> Bool {
        guard let fails else { return false }
        return fails.streak >= Self.sweatsAt && now - fails.at < Self.sweatFor
    }
}
