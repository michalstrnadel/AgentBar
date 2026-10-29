import Foundation

/// How a session's tools have been going, as the Claude Code hook writes it
/// (`fails`, `tests`, `comeback`, `edits` in docs/protocol.md). Read off the row
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
    struct Edit: Equatable {
        let path: String
        let ts: TimeInterval
    }

    var fails: FailStreak?
    /// The newest test run's verdict: true red, false green, nil none seen.
    var testsRed: Bool?
    /// When a test run last went green after a red one, or a pull request was
    /// opened; 0 when neither has happened.
    var comeback: TimeInterval = 0
    /// The files changed lately, newest last, at most 20.
    var edits: [Edit] = []

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
        edits = (o["edits"] as? [[String: Any]] ?? []).suffix(20).compactMap { e in
            guard let path = e["path"] as? String, path.hasPrefix("/") else { return nil }
            return Edit(path: String(path.prefix(1024)), ts: Session.plausibleTime(e["ts"]))
        }
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
