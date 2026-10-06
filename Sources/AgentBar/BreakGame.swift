import Foundation

/// **Space Bugs**, one of Take a break's two games: a small Galaxian-like shooter
/// that runs inside the island when
/// the person asks for it from the island's ⋯ menu — and steps aside the moment an
/// agent needs them (`yields(before:now:)`). Clawd is the ship; the formation is bugs.
///
/// This is the whole game as a value: state, `step(dt:)`, nothing else. No AppKit,
/// no clock and no randomness of its own — time comes in as `dt` and chance from a
/// seeded generator — so a test can play it frame by frame and know what happens.
/// `BreakGameView` draws it and feeds it keys; `IslandController+Game` decides when
/// it is on screen.
///
/// Coordinates are points in the playfield, origin bottom-left, y up.
struct BreakGame {
    // MARK: - Shape of the field

    static let width: Double = 296
    static let height: Double = 470
    static let columns = 8
    static let cellWidth: Double = 32
    static let cellHeight: Double = 24
    static let formationTop: Double = height - 56
    static let sway: Double = 16

    static let playerY: Double = 26
    static let playerSize = (w: 22.0, h: 14.0)
    static let enemySize = (w: 20.0, h: 14.0)
    static let shotSize = (w: 2.0, h: 8.0)
    static let tokenSize = (w: 10.0, h: 10.0)

    static let playerSpeed: Double = 170
    static let shotSpeed: Double = 380
    static let maxShots = 2
    static let startLives = 3
    static let respawnDelay: Double = 1.2
    static let invulnerable: Double = 1.6
    static let waveIntro: Double = 1.6
    static let tokenChance = 0.25
    static let tokenValue = 100

    // MARK: - Things on the field

    enum Kind: Int, CaseIterable {
        case drone, wasp, boss

        /// Points in formation; a diver is worth twice as much.
        var points: Int {
            switch self {
            case .drone: return 30
            case .wasp:  return 50
            case .boss:  return 80
            }
        }
    }

    enum Motion: Equatable {
        case formation
        /// Swooping down towards where the ship was, `age` seconds in.
        case diving(age: Double, fromX: Double, fromY: Double, side: Double, firesAt: [Double])
        /// Off the bottom, coming back in from the top to its slot.
        case returning
    }

    struct Enemy: Equatable {
        var id: Int
        var kind: Kind
        var row: Int
        var column: Int
        var x: Double
        var y: Double
        var motion: Motion = .formation
    }

    struct Shot: Equatable {
        var x: Double
        var y: Double
        var vy: Double
    }

    struct Token: Equatable {
        var x: Double
        var y: Double
    }

    struct Burst: Equatable {
        var x: Double
        var y: Double
        var age: Double = 0
        var big = false
    }

    enum Phase: Equatable {
        /// Before the first shot: the title over the formation.
        case ready
        case playing
        /// The banner between waves.
        case intro(left: Double)
        case over
    }

    /// What `step` was told the keys are doing.
    struct Input: Equatable {
        var left = false
        var right = false
    }

    /// What happened in one step, for sound and nothing else.
    struct Events: Equatable {
        var hits = 0
        var lostLife = false
        var gameOver = false
        var token = false
        var waveCleared = false
    }

    // MARK: - State

    var phase: Phase = .ready
    var wave = 1
    var score = 0
    var lives = startLives
    var tokens = 0
    var playerX = width / 2
    /// Seconds until the ship is back after a hit; 0 while it is on the field.
    var respawn: Double = 0
    /// Seconds the ship cannot be hit for after it came back.
    var shield: Double = 0
    var enemies: [Enemy] = []
    var shots: [Shot] = []
    var enemyShots: [Shot] = []
    var droppedTokens: [Token] = []
    var bursts: [Burst] = []
    /// Seconds since the wave began: drives the formation's sway.
    var clock: Double = 0
    var diveIn: Double = 2.5
    var input = Input()
    var rng: SplitMix64

    init(seed: UInt64 = 0x5eed) {
        rng = SplitMix64(seed: seed)
        enemies = Self.formation()
    }

    // MARK: - Difficulty

    /// How much harder each wave is, capped so wave 12 is not a wall.
    var pace: Double { min(1 + Double(wave - 1) * 0.15, 2.2) }
    var swaySpeed: Double { 1.1 * pace }
    var diveGap: Double { max(0.9, 3.0 / pace) }
    var diveSpeed: Double { 120 * pace }
    var enemyShotSpeed: Double { 190 * min(pace, 1.8) }
    var diversAtOnce: Int { wave >= 3 ? 2 : 1 }

    // MARK: - The formation

    /// Four rows: four bosses in the middle of the top one, then wasps, then two of
    /// drones — Galaxian's colour bands.
    static func formation() -> [Enemy] {
        var out: [Enemy] = []
        var id = 0
        for row in 0..<4 {
            let kind: Kind = row == 0 ? .boss : row == 1 ? .wasp : .drone
            for column in 0..<columns where row != 0 || (2...5).contains(column) {
                let (x, y) = slot(row: row, column: column, clock: 0)
                out.append(Enemy(id: id, kind: kind, row: row, column: column, x: x, y: y))
                id += 1
            }
        }
        return out
    }

