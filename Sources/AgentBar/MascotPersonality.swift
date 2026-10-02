import Foundation

/// The decisions behind the island mascot's small signs of life — where its eyes
/// point, when it blinks, when a finish earns a sparkle, and what a poke turns
/// into. Pure on purpose: every clock and every pointer position is passed in, so
/// all of it can be read (and tested) without a panel, a timer or a screen.
/// `IslandMascot` is what puts the answers on the island, and only there — the
/// menu bar mark is a status glyph among other status glyphs, and a crab in it
/// looking around would be the one thing in the bar that moves for no reason.
enum MascotPersonality {
    /// Off by default (`bool(forKey:)` gives false), like the island's other
    /// switches. It stays inside the pill and the open panel and the largest motion
    /// is a pupil moving by one point, but it is still motion nobody asked for: the
    /// blink plays whenever the pill shows Clawd at rest, pointer near or not, in a
    /// chin the rest of the design works hard to keep still — and with it on, a
    /// click on a row's mark pokes it instead of jumping to the session. Both are
    /// changes to what someone already relies on, so they wait to be switched on in
    /// Settings ▸ General, and Reduce Motion turns all of it off whatever the switch
    /// says.
    enum Prefs {
        static let key = "islandMascotPersonality"
        static var enabled: Bool {
            get { UserDefaults.standard.bool(forKey: key) }
            set { UserDefaults.standard.set(newValue, forKey: key) }
        }
    }

    /// Whether any of it plays. Reduce Motion is not a preference to weigh against
    /// the switch — it is the user saying motion costs them something — so it
    /// wins outright, and with it the blink goes too: a mascot that only blinks
    /// would be a half-measure nobody asked for.
    static func plays(enabled: Bool, reduceMotion: Bool) -> Bool {
        enabled && !reduceMotion
    }

    /// Where the pupils sit, in whole steps of one point each way. Pixel art has
    /// no half-glance: an eye is either where it was drawn or one step over.
    struct Pupil: Hashable {
        var dx: Int
        var dy: Int
        static let ahead = Pupil(dx: 0, dy: 0)
    }

    // MARK: - Gaze

    /// The eyes follow the pointer — while it is near, while it moves, and with
    /// enough hysteresis that a pointer sitting on a boundary does not make them
    /// twitch at the poll's eight hertz.
    ///
    /// Each axis is decided on its own from the direction to the pointer (the unit
    /// vector, so distance never tips an axis on its own): a component has to pass
    /// `engage` to move the eye that way and drop under `release` to bring it
    /// back. The gap between the two is the smoothing; there is no easing to run,
    /// because there is nothing between "here" and "one point over" to ease
    /// through.
    struct Gaze {
        /// Beyond this many points the pointer is somewhere else entirely and the
        /// eyes look ahead. The pill sits under the notch, so anything inside this
        /// is the top band of the screen — where the user is reaching for it.
        static let reach: Double = 320
        /// Already following: let it wander a little further before giving up, or
        /// a pointer parked at the edge of reach flips the eyes on every tick.
        static let releaseReach: Double = 380
        /// On top of the mark itself there is no direction worth turning to; the
        /// eyes hold whatever they were doing.
        static let onTop: Double = 6
        static let engage = 0.45
        static let release = 0.28
        /// A pointer that stops is no longer interesting. After this long without
        /// moving the eyes drift back ahead — a glance, not a stare.
        static let boredAfter: TimeInterval = 4

        private(set) var pupil = Pupil.ahead
        private var lastPointer: (x: Double, y: Double)?
        private var lastMoved: TimeInterval = -.infinity

