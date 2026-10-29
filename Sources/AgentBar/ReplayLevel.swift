import Foundation

/// A turn as a little side-scrolling level: Clawd walks from one tool call to the
/// next, stops at each to do what it did (a book to read, an anvil to hammer), hops
/// over the pit an error left, waits at a gate while the session waited on you,
/// and reaches a flag at the end.
///
/// Pure on purpose, like `ClawdScene`: what happened goes in, a level comes out,
/// and every number the picture is drawn from can be read and tested without
/// drawing. `ReplayRenderer` draws it; `ReplayTurn` reads what goes in.
///
/// Positions are in Clawd's own pixels (he is 12 wide, a prop makes him 22), so
/// the level is the same at every size. Times are seconds of the clip, which lasts
/// `minSeconds`…`maxSeconds` whatever the turn took: an hour's gap is a longer walk
/// and a sign saying so, not an hour of walking.
enum ReplayLevel {
    // MARK: - What goes in

    /// A tool result that came back as an error.
    struct Failure: Equatable {
        var at: TimeInterval
        /// The command that failed ran tests (`AwayRecap.isTestRun`).
        var tests: Bool = false
    }

    // MARK: - What comes out

    enum Kind: Equatable {
        /// One tool call, or several of the same kind in a row: a station with that
        /// tool's scene. `word` is what it says under the station.
        case station(ClawdScene, word: String, count: Int)
        /// An error: a gap in the ground Clawd hops over.
        case pit(tests: Bool)
        /// The session waited on you this long: a gate that opens.
        case gate(waited: TimeInterval)
        /// The end of the turn.
        case flag
    }

    struct Beat: Equatable {
        var kind: Kind
        /// When it happened, on the turn's own clock.
        var realAt: TimeInterval
        /// Clawd reaches the beat at `x0` at `arrive` and leaves it from `x1` at
        /// `leave` — the same place, except over a pit.
        var x0: Double
        var x1: Double
        var arrive: Double
        var leave: Double
        /// Real time since the beat before, shown on a sign when it was long.
        var gapBefore: TimeInterval
    }

    struct Bubble: Equatable {
        var text: String
        var from: Double
        var to: Double
    }

    struct Level: Equatable {
        var beats: [Beat]
        var bubbles: [Bubble]
        var duration: Double
        /// Tool calls left out at the start so the rest fits the clip.
        var earlier: Int
        /// What happened, for the words around the level.
        var steps: Int
        var errors: Int
        var waited: TimeInterval
        var realStart: TimeInterval
        var realEnd: TimeInterval
        var realSeconds: TimeInterval { max(0, realEnd - realStart) }
        /// Where the flag stands.
        var length: Double { (beats.last?.x1 ?? 0) + flagReach }
    }

    // MARK: - Tuning

    static let minSeconds: Double = 8
    static let maxSeconds: Double = 15
    /// A gap this long between two beats gets a sign: "12 min later".
    static let signAfter: TimeInterval = 120
    /// Said lines are cut to this many characters.
    static let saidLength = 40
    /// Where Clawd starts walking from, and how far past his stop the flag is.
    static let start: Double = 0
    static let flagReach: Double = 16

    /// Room a station takes: Clawd with a prop is 22 pixels, and a walk between
    /// two needs some ground to read as a walk.
    static let spacing: Double = 34
    static let pitWidth: Double = 8
    /// Walking pace, pixels a second, at full speed.
    static let pace: Double = 44
    static let act: Double = 1.0
    static let hop: Double = 0.7
    static let intro: Double = 0.6
    static let outro: Double = 1.8
    /// The shortest an action may get before steps are left out instead.
    static let minAct: Double = 0.45

    // MARK: - Making one