    /// Where a slot is at a moment: the grid, centred, swaying side to side.
    static func slot(row: Int, column: Int, clock: Double, swaySpeed: Double = 1.1) -> (Double, Double) {
        let left = (width - Double(columns) * cellWidth) / 2 + cellWidth / 2
        let offset = sin(clock * swaySpeed) * sway
        return (left + Double(column) * cellWidth + offset, formationTop - Double(row) * cellHeight)
    }

    // MARK: - Commands

    /// Space: the first press starts the game; after that, a shot if one is free.
    mutating func fire() {
        switch phase {
        case .ready: phase = .playing
        case .playing:
            guard respawn == 0, shots.count < Self.maxShots else { return }
            shots.append(Shot(x: playerX, y: Self.playerY + Self.playerSize.h / 2, vy: Self.shotSpeed))
        case .intro, .over: return
        }
    }

    /// Return on the game-over screen: a fresh game, same generator.
    mutating func restart() {
        let r = rng
        self = BreakGame()
        rng = r
        phase = .playing
    }

    // MARK: - Time

    @discardableResult
    mutating func step(dt raw: Double) -> Events {
        var ev = Events()
        let dt = min(max(raw, 0), 0.05)
        guard dt > 0 else { return ev }
        bursts = bursts.compactMap { b in
            var b = b
            b.age += dt
            return b.age < 0.4 ? b : nil
        }
        switch phase {
        case .ready, .over:
            clock += dt
            settleFormation()
            return ev
        case .intro(let left):
            clock += dt
            settleFormation()
            if left - dt <= 0 {
                phase = .playing
            } else {
                phase = .intro(left: left - dt)
            }
            return ev
        case .playing:
            break
        }
        clock += dt
        moveShip(dt)
        moveShots(dt)
        moveEnemies(dt)
        scheduleDives(dt)
        moveTokens(dt, &ev)
        collide(&ev)
        if enemies.isEmpty {
            ev.waveCleared = true
            wave += 1
            enemies = Self.formation()
            shots = []
            enemyShots = []
            clock = 0
            diveIn = 2.0
            phase = .intro(left: Self.waveIntro)
        }
        return ev
    }

    private mutating func moveShip(_ dt: Double) {
        if respawn > 0 {
            respawn = max(0, respawn - dt)
            if respawn == 0 { shield = Self.invulnerable; playerX = Self.width / 2 }
            return
        }
        shield = max(0, shield - dt)
        let dir = (input.right ? 1.0 : 0) - (input.left ? 1.0 : 0)
        let half = Self.playerSize.w / 2
        playerX = min(max(playerX + dir * Self.playerSpeed * dt, half), Self.width - half)
    }

    private mutating func moveShots(_ dt: Double) {
        shots = shots.map { var s = $0; s.y += s.vy * dt; return s }.filter { $0.y < Self.height + 10 }
        enemyShots = enemyShots.map { var s = $0; s.y += s.vy * dt; return s }.filter { $0.y > -10 }
    }

    private mutating func settleFormation() {
        for i in enemies.indices where enemies[i].motion == .formation {
            let (x, y) = Self.slot(row: enemies[i].row, column: enemies[i].column, clock: clock,
                                   swaySpeed: swaySpeed)
            enemies[i].x = x
            enemies[i].y = y
        }
    }

    private mutating func moveEnemies(_ dt: Double) {
        for i in enemies.indices {
            let (sx, sy) = Self.slot(row: enemies[i].row, column: enemies[i].column, clock: clock,
                                     swaySpeed: swaySpeed)
            switch enemies[i].motion {
            case .formation:
                enemies[i].x = sx
                enemies[i].y = sy
            case .diving(let age, let fromX, let fromY, let side, var firesAt):
                let a = age + dt
                // A swoop: out to one side, then down across the field.
                enemies[i].x = min(max(fromX + side * 70 * sin(a * 2.2), 8), Self.width - 8)
                enemies[i].y = fromY - diveSpeed * a + 30 * sin(min(a, 0.7) * .pi / 0.7)
                if let next = firesAt.first, a >= next {
                    firesAt.removeFirst()
                    enemyShots.append(Shot(x: enemies[i].x, y: enemies[i].y - Self.enemySize.h / 2,
                                           vy: -enemyShotSpeed))
                }
                if enemies[i].y < -20 {
                    enemies[i].motion = .returning
                    enemies[i].y = Self.height + 20
                    enemies[i].x = sx
                } else {
                    enemies[i].motion = .diving(age: a, fromX: fromX, fromY: fromY, side: side,
                                                firesAt: firesAt)
                }
            case .returning:
                let dy = sy - enemies[i].y
                let step = 160 * dt
                if abs(dy) <= step {
                    enemies[i].motion = .formation
                    enemies[i].x = sx
                    enemies[i].y = sy
                } else {
                    enemies[i].y += dy > 0 ? step : -step
                    enemies[i].x += (sx - enemies[i].x) * min(1, dt * 4)
                }
            }
        }
    }