        /// One poll. `dx`/`dy` run from the mark to the pointer, y up; `pointer`
        /// is the pointer's own position, so "has it moved" does not depend on the
        /// mark staying put. Returns the pupil to draw.
        @discardableResult
        mutating func follow(dx: Double, dy: Double, pointer: (x: Double, y: Double),
                             now: TimeInterval) -> Pupil {
            if let last = lastPointer, last.x == pointer.x, last.y == pointer.y {
                // Still. Hold until bored.
            } else {
                lastMoved = now
            }
            lastPointer = pointer
            let distance = (dx * dx + dy * dy).squareRoot()
            let following = pupil != .ahead
            if now - lastMoved > Self.boredAfter
                || distance > (following ? Self.releaseReach : Self.reach) {
                pupil = .ahead
                return pupil
            }
            guard distance > Self.onTop else { return pupil }
            pupil = Pupil(dx: Self.step(dx / distance, current: pupil.dx),
                          dy: Self.step(dy / distance, current: pupil.dy))
            return pupil
        }

        /// The pill is not on screen, or not the mascot's: eyes ahead, and the next
        /// look starts fresh rather than from a pointer seen minutes ago.
        mutating func rest() {
            pupil = .ahead
            lastPointer = nil
        }

        static func step(_ component: Double, current: Int) -> Int {
            let sign = component < 0 ? -1 : 1
            let magnitude = abs(component)
            if current == sign { return magnitude >= release ? sign : 0 }
            return magnitude >= engage ? sign : 0
        }
    }

    // MARK: - Blink

    /// An occasional blink, read off the same poll — no timer of its own. Closed
    /// for `length`, which at the poll's 0.12 s is one or two ticks: long enough
    /// to see, short enough to read as a blink and not a wink.
    struct Blink {
        static let length: TimeInterval = 0.15
        /// Seconds between blinks. Irregular on purpose: anything metronomic in
        /// the corner of the eye gets noticed as a metronome.
        static let gaps: ClosedRange<TimeInterval> = 3.5...7

        private(set) var nextAt: TimeInterval
        private var openAt: TimeInterval = -.infinity

        init(firstAt: TimeInterval) { nextAt = firstAt }

        mutating func closed(at now: TimeInterval,
                             gap: () -> TimeInterval = { .random(in: Blink.gaps) }) -> Bool {
            if now < openAt { return true }
            guard now >= nextAt else { return false }
            openAt = now + Self.length
            nextAt = now + gap()
            return true
        }
    }

    // MARK: - Celebration

    /// Whether a finish earns the pill's sparkle. Not every finish does, and that
    /// is the whole design: Claude Code enters `done` after every turn, so a
    /// fifty-turn conversation is fifty finishes, and a sparkle on each would be
    /// the 1.17.0 banner mistake drawn smaller (see CLAUDE.md, rule 2). Three
    /// conditions, all of them:
    ///
    /// - the turn was real work — `minWork` from the first working tick to `done`.
    ///   A chat reply takes seconds; a task takes minutes. Waits on the user
    ///   (approval, a question) stay inside the turn, because the turn is what
    ///   finished.
    /// - this session has not had one for `perSession`, so a run of long tasks in
    ///   one conversation still gets a handful an hour, not one each;
    /// - nothing else sparkled in the last `anySession`, so two sessions ending
    ///   together make one sparkle, not a firework.
    ///
    /// The edge is the mascot's done-hop and SoundCenter's done cue, deliberately:
    /// working → done, reported rather than decayed by a watchdog, and never a file
    /// that first appears already done.
    struct Celebrations {
        struct Sample {
            var id: String
            var state: Session.State
            var decayed: Bool = false
        }

        static let minWork: TimeInterval = 90
        static let perSession: TimeInterval = 15 * 60
        static let anySession: TimeInterval = 20

        private var previous: [String: Session.State] = [:]
        private var workingSince: [String: TimeInterval] = [:]
        private var lastFor: [String: TimeInterval] = [:]
        private var lastAny: TimeInterval = -.infinity