    /// The level for one turn. `entries` are its tool calls and said lines,
    /// `failures` the errors that came back, `segments` what AgentBar saw the
    /// session doing (its waits become gates). `includeSaid` is off whenever the
    /// clip may leave the Mac without project names: what the agent said is the
    /// most private thing in it.
    static func make(entries: [TimelinePeek.Entry], failures: [Failure] = [],
                     segments: [SessionTimeline.Segment] = [], includeSaid: Bool) -> Level {
        let sorted = entries.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
        let realStart = sorted.first?.at ?? segments.first?.start ?? 0
        let realEnd = max(sorted.last?.at ?? realStart, failures.map(\.at).max() ?? realStart)

        // Every beat in the order it happened, before any positions.
        var raw: [(at: TimeInterval, kind: Kind)] = []
        for e in sorted {
            guard case let .tool(name, _) = e.item else { continue }
            raw.append((e.at, .station(scene(forToolName: name), word: word(forToolName: name, named: includeSaid),
                                       count: 1)))
        }
        for f in failures where f.at >= realStart - 1 {
            raw.append((f.at, .pit(tests: f.tests)))
        }
        for s in segments where s.phase == .waiting && s.end > s.start
            && s.start >= realStart - 5 && s.start <= realEnd + 5 {
            raw.append((s.start, .gate(waited: s.end - s.start)))
        }
        // Stable by time; at a tie the tool call comes before what came of it.
        raw = raw.enumerated().sorted { a, b in
            a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset
        }.map(\.element)

        // The same tool again and again is one station with a count.
        var merged: [(at: TimeInterval, kind: Kind)] = []
        for r in raw {
            if case let .station(scene, word, n) = merged.last?.kind,
               case let .station(s2, w2, _) = r.kind, scene == s2, word == w2 {
                merged[merged.count - 1].kind = .station(scene, word: word, count: n + 1)
            } else {
                merged.append(r)
            }
        }
        let steps = raw.filter { if case .station = $0.kind { return true }; return false }.count

        // What fits: the newest beats, as many as the clip holds at the shortest
        // action. A turn of two hundred calls keeps its end and says how many came
        // before.
        var kept = merged
        var earlier = 0
        while kept.count > 1, timing(kept, gaps: gapsOf(kept)).fixed(minAct) > maxSeconds {
            let gone = kept.removeFirst()
            if case let .station(_, _, n) = gone.kind { earlier += n }
        }

        let gaps = gapsOf(kept)
        let t = timing(kept, gaps: gaps)
        // Scale everything that moves so the whole lands in the range.
        let natural = t.total(act: act, speed: 1)
        let target = min(maxSeconds, max(minSeconds, natural))
        // Solve for a speed factor k: walks and actions take 1/k as long.
        let fixedPart = intro + outro
        // Never slower than half pace: a short turn holds its flag longer instead.
        let k = max(0.5, (natural - fixedPart) / max(0.0001, target - fixedPart))

        var beats: [Beat] = []
        var x = start
        var clock = 0.0
        for (i, b) in kept.enumerated() {
            let distance = walkDistance(gap: gaps[i])
            let walk = (distance / pace) / k + (i == 0 ? intro : 0)
            let arriveX = x + distance
            let arrive = clock + walk
            let beat: Beat
            switch b.kind {
            case .pit:
                let hopTime = hop / k
                beat = Beat(kind: b.kind, realAt: b.at, x0: arriveX, x1: arriveX + pitWidth + 14,
                            arrive: arrive, leave: arrive + hopTime, gapBefore: gaps[i])
            case .gate(let waited):
                let hold = gateHold(waited) / k
                beat = Beat(kind: b.kind, realAt: b.at, x0: arriveX, x1: arriveX,
                            arrive: arrive, leave: arrive + hold, gapBefore: gaps[i])
            case .station, .flag:
                beat = Beat(kind: b.kind, realAt: b.at, x0: arriveX, x1: arriveX,
                            arrive: arrive, leave: arrive + act / k, gapBefore: gaps[i])
            }
            beats.append(beat)
            x = beat.x1
            clock = beat.leave
        }
        // The flag: a last short walk, then the hold.
        let lastGap = max(0, realEnd - (kept.last?.at ?? realEnd))
        let flagWalk = (spacing * 0.6 / pace) / k + (kept.isEmpty ? intro : 0)
        let flag = Beat(kind: .flag, realAt: realEnd, x0: x + spacing * 0.6, x1: x + spacing * 0.6,
                        arrive: clock + flagWalk, leave: clock + flagWalk + outro, gapBefore: lastGap)
        beats.append(flag)
        let duration = min(maxSeconds, max(minSeconds, flag.leave))

        var bubbles: [Bubble] = []
        if includeSaid {
            // Words from before the steps that were left out stay out with them.
            let from = earlier > 0 ? (kept.first?.at ?? realStart) : -.infinity
            bubbles = said(sorted.filter { $0.at >= from }, beats: beats, duration: duration)
        }
        let waits = segments.filter { $0.phase == .waiting && $0.start >= realStart - 5 && $0.start <= realEnd + 5 }
        let waited = waits.reduce(0) { $0 + max(0, $1.end - $1.start) }
        return Level(beats: beats, bubbles: bubbles, duration: duration, earlier: earlier, steps: steps,
                     errors: failures.filter { $0.at >= realStart - 1 }.count, waited: waited,
                     realStart: realStart, realEnd: max(realEnd, waits.map(\.end).max() ?? realEnd))
    }

    /// How long each beat's own part takes at a given action length, and the walks.
    private struct Timing {
        var walks: Double
        var stations: Int
        var hops: Int
        var gates: Double
        func total(act: Double, speed k: Double) -> Double {
            intro + outro + (walks + Double(stations) * act + Double(hops) * hop + gates) / k
        }
        /// The clip's length with every action cut to `act` and walks scaled alike.
        func fixed(_ shortest: Double) -> Double {
            let k = ReplayLevel.act / shortest
            return total(act: ReplayLevel.act, speed: k)
        }
    }

