import Foundation

/// **Bug Hunt**: the island's second game, played by the rules of the old light-gun
/// hunting game. The pictures, the name and the sounds are ours: the bugs from
/// Take a break are the quarry and Clawd plays the dog.
///
/// A round is ten bugs, one at a time (Game A) or in pairs (Game B). Each flight
/// gets three shots. A hit bug freezes, falls into the grass, and Clawd holds it
/// up. A bug that outlives the shots, or the clock, flies away and Clawd laughs.
/// Hit enough of the ten and the next round comes faster; hit all ten for a
/// bonus; fall short and the game is over.
///
/// Like `BreakGame` this is the whole game as a value. Time comes in as `dt`,
/// chance from a seeded generator, and shots as points in the field, so a test
/// can play it frame by frame. `HuntGameView` draws it.
///
/// Coordinates are points in the field, origin bottom-left, y up.
struct HuntGame {
    // MARK: - Shape of the field

    static let width: Double = 432
    static let height: Double = 470
    /// Top of the dirt strip that carries the scoreboard.
    static let groundTop: Double = 56
    /// Top of the tall grass: bugs rise from behind it and fall back into it.
    static let grassTop: Double = 112
    static let bugSize = (w: 42.0, h: 30.0)
    /// How far outside a bug's box a shot still counts.
    static let hitSlack: Double = 5

    static let shotsPerFlight = 3
    static let bugsPerRound = 10
    /// Seconds in the air before a bug gives up on you and leaves.
    static let flightTime: Double = 5.5
    static let freezeTime: Double = 0.5
    static let fallSpeed: Double = 170
    static let escapeSpeed: Double = 240
    static let introTime: Double = 2.6
    static let bannerTime: Double = 1.3
    static let retrieveTime: Double = 1.6
    static let laughTime: Double = 1.6
    static let roundEndTime: Double = 2.2
    static let perfectTime: Double = 2.4

    // MARK: - Things on the field

    typealias Kind = BreakGame.Kind

    enum Mode: Int, CaseIterable {
        case a = 1, b = 2
        var bugsPerFlight: Int { rawValue }
    }

    enum BugState: Equatable {
        /// In the air; `turnIn` seconds until it changes heading.
        case flying(turnIn: Double)
        /// Just hit: frozen where the shot found it.
        case hit(age: Double)
        case falling
        /// Leaving straight up: out of shots, or out of time.
        case escaping
        /// In the grass, or off the top: done with.
        case gone(caught: Bool)
    }

    struct Bug: Equatable {
        var kind: Kind
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var state: BugState
        /// Once above the grass it bounces off it; before that it is still rising.
        var risen = false
    }

    enum Result: Equatable { case pending, hit, miss }

    enum Phase: Equatable {
        /// The title: pick Game A or B.
        case title
        /// Clawd walks in, sniffs, and jumps into the grass.
        case intro(t: Double)
        case banner(t: Double)
        case flight
        /// Clawd holds up what was caught, at `x`.
        case retrieve(t: Double, x: Double, kinds: [Kind])
        case laugh(t: Double)
        /// The hit bar sorts itself, then the verdict.
        case roundEnd(t: Double, passed: Bool)
        case perfect(t: Double)
        case over
    }

    /// What happened in one step (or one shot), for sound and nothing else.
    struct Events: Equatable {
        var shot = false
        var hits = 0
        var fell = false
        var flyAway = false
        var laugh = false
        var retrieve = false
        var roundPassed = false
        var perfect = false
        var gameOver = false
    }

    // MARK: - State

    var phase: Phase = .title
    var mode: Mode = .a
    var round = 1
    var score = 0
    var bugs: [Bug] = []
    var shotsLeft = HuntGame.shotsPerFlight
    /// Seconds this flight has been in the air.
    var flightClock: Double = 0
    /// One slot per bug of the round, filled as each flight ends.
    var results: [Result] = Array(repeating: .pending, count: HuntGame.bugsPerRound)
    /// The first slot of the flight in the air.
    var slot = 0
    var clock: Double = 0
    private var rng: SplitMix64

    init(seed: UInt64) {
        rng = SplitMix64(seed: seed)
    }

    var hitsThisRound: Int { results.filter { $0 == .hit }.count }
    /// The sky turns while something flies away, and while Clawd laughs about it.
    var skyAlarmed: Bool {
        if case .laugh = phase { return true }
        return bugs.contains { $0.state == .escaping }
    }

    // MARK: - Rules as numbers

    /// Hits out of ten a round needs.
    static func needed(round: Int) -> Int {
        switch round {
        case ...10: return 6
        case 11...12: return 7
        case 13...14: return 8
        case 15...19: return 9
        default: return 10
        }
    }