    private mutating func scheduleDives(_ dt: Double) {
        diveIn -= dt
        guard diveIn <= 0 else { return }
        diveIn = diveGap * (0.7 + 0.6 * rng.unit())
        let idle = enemies.indices.filter { enemies[$0].motion == .formation }
        guard !idle.isEmpty else { return }
        for _ in 0..<min(diversAtOnce, idle.count) {
            let candidates = enemies.indices.filter { enemies[$0].motion == .formation }
            guard !candidates.isEmpty else { break }
            let i = candidates[Int(rng.unit() * Double(candidates.count)) % candidates.count]
            let side: Double = enemies[i].x < playerX ? 1 : -1
            let shots = 1 + (rng.unit() < 0.4 ? 1 : 0)
            let times = (0..<shots).map { 0.5 + Double($0) * 0.55 + rng.unit() * 0.3 }
            enemies[i].motion = .diving(age: 0, fromX: enemies[i].x, fromY: enemies[i].y,
                                        side: side, firesAt: times)
        }
    }

    private mutating func moveTokens(_ dt: Double, _ ev: inout Events) {
        droppedTokens = droppedTokens.map { var t = $0; t.y -= 90 * dt; return t }.filter { $0.y > -10 }
        guard respawn == 0 else { return }
        let caught = droppedTokens.filter {
            Self.overlaps($0.x, $0.y, Self.tokenSize, playerX, Self.playerY, Self.playerSize)
        }
        guard !caught.isEmpty else { return }
        droppedTokens.removeAll { t in caught.contains(t) }
        tokens += caught.count
        score += caught.count * Self.tokenValue
        ev.token = true
    }

    private mutating func collide(_ ev: inout Events) {
        // Our shots against the bugs.
        var spent = Set<Int>()
        var killed = Set<Int>()
        for (si, s) in shots.enumerated() {
            for e in enemies where !killed.contains(e.id) {
                if Self.overlaps(s.x, s.y, Self.shotSize, e.x, e.y, Self.enemySize) {
                    spent.insert(si)
                    killed.insert(e.id)
                    var diving = false
                    if case .diving = e.motion { diving = true }
                    score += e.kind.points * (diving ? 2 : 1)
                    bursts.append(Burst(x: e.x, y: e.y))
                    ev.hits += 1
                    if diving, rng.unit() < Self.tokenChance {
                        droppedTokens.append(Token(x: e.x, y: e.y))
                    }
                    break
                }
            }
        }
        shots = shots.enumerated().filter { !spent.contains($0.offset) }.map(\.element)
        enemies.removeAll { killed.contains($0.id) }

        // Theirs, and the divers themselves, against the ship.
        guard respawn == 0, shield == 0 else { return }
        let hitByShot = enemyShots.firstIndex {
            Self.overlaps($0.x, $0.y, Self.shotSize, playerX, Self.playerY, Self.playerSize)
        }
        let rammed = enemies.firstIndex {
            Self.overlaps($0.x, $0.y, Self.enemySize, playerX, Self.playerY, Self.playerSize)
        }
        guard hitByShot != nil || rammed != nil else { return }
        if let i = hitByShot { enemyShots.remove(at: i) }
        if let i = rammed {
            bursts.append(Burst(x: enemies[i].x, y: enemies[i].y))
            enemies.remove(at: i)
        }
        bursts.append(Burst(x: playerX, y: Self.playerY, big: true))
        lives -= 1
        ev.lostLife = true
        if lives <= 0 {
            lives = 0
            phase = .over
            ev.gameOver = true
        } else {
            respawn = Self.respawnDelay
            enemyShots = []
        }
    }

    static func overlaps(_ ax: Double, _ ay: Double, _ a: (w: Double, h: Double),
                         _ bx: Double, _ by: Double, _ b: (w: Double, h: Double)) -> Bool {
        abs(ax - bx) * 2 < a.w + b.w && abs(ay - by) * 2 < a.h + b.h
    }

    // MARK: - Yielding to work

    /// Whether something that waits on the person turned up since `before` was
    /// taken: a request, or a session asking. Only something **new** — what was
    /// already waiting when the break began was the person's to leave for later.
    static func yields(before: Set<String>, now: Set<String>) -> Bool {
        !now.subtracting(before).isEmpty
    }

    // MARK: - The high score

    enum Prefs {
        static let key = "breakGameHighScore"
        static func highScore(_ d: UserDefaults = .standard) -> Int { d.integer(forKey: key) }
        /// Records `score` if it beats the one kept; true when it did.
        @discardableResult
        static func record(_ score: Int, _ d: UserDefaults = .standard) -> Bool {
            guard score > highScore(d) else { return false }
            d.set(score, forKey: key)
            return true
        }
    }
}

/// A small, fast, seedable generator: the game's only source of chance.
struct SplitMix64: Equatable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// In [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
