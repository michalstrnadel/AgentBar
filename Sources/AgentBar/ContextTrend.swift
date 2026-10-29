import Foundation

/// Whether a Claude Code session is about to auto-compact, from how its context
/// grew over the turns AgentBar watched.
///
/// **The measure is turns, not minutes.** Context grows when the agent reads,
/// writes and answers, and a turn is the unit in which that happens: a session
/// that sits waiting on you for an hour adds nothing, so a clock would forecast
/// a compaction that never comes. A turn is counted where Claude Code says one
/// ends (the row going from working to done/idle/failed); its figure is the last
/// percent the mod reported before the next turn began, so a measurement that
/// lands a second after `done` still belongs to the turn it measured.
///
/// **The rule.** Growth per turn is the mean of the last `window` turn-to-turn
/// changes; at least `minIncreases` of them must be real increases, or there is
/// no forecast — say nothing rather than guess. The forecast speaks only at
/// `ContextGauge.showFrom` (70%) and up, and only when that pace reaches
/// `compactsAt` within `horizon` turns.
///
/// **Any drop resets the history.** Context only shrinks when Claude Code
/// compacted or the person ran `/clear`; what came before says nothing about the
/// conversation that follows.
///
/// **Where it compacts is an assumption.** The mod reports `context.percent` and
/// nothing about the auto-compact point, and Claude Code does not publish it as a
/// number (it keeps a reserve that has changed between versions). `compactsAt` is
/// 90%: a margin under 100% on the early side, so the warning comes a turn too
/// soon rather than a turn too late. If the mod ever reports the threshold, it
/// should replace this constant.
///
/// Fed from the store's ticks (`main.swift`), like `SessionTimeline`; only what
/// was seen while the app ran counts.
final class ContextTrend {
    static let shared = ContextTrend()

    /// Assumed auto-compact point, in percent of the window (see above).
    static let compactsAt = 90
    /// How many turns ahead a forecast may reach.
    static let horizon = 3
    /// How many turn-to-turn changes the pace is averaged over.
    static let window = 4
    /// Fewer real increases than this and there is no forecast.
    static let minIncreases = 2

    struct Forecast: Equatable {
        /// Turns left at the current pace; 0 when already at or past `compactsAt`.
        let turns: Int

        /// "compacts in about 2 turns", or "compacts soon" once at the point.
        var text: String {
            switch turns {
            case ...0: return "compacts soon"
            case 1:    return "compacts in about 1 turn"
            default:   return "compacts in about \(turns) turns"
            }
        }
    }

    struct Track: Equatable {
        /// The figure each watched turn ended on, oldest first. The first entry
        /// is the baseline: where the session stood when first seen or reset.
        var ends: [Int]
        var resting: Bool
        var last: Int
    }

    private(set) var tracks: [String: Track] = [:]

    func observe(_ sessions: [Session]) {
        var live = Set<String>()
        for s in sessions {
            live.insert(s.id)
            guard let p = s.contextPercent else { continue }
            tracks[s.id] = Self.step(tracks[s.id], percent: p, resting: Self.resting(s))
        }
        for id in tracks.keys where !live.contains(id) { tracks[id] = nil }
    }

    func forecast(for s: Session) -> Forecast? {
        guard let p = s.contextPercent, let t = tracks[s.id] else { return nil }
        return Self.forecast(ends: t.ends, current: p)
    }

    // MARK: - Pure

    static func resting(_ s: Session) -> Bool {
        if s.heldByMod { return false }
        switch s.state {
        case .idle, .done, .error:                     return true
        case .thinking, .tool, .permission, .question: return false
        }
    }

    static let keep = 8

    /// One tick of one session.
    static func step(_ prior: Track?, percent p: Int, resting: Bool) -> Track {
        // First sight, or the context shrank: a fresh baseline.
        guard var t = prior, p >= t.last else {
            return Track(ends: [p], resting: resting, last: p)
        }
        t.last = p
        if resting {
            // Entering rest closes a turn; while resting, a late measurement still
            // belongs to the turn that just ended.
            if t.resting { t.ends[t.ends.count - 1] = p } else { t.ends.append(p) }
        }
        t.resting = resting
        t.ends = Array(t.ends.suffix(keep))
        return t
    }

    static func forecast(ends: [Int], current: Int) -> Forecast? {
        guard current >= ContextGauge.showFrom, ends.count >= 2 else { return nil }
        let deltas = Array(zip(ends, ends.dropFirst()).map { $1 - $0 }.suffix(window))
        guard deltas.filter({ $0 > 0 }).count >= minIncreases else { return nil }
        let perTurn = Double(deltas.reduce(0, +)) / Double(deltas.count)
        guard perTurn > 0 else { return nil }
        let left = compactsAt - current
        let turns = left <= 0 ? 0 : Int((Double(left) / perTurn).rounded(.up))
        return turns <= horizon ? Forecast(turns: turns) : nil
    }
}