    static func points(_ kind: Kind, round: Int) -> Int {
        let base: [Kind: [Int]] = [.drone: [500, 800, 1000], .wasp: [1000, 1600, 2000], .boss: [1500, 2400, 3000]]
        let band = round <= 5 ? 0 : round <= 10 ? 1 : 2
        return base[kind]![band]
    }

    static func perfectBonus(round: Int) -> Int {
        switch round {
        case ...10: return 10_000
        case 11...15: return 15_000
        case 16...20: return 20_000
        default: return 30_000
        }
    }

    /// Points a second for a bug of `kind` in `round` — faster every round, capped.
    static func speed(_ kind: Kind, round: Int, mode: Mode) -> Double {
        let k: Double = kind == .drone ? 1 : kind == .wasp ? 1.22 : 1.45
        let r = min(1 + 0.07 * Double(round - 1), 2.1)
        return 140 * k * r * (mode == .b ? 0.9 : 1)
    }

    // MARK: - Starting

    /// From the title (or after a game over): straight to Clawd's walk-in.
    mutating func start(_ mode: Mode) {
        self.mode = mode
        round = 1
        score = 0
        bugs = []
        results = Array(repeating: .pending, count: Self.bugsPerRound)
        slot = 0
        phase = .intro(t: 0)
    }

    /// Return after a game over: the same game again.
    mutating func restart() { start(mode) }

    /// A click during the walk-in skips it.
    mutating func skipIntro() {
        if case .intro = phase { phase = .banner(t: 0) }
    }

    private mutating func launchFlight() {
        bugs = (0..<mode.bugsPerFlight).map { i in
            let kind = pickKind()
            let x = 70 + rng.unit() * (Self.width - 140)
            let angle = (0.6 + rng.unit() * 0.55) // radians above horizontal
            let dir: Double = (i == 1 ? -1 : 1) * (rng.unit() < 0.5 ? -1 : 1)
            let s = Self.speed(kind, round: round, mode: mode)
            return Bug(kind: kind, x: x, y: Self.grassTop - 18, vx: cos(angle) * s * dir, vy: sin(angle) * s,
                       state: .flying(turnIn: turnDelay()))
        }
        shotsLeft = Self.shotsPerFlight
        flightClock = 0
        phase = .flight
    }

    private mutating func pickKind() -> Kind {
        let boss = min(0.1 + 0.03 * Double(round - 1), 0.4)
        let r = rng.unit()
        return r < boss ? .boss : r < boss + 0.3 ? .wasp : .drone
    }

    private mutating func turnDelay() -> Double { 0.6 + rng.unit() * 1.0 }

    // MARK: - Shooting

    /// A shot at (x, y). Spent only while bugs are in the air; it hits the nearest
    /// flying bug whose box (plus a little slack) holds the point.
    @discardableResult
    mutating func shoot(x: Double, y: Double) -> Events {
        var ev = Events()
        guard phase == .flight, shotsLeft > 0,
              bugs.contains(where: { if case .flying = $0.state { return true }; return false }) else { return ev }
        shotsLeft -= 1
        ev.shot = true
        let target = bugs.indices
            .filter { if case .flying = bugs[$0].state { return true }; return false }
            .filter {
                abs(bugs[$0].x - x) <= Self.bugSize.w / 2 + Self.hitSlack
                    && abs(bugs[$0].y - y) <= Self.bugSize.h / 2 + Self.hitSlack
            }
            .min { hypot(bugs[$0].x - x, bugs[$0].y - y) < hypot(bugs[$1].x - x, bugs[$1].y - y) }
        if let i = target {
            bugs[i].state = .hit(age: 0)
            score += Self.points(bugs[i].kind, round: round)
            ev.hits = 1
        }
        // Out of shots with something still flying: it leaves now.
        if shotsLeft == 0 { escapeAll(&ev) }
        return ev
    }

    private mutating func escapeAll(_ ev: inout Events) {
        var any = false
        for i in bugs.indices {
            if case .flying = bugs[i].state {
                bugs[i].state = .escaping
                any = true
            }
        }
        if any { ev.flyAway = true }
    }

    // MARK: - Time

    @discardableResult
    mutating func step(dt raw: Double) -> Events {
        var ev = Events()
        let dt = min(max(raw, 0), 0.05)
        guard dt > 0 else { return ev }
        clock += dt
        switch phase {
        case .title, .over:
            break
        case .intro(let t):
            phase = t + dt >= Self.introTime ? .banner(t: 0) : .intro(t: t + dt)
        case .banner(let t):
            if t + dt >= Self.bannerTime { launchFlight() } else { phase = .banner(t: t + dt) }
        case .flight:
            flightClock += dt
            if flightClock >= Self.flightTime { escapeAll(&ev) }
            moveBugs(dt, &ev)
            if bugs.allSatisfy({ if case .gone = $0.state { return true }; return false }) { endFlight(&ev) }
        case .retrieve(let t, let x, let kinds):
            if t + dt >= Self.retrieveTime { nextFlight(&ev) } else { phase = .retrieve(t: t + dt, x: x, kinds: kinds) }
        case .laugh(let t):
            if t + dt >= Self.laughTime { nextFlight(&ev) } else { phase = .laugh(t: t + dt) }
        case .roundEnd(let t, let passed):
            if t + dt < Self.roundEndTime {
                phase = .roundEnd(t: t + dt, passed: passed)
            } else if !passed {
                phase = .over
                ev.gameOver = true
            } else if hitsThisRound == Self.bugsPerRound {
                score += Self.perfectBonus(round: round)
                phase = .perfect(t: 0)
                ev.perfect = true
            } else {
                nextRound()
            }
        case .perfect(let t):
            if t + dt >= Self.perfectTime { nextRound() } else { phase = .perfect(t: t + dt) }
        }
        return ev
    }

