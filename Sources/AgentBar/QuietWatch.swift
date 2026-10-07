import Foundation

/// A working session that has gone quiet: no word from its agent for a while.
///
/// A question, not a verdict — a long test run is quiet too, and it is fine. So
/// the flag says **"quiet 12m?"**, never "stuck", and it only offers the jump to
/// the session that a click on the row already makes. Every hook write moves a
/// session's `ts`, so silence is measured from the last one.
enum QuietWatch {
    private static let key = "quietWatchMinutes"
    static let choices = [0, 10, 20, 30]

    /// Minutes of silence before the flag, 0 for never. Ten unless changed.
    static var minutes: Int {
        get { UserDefaults.standard.object(forKey: key) as? Int ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// How long `s` has been quiet, in whole minutes, when that is long enough to
    /// say so; nil otherwise. Only a session that is working and on this Mac: one
    /// waiting on you is quiet because of you, a decayed row is already a guess,
    /// and a cloud run is not ours to time.
    static func quietMinutes(_ s: Session, now: TimeInterval = Date().timeIntervalSince1970,
                             threshold minutes: Int = QuietWatch.minutes) -> Int? {
        guard minutes > 0, s.state.isWorking, !s.decayed, s.entrypoint != "cloud", s.ts > 0 else { return nil }
        let quiet = now - s.ts
        guard quiet >= Double(minutes) * 60 else { return nil }
        return Int(quiet / 60)
    }

    static func label(_ minutes: Int) -> String {
        minutes < 60 ? "quiet \(minutes)m?" : "quiet \(minutes / 60)h \(minutes % 60)m?"
    }
}
