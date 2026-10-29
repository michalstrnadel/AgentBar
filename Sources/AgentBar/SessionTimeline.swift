import Foundation

/// What each session has been doing lately — working, waiting on you, finished —
/// as AgentBar saw it, for the thin strip under the island's first row. Only what
/// was seen while the app ran: a session's first minutes before that are blank,
/// never guessed.
///
/// Pure bookkeeping, fed from the store's ticks: a new segment starts only when
/// the phase changes, so a session that works for an hour is one segment.
final class SessionTimeline {
    static let shared = SessionTimeline()

    enum Phase: Equatable {
        case working, waiting, failed, rest

        init(_ s: Session.State) {
            switch s {
            case .thinking, .tool:      self = .working
            case .permission, .question: self = .waiting
            case .error:                self = .failed
            case .idle, .done:          self = .rest
            }
        }
    }

    struct Segment: Equatable {
        var phase: Phase
        var start: TimeInterval
        var end: TimeInterval
    }

    /// How far back the strip reaches.
    static let window: TimeInterval = 60 * 60
    static let maxSegments = 200

    private(set) var segments: [String: [Segment]] = [:]

    func observe(_ sessions: [Session], now: TimeInterval = Date().timeIntervalSince1970) {
        var live = Set<String>()
        for s in sessions {
            live.insert(s.id)
            let phase = s.heldByMod ? .waiting : Phase(s.state)
            var list = segments[s.id] ?? []
            if var last = list.last, last.phase == phase {
                last.end = now
                list[list.count - 1] = last
            } else {
                if var last = list.last { last.end = now; list[list.count - 1] = last }
                list.append(Segment(phase: phase, start: now, end: now))
            }
            list.removeAll { $0.end < now - Self.window }
            segments[s.id] = Array(list.suffix(Self.maxSegments))
        }
        for id in segments.keys where !live.contains(id) { segments[id] = nil }
    }

    /// The segments inside the window ending `now`, clipped to it.
    /// The last segment is still going: the store only calls `observe` when a
    /// session changes, so a session that works steadily for an hour would
    /// otherwise end its strip at its last change.
    func strip(for session: String, now: TimeInterval = Date().timeIntervalSince1970) -> [Segment] {
        var list = segments[session] ?? []
        if var last = list.last, last.end < now {
            last.end = now
            list[list.count - 1] = last
        }
        return Self.clip(list, now: now)
    }

    static func clip(_ list: [Segment], now: TimeInterval) -> [Segment] {
        let from = now - window
        return list.compactMap { s in
            guard s.end >= from else { return nil }
            return Segment(phase: s.phase, start: max(s.start, from), end: min(s.end, now))
        }
    }

    /// Worth drawing: something other than one long rest, over at least a minute.
    static func worthShowing(_ list: [Segment]) -> Bool {
        guard let first = list.first, let last = list.last, last.end - first.start >= 60 else { return false }
        return list.contains { $0.phase != .rest }
    }

    /// "worked 34m · waited on you 6m" over the window, for the strip's tooltip.
    static func summary(_ list: [Segment]) -> String {
        func total(_ p: Phase) -> Int { Int(list.filter { $0.phase == p }.reduce(0) { $0 + $1.end - $1.start } / 60) }
        var parts = ["last hour: worked \(total(.working))m"]
        let w = total(.waiting)
        if w > 0 { parts.append("waited on you \(w)m") }
        if list.contains(where: { $0.phase == .failed }) { parts.append("failed once or more") }
        return parts.joined(separator: " · ")
    }
}