        /// One store tick. True when the pill should sparkle now.
        mutating func observe(_ samples: [Sample], now: TimeInterval) -> Bool {
            var fire = false
            for s in samples {
                let prev = previous[s.id]
                if s.state.isWorking, workingSince[s.id] == nil { workingSince[s.id] = now }
                if s.state == .done, prev?.isWorking == true, !s.decayed,
                   let since = workingSince[s.id], now - since >= Self.minWork,
                   now - (lastFor[s.id] ?? -.infinity) >= Self.perSession,
                   now - lastAny >= Self.anySession {
                    lastFor[s.id] = now
                    lastAny = now
                    fire = true
                }
                if s.state.isFinished { workingSince[s.id] = nil }
                previous[s.id] = s.state
            }
            // Forget sessions that are gone. The per-session cooldown goes with
            // them: a new session under an old id is a new conversation.
            let live = Set(samples.map(\.id))
            previous = previous.filter { live.contains($0.key) }
            workingSince = workingSince.filter { live.contains($0.key) }
            lastFor = lastFor.filter { live.contains($0.key) }
            return fire
        }
    }

    // MARK: - Pokes

    /// What a click on a mark in the open panel turns into. Purely cosmetic — the
    /// mark swallows the click and nothing is focused, answered or opened. One
    /// poke squishes; `dizzyAfter` pokes inside `window` make it dizzy, and while
    /// it is dizzy further pokes do nothing, so hammering it is one dizzy beat and
    /// not a queue of them.
    struct Pokes {
        enum Reaction: Equatable {
            case squish, dizzy
            var length: TimeInterval { self == .squish ? 0.35 : 1.0 }
        }

        static let window: TimeInterval = 1.2
        static let dizzyAfter = 3

        private var recent: [TimeInterval] = []
        private var playing: (reaction: Reaction, since: TimeInterval)?

        /// A click landed. Nil while a dizzy beat is still running.
        mutating func poke(at now: TimeInterval) -> Reaction? {
            if let p = playing, p.reaction == .dizzy, now - p.since < p.reaction.length {
                return nil
            }
            recent = recent.filter { now - $0 < Self.window } + [now]
            let reaction: Reaction = recent.count >= Self.dizzyAfter ? .dizzy : .squish
            if reaction == .dizzy { recent = [] }
            playing = (reaction, now)
            return reaction
        }

        /// What is still playing, and how far into it — so a row rebuilt by the
        /// next store tick picks the reaction up where the old row left it.
        func current(at now: TimeInterval) -> (reaction: Reaction, elapsed: TimeInterval)? {
            guard let p = playing, now - p.since < p.reaction.length else { return nil }
            return (p.reaction, now - p.since)
        }
    }

    // MARK: - Greeting

    /// Clawd waves once when AgentBar starts — the one moment the pill appearing is
    /// news, because the user just launched it. Once per launch and only at that
    /// moment: if the pill is not there to wave from (hidden while nothing runs,
    /// hidden while away, the panel open, a flash on it, a session already
    /// working), the hello is skipped for the whole launch rather than saved up.
    /// A wave on some later peek would be a greeting nobody arrived for.
    struct Greeting {
        /// The first chance decides, whichever way it goes.
        private(set) var asked = false

        static func shouldGreet(pillVisible: Bool, collapsed: Bool, flashing: Bool,
                                working: Bool, alreadyGreeted: Bool) -> Bool {
            !alreadyGreeted && pillVisible && collapsed && !flashing && !working
        }

        /// The launch's one chance. True at most once, ever, for this value. `plays`
        /// is `MascotPersonality.plays` — with the switch off or Reduce Motion on,
        /// the chance is spent all the same: switching it on later is not a launch.
        mutating func consider(plays: Bool, pillVisible: Bool, collapsed: Bool,
                               flashing: Bool, working: Bool) -> Bool {
            defer { asked = true }
            return plays && Self.shouldGreet(pillVisible: pillVisible, collapsed: collapsed,
                                             flashing: flashing, working: working,
                                             alreadyGreeted: asked)
        }

        /// Frame length: six frames of `MascotEyes.waveFrames`, about a second.
        static let frameLength: TimeInterval = 0.17
    }
}