    private mutating func moveBugs(_ dt: Double, _ ev: inout Events) {
        let halfW = Self.bugSize.w / 2, halfH = Self.bugSize.h / 2
        for i in bugs.indices {
            var b = bugs[i]
            switch b.state {
            case .flying(let turnIn):
                b.x += b.vx * dt
                b.y += b.vy * dt
                if b.y > Self.grassTop + halfH { b.risen = true }
                if b.x < halfW { b.x = halfW; b.vx = abs(b.vx) }
                if b.x > Self.width - halfW { b.x = Self.width - halfW; b.vx = -abs(b.vx) }
                if b.y > Self.height - halfH - 6 { b.y = Self.height - halfH - 6; b.vy = -abs(b.vy) }
                if b.risen, b.y < Self.grassTop + halfH { b.y = Self.grassTop + halfH; b.vy = abs(b.vy) }
                if turnIn - dt <= 0 {
                    // A new heading at the same speed: never flat, never straight up.
                    let s = hypot(b.vx, b.vy)
                    let angle = 0.35 + rng.unit() * 0.8
                    // Low in the sky it tends to climb, high up to dive: the whole sky gets used.
                    let climb = b.y < (Self.grassTop + Self.height) / 2 ? 0.7 : 0.35
                    let up: Double = b.risen ? (rng.unit() < climb ? 1 : -1) : 1
                    let side: Double = rng.unit() < 0.35 ? -(b.vx < 0 ? -1 : 1) : (b.vx < 0 ? -1 : 1)
                    b.vx = cos(angle) * s * side
                    b.vy = sin(angle) * s * up
                    b.state = .flying(turnIn: turnDelay())
                } else {
                    b.state = .flying(turnIn: turnIn - dt)
                }
            case .hit(let age):
                b.state = age + dt >= Self.freezeTime ? .falling : .hit(age: age + dt)
            case .falling:
                b.y -= Self.fallSpeed * dt
                if b.y < Self.grassTop - 18 {
                    b.state = .gone(caught: true)
                    ev.fell = true
                }
            case .escaping:
                b.y += Self.escapeSpeed * dt
                if b.y > Self.height + 30 { b.state = .gone(caught: false) }
            case .gone:
                break
            }
            bugs[i] = b
        }
    }

    private mutating func endFlight(_ ev: inout Events) {
        var caught: [Kind] = []
        var lastX = Self.width / 2
        for (k, b) in bugs.enumerated() where slot + k < results.count {
            let hit = b.state == .gone(caught: true)
            results[slot + k] = hit ? .hit : .miss
            if hit {
                caught.append(b.kind)
                lastX = b.x
            }
        }
        slot += bugs.count
        bugs = []
        if caught.isEmpty {
            phase = .laugh(t: 0)
            ev.laugh = true
        } else {
            phase = .retrieve(t: 0, x: min(max(lastX, 40), Self.width - 40), kinds: caught)
            ev.retrieve = true
        }
    }

    private mutating func nextFlight(_ ev: inout Events) {
        if slot >= Self.bugsPerRound {
            let passed = hitsThisRound >= Self.needed(round: round)
            phase = .roundEnd(t: 0, passed: passed)
            if passed { ev.roundPassed = true }
        } else {
            launchFlight()
        }
    }

    private mutating func nextRound() {
        round += 1
        results = Array(repeating: .pending, count: Self.bugsPerRound)
        slot = 0
        phase = .banner(t: 0)
    }

    // MARK: - The high score, one per game

    enum Prefs {
        static func key(_ mode: Mode) -> String { mode == .a ? "huntHighScoreA" : "huntHighScoreB" }
        static func highScore(_ mode: Mode, _ d: UserDefaults = .standard) -> Int { d.integer(forKey: key(mode)) }
        /// Records `score` if it beats the one kept for `mode`; true when it did.
        @discardableResult
        static func record(_ score: Int, mode: Mode, _ d: UserDefaults = .standard) -> Bool {
            guard score > highScore(mode, d) else { return false }
            d.set(score, forKey: key(mode))
            return true
        }
    }
}