    private static func timing(_ beats: [(at: TimeInterval, kind: Kind)], gaps: [TimeInterval]) -> Timing {
        var t = Timing(walks: spacing * 0.6 / pace, stations: 0, hops: 0, gates: 0)
        for (i, b) in beats.enumerated() {
            t.walks += walkDistance(gap: gaps[i]) / pace
            switch b.kind {
            case .station, .flag: t.stations += 1
            case .pit: t.hops += 1
            case .gate(let w): t.gates += gateHold(w)
            }
        }
        return t
    }

    /// Real time between a beat and the end of the one before — a gate ends when
    /// the wait did, so the time spent waiting is the gate's, not the next walk's.
    private static func gapsOf(_ beats: [(at: TimeInterval, kind: Kind)]) -> [TimeInterval] {
        beats.indices.map { i in
            guard i > 0 else { return 0 }
            var end = beats[i - 1].at
            if case let .gate(waited) = beats[i - 1].kind { end += waited }
            return max(0, beats[i].at - end)
        }
    }

    /// The walk to a beat: always room for Clawd and his prop, a little more for
    /// a longer gap, and never more than twice the room however long it was.
    static func walkDistance(gap: TimeInterval) -> Double {
        spacing + min(spacing, 6 * log2(1 + max(0, gap) / 10))
    }

    /// A longer wait holds the gate a little longer, never long.
    static func gateHold(_ waited: TimeInterval) -> Double {
        0.9 + min(1.2, 0.25 * log2(1 + max(0, waited) / 10))
    }

    /// Said lines as bubbles over Clawd: each from the beat it was said at, held a
    /// moment, never two at once.
    private static func said(_ entries: [TimelinePeek.Entry], beats: [Beat], duration: Double) -> [Bubble] {
        var out: [Bubble] = []
        for e in entries {
            guard case let .said(text) = e.item else { continue }
            let line = clip(text)
            guard !line.isEmpty else { continue }
            // The first beat at or after the moment it was said.
            let at = beats.first { $0.realAt >= e.at }?.arrive ?? duration - 1.6
            let from = max(at - 0.2, out.last.map { $0.to + 0.15 } ?? 0)
            let to = min(from + 1.6, duration)
            guard to - from >= 0.8 else { continue }
            out.append(Bubble(text: line, from: from, to: to))
        }
        return out
    }

    /// A said line at most `saidLength` characters, cut at a word.
    static func clip(_ s: String) -> String {
        Handoff.clip(s, saidLength)
    }

    // MARK: - Clawd's position

    enum Pose: Equatable {
        case walk(step: Int)
        /// In the air over a pit, 0…1 of the hop.
        case hop(Double)
        case acting(ClawdScene, since: Double)
        /// At a closed gate, `open` 0…1 as it lifts.
        case waiting(open: Double)
        case done(since: Double)
    }

    /// Where Clawd is at `t` (in level pixels) and what he is doing.
    static func clawd(at t: Double, in level: Level) -> (x: Double, pose: Pose) {
        var x = start
        var left = 0.0
        for b in level.beats {
            if t < b.arrive {
                let f = (t - left) / max(0.001, b.arrive - left)
                let px = x + (b.x0 - x) * max(0, min(1, f))
                return (px, .walk(step: Int(px / 3) % 2))
            }
            if t < b.leave {
                let f = (t - b.arrive) / max(0.001, b.leave - b.arrive)
                switch b.kind {
                case .station(let scene, _, _):
                    return (b.x0, .acting(scene, since: t - b.arrive))
                case .pit:
                    return (b.x0 + (b.x1 - b.x0) * f, .hop(f))
                case .gate:
                    return (b.x0, .waiting(open: max(0, min(1, (f - 0.45) / 0.45))))
                case .flag:
                    return (b.x0, .done(since: t - b.arrive))
                }
            }
            x = b.x1
            left = b.leave
        }
        return (x, .done(since: t - (level.beats.last?.arrive ?? 0)))
    }

    // MARK: - Tools as scenes

    /// The scene for a tool's own name, as the transcript spells it (Claude Code's
    /// `Read`, Codex's `Shell`). Anything without a picture is a plain crate.
    static func scene(forToolName name: String) -> ClawdScene {
        switch name {
        case "Bash", "Shell", "BashOutput":               return .hammer
        case "Read", "NotebookRead":                      return .read
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return .type
        case "Grep", "Glob", "LS":                        return .search
        case "WebFetch", "WebSearch", "Web":              return .web
        case "Agent", "Task", "Message":                  return .delegate
        default:                                          return .walk
        }
    }

    /// The word under a station. A tool with no scene says its own name only
    /// when names may be shown: an MCP tool's name can say whose server it is.
    static func word(forToolName name: String, named: Bool) -> String {
        switch scene(forToolName: name) {
        case .hammer:   return "Run"
        case .read:     return "Read"
        case .type:     return name == "Write" ? "Write" : "Edit"
        case .search:   return "Search"
        case .web:      return "Web"
        case .delegate: return "Agent"
        default:        return named && !name.isEmpty ? String(name.prefix(14)) : "Tool"
        }
    }
}
