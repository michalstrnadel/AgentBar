import Foundation

/// Which sessions just made a comeback — a test run that went green after a red
/// one, or a pull request opened (`comeback` on the row, written by the Claude
/// Code hook). The one celebration in AgentBar that is earned rather than
/// scheduled: a finished turn is not news (CLAUDE.md, rule 2), but getting the
/// tests back to green is.
///
/// Pure, like `MascotPersonality.Celebrations`, and only the edge: the value
/// moving forward while AgentBar watches. A row seen for the first time already
/// carrying one is history, not news — the app launching is not a comeback — and
/// one that reaches the app late (`fresh`) is let pass. Whether it then plays is
/// the throttle's and the personality switch's to say (`IslandMascot`).
struct Comeback {
    static let fresh: TimeInterval = 120

    struct Sample {
        var id: String
        /// The row's `comeback`, 0 when it has none.
        var at: TimeInterval
    }

    private var seen: [String: TimeInterval] = [:]

    /// One store tick, `now` on the same clock as the rows (Unix time). The ids
    /// whose comeback is new, in the order given.
    mutating func observe(_ samples: [Sample], now: TimeInterval) -> [String] {
        var out: [String] = []
        for s in samples {
            if let before = seen[s.id], s.at > before, now - s.at < Self.fresh {
                out.append(s.id)
            }
            seen[s.id] = max(seen[s.id] ?? 0, s.at)
        }
        let live = Set(samples.map(\.id))
        seen = seen.filter { live.contains($0.key) }
        return out
    }
}
