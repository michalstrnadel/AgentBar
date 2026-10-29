import Foundation

/// How fast a session is going, so the mascot can go at the same pace: a session
/// firing off a tool every few seconds plays its loop quicker, one that changes
/// state twice a minute plays it slower, and one that has said nothing for
/// `stallsAfter` while it is meant to be working is stalled. Information, not
/// ornament — which is why it reaches the menu bar too (docs/clawd-scenes.md):
/// the mark moves only while a session works, and how fast it moves is now
/// something the session said rather than a constant.
///
/// Pure, like `MascotPersonality.Celebrations`: every store tick is handed in with
/// its clock, so the whole of it can be read and tested without a timer.
struct Tempo {
    /// The span edges are counted over.
    static let window: TimeInterval = 60
    /// Edges a minute at which a loop plays at its own speed.
    static let natural = 8.0
    /// Edges a minute at which it reaches `range.upperBound`.
    static let busy = 20.0
    static let range: ClosedRange<Double> = 0.6...1.6
    static let stallsAfter: TimeInterval = 90
    /// A session seen for less than this is measured over this much, so the first
    /// edge after launch does not read as sixty a minute.
    static let shortest: TimeInterval = 15

    struct Sample {
        var id: String
        var state: Session.State
        var label: String
    }

    private var last: [String: (state: Session.State, label: String)] = [:]
    private var edges: [String: [TimeInterval]] = [:]
    private var lastEdge: [String: TimeInterval] = [:]
    private var firstSeen: [String: TimeInterval] = [:]
    private var working: Set<String> = []

    /// One store tick. An edge is a change of state or label: a tool starting,
    /// a tool's result coming back, a new prompt.
    mutating func observe(_ samples: [Sample], now: TimeInterval) {
        for s in samples {
            if let prev = last[s.id] {
                if prev.state != s.state || prev.label != s.label {
                    edges[s.id, default: []].append(now)
                    lastEdge[s.id] = now
                }
            } else {
                firstSeen[s.id] = now
                lastEdge[s.id] = now
            }
            last[s.id] = (s.state, s.label)
            edges[s.id] = edges[s.id]?.filter { now - $0 < Self.window }
            if s.state.isWorking { working.insert(s.id) } else { working.remove(s.id) }
        }
        let live = Set(samples.map(\.id))
        last = last.filter { live.contains($0.key) }
        edges = edges.filter { live.contains($0.key) }
        lastEdge = lastEdge.filter { live.contains($0.key) }
        firstSeen = firstSeen.filter { live.contains($0.key) }
        working = working.intersection(live)
    }

    /// Edges a minute, over the window or over as long as the session has been seen.
    func rate(for id: String, now: TimeInterval) -> Double {
        let n = Double(edges[id]?.filter { now - $0 < Self.window }.count ?? 0)
        let seen = now - (firstSeen[id] ?? now)
        return n * 60 / min(Self.window, max(Self.shortest, seen))
    }

    /// What the loop's speed is multiplied by: `range.lowerBound` with nothing
    /// happening, 1 at `natural`, `range.upperBound` from `busy` up.
    func multiplier(for id: String, now: TimeInterval) -> Double {
        Self.multiplier(rate: rate(for: id, now: now))
    }

    static func multiplier(rate: Double) -> Double {
        let r = max(0, rate)
        if r <= natural { return range.lowerBound + (1 - range.lowerBound) * r / natural }
        return min(range.upperBound, 1 + (range.upperBound - 1) * (r - natural) / (busy - natural))
    }

    /// Working, and nothing has changed for `stallsAfter`.
    func stalled(_ id: String, now: TimeInterval) -> Bool {
        guard working.contains(id), let at = lastEdge[id] else { return false }
        return now - at >= Self.stallsAfter
    }
}
