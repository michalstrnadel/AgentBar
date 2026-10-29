import Foundation

/// Crossed paths: two sessions editing the same file within minutes of each other.
///
/// Two agents in one repository rarely collide on purpose. They collide because
/// nobody saw that Codex rewrote `auth.swift` four minutes after Claude did — and
/// the second change was made against a file the first one had already moved. This
/// says so, and only says so: in Your Day as a moment on the card, and live as an
/// amber chip on the row ("also edited by Codex · 3m"). Nothing opens and nothing
/// is stopped; the person decides whether it matters.
///
/// Pure: every function here takes the edits it is given — from transcripts, from
/// rollouts, from the `edits` ring a row carries (`docs/protocol.md`).
enum Flyby {
    /// One file edit, and whose it was.
    struct EditEvent: Equatable {
        let ts: TimeInterval
        let path: String
        let session: String
        let agent: String
    }

    /// Two sessions that edited one file, `gap` seconds apart.
    struct Crossing: Equatable {
        /// The file both edited, as the earlier edit spelled it.
        let path: String
        /// The earlier edit, and the later one.
        let first: EditEvent
        let second: EditEvent
        var gap: TimeInterval { second.ts - first.ts }
        /// The file's name, or "the same file" for a crossing whose path was taken
        /// out for sharing (`DayWrap.shareSafe`).
        var file: String { path.isEmpty ? "the same file" : (path as NSString).lastPathComponent }

        /// "Codex and Claude both edited auth.swift, 4 min apart" — the later one
        /// first, because it is the one that may have written over the other.
        func sentence(file name: String? = nil) -> String {
            "\(Flyby.who(second.agent, first.agent)) both edited \(name ?? file), \(Flyby.apart(gap))"
        }
    }

    /// How close two edits must be to count. Ten minutes is a turn or two: close
    /// enough that neither agent read the other's change before making its own.
    static let window: TimeInterval = 10 * 60

    /// The same file, however each writer spelled it: `.`/`..` resolved, a
    /// trailing slash dropped, and case folded — the Mac's disks are case-insensitive.
    static func normalised(_ path: String) -> String {
        (path as NSString).standardizingPath.lowercased()
    }

    /// Every pair of edits to one file by two different sessions within `window`,
    /// one per file and pair of sessions (the closest), oldest first.
    static func pairs(events: [EditEvent], window: TimeInterval = Flyby.window) -> [Crossing] {
        var byPath: [String: [EditEvent]] = [:]
        for e in events where !e.path.isEmpty && !e.session.isEmpty {
            byPath[normalised(e.path), default: []].append(e)
        }
        var best: [String: Crossing] = [:]
        for (path, list) in byPath {
            let sorted = list.sorted { ($0.ts, $0.session) < ($1.ts, $1.session) }
            for (i, a) in sorted.enumerated() {
                // Sorted by time: the first edit past the window ends the search.
                for b in sorted[(i + 1)...] {
                    guard b.ts - a.ts <= window else { break }
                    guard b.session != a.session else { continue }
                    let key = path + "\u{0}" + [a.session, b.session].sorted().joined(separator: "\u{0}")
                    let c = Crossing(path: a.path, first: a, second: b)
                    if let old = best[key], old.gap <= c.gap { continue }
                    best[key] = c
                }
            }
        }
        return best.values.sorted { ($0.second.ts, $0.path) < ($1.second.ts, $1.path) }
    }

    // MARK: - Live

    /// Another live session's edit to a file this one edited too.
    struct Live: Equatable {
        /// Who: "Codex", or "another Claude" when it is the same kind of agent.
        let agent: String
        let path: String
        /// When the *other* session edited it.
        let ts: TimeInterval

        /// "also edited by Codex · 3m".
        func chip(now: TimeInterval) -> String {
            "also edited by \(agent) · \(Flyby.ago(now - ts))"
        }

        func tooltip(now: TimeInterval) -> String {
            "\(agent.prefix(1).uppercased() + agent.dropFirst()) edited \((path as NSString).lastPathComponent) "
                + "\(Flyby.ago(now - ts)) ago, within \(Int(Flyby.window / 60)) minutes of this session — "
                + "worth a look before the two changes meet."
        }
    }

    /// How long a crossing stays on a row: the later edit is this recent.
    static let fresh: TimeInterval = 15 * 60

    /// For each live session, the freshest crossing with another live one — the
    /// other side of it. Sessions without one are absent.
    static func live(_ sessions: [Session], now: TimeInterval) -> [String: Live] {
        var events: [EditEvent] = []
        var agents: [String: Session] = [:]
        for s in sessions {
            agents[s.id] = s
            for e in s.edits where now - e.ts <= fresh + window {
                events.append(EditEvent(ts: e.ts, path: e.path, session: s.id, agent: s.agentID))
            }
        }
        var out: [String: Live] = [:]
        for c in pairs(events: events) where now - c.second.ts <= fresh {
            for (mine, other) in [(c.first, c.second), (c.second, c.first)] {
                guard let me = agents[mine.session], let them = agents[other.session] else { continue }
                let name = them.agentID == me.agentID && them.agentName == me.agentName
                    ? "another \(them.agent.name)" : them.agent.name
                let l = Live(agent: name, path: other.path, ts: other.ts)
                if let old = out[mine.session], old.ts >= l.ts { continue }
                out[mine.session] = l
            }
        }
        return out
    }

    /// The rows with their crossings on them.
    static func mark(_ sessions: [Session], now: TimeInterval) -> [Session] {
        let found = live(sessions, now: now)
        guard !found.isEmpty || sessions.contains(where: { $0.crossedBy != nil }) else { return sessions }
        return sessions.map { s in
            var out = s
            out.crossedBy = found[s.id]
            return out
        }
    }

    // MARK: - Words

    /// "Codex and Claude", or "Two Claude sessions" when both are the same agent.
    static func who(_ a: String, _ b: String) -> String {
        let na = Agent.byID(a).name, nb = Agent.byID(b).name
        return a == b ? "Two \(na) sessions" : "\(na) and \(nb)"
    }

    /// "4 min apart", "under a minute apart".
    static func apart(_ gap: TimeInterval) -> String {
        gap < 60 ? "under a minute apart" : "\(Int(gap / 60)) min apart"
    }

    /// "3m", "<1m".
    static func ago(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "<1m" : "\(Int(seconds / 60))m"
    }
}
