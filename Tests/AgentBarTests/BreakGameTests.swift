import AppKit
import Foundation
import Testing
@testable import AgentBar

/// Take a break, played frame by frame. The model has no clock and no chance of
/// its own, so every one of these is the same game every run.
@Suite struct BreakGameTests {
    private func playing(seed: UInt64 = 1) -> BreakGame {
        var g = BreakGame(seed: seed)
        g.fire()                      // the first Space starts it
        #expect(g.phase == .playing)
        #expect(g.shots.isEmpty)
        return g
    }

    private func run(_ g: inout BreakGame, seconds: Double) -> BreakGame.Events {
        var all = BreakGame.Events()
        for _ in 0..<Int(seconds * 60) {
            let e = g.step(dt: 1.0 / 60)
            all.hits += e.hits
            all.lostLife = all.lostLife || e.lostLife
            all.gameOver = all.gameOver || e.gameOver
            all.waveCleared = all.waveCleared || e.waveCleared
        }
        return all
    }

    @Test func theFormationIsGalaxiansBands() {
        let f = BreakGame.formation()
        #expect(f.count == 4 + 8 + 8 + 8)
        #expect(f.filter { $0.kind == .boss }.map(\.column) == [2, 3, 4, 5])
        #expect(Set(f.map(\.id)).count == f.count)
        for e in f {
            #expect(e.x > 0 && e.x < BreakGame.width)
            #expect(e.y < BreakGame.height && e.y > BreakGame.height / 2)
        }
    }

    @Test func aShotThatHitsScoresAndIsSpent() {
        var g = playing()
        g.diveIn = 999
        let target = g.enemies.first { $0.kind == .drone && $0.row == 3 }!
        g.playerX = target.x
        g.clock = 0
        g.shots = [.init(x: target.x, y: target.y - 4, vy: BreakGame.shotSpeed)]
        // Hold the sway still for the one frame: the slot is where it was.
        let e = g.step(dt: 0.001)
        #expect(e.hits == 1)
        #expect(g.score == BreakGame.Kind.drone.points)
        #expect(g.shots.isEmpty)
        #expect(!g.enemies.contains { $0.id == target.id })
    }

    @Test func aDiverIsWorthTwice() {
        var g = playing()
        g.diveIn = 999
        let i = g.enemies.firstIndex { $0.kind == .wasp }!
        g.enemies[i].motion = .diving(age: 0, fromX: 150, fromY: 200, side: 1, firesAt: [])
        g.enemies[i].x = 150
        g.enemies[i].y = 200
        g.shots = [.init(x: 150, y: 200, vy: 0)]
        g.step(dt: 0.0001)
        #expect(g.score == BreakGame.Kind.wasp.points * 2)
    }

    @Test func onlyTwoShotsAtOnce() {
        var g = playing()
        g.fire(); g.fire(); g.fire()
        #expect(g.shots.count == BreakGame.maxShots)
    }

    @Test func aHitCostsALifeAndTheLastOneEndsIt() {
        var g = playing()
        g.diveIn = 999
        g.enemyShots = [.init(x: g.playerX, y: BreakGame.playerY, vy: 0)]
        let e = g.step(dt: 0.001)
        #expect(e.lostLife)
        #expect(g.lives == BreakGame.startLives - 1)
        #expect(g.respawn > 0)
        // While it is gone it cannot be hit again, nor fire.
        g.enemyShots = [.init(x: BreakGame.width / 2, y: BreakGame.playerY, vy: 0)]
        g.fire()
        #expect(g.shots.isEmpty)
        #expect(!g.step(dt: 0.01).lostLife)
        g.lives = 1
        g.respawn = 0
        g.shield = 0
        g.enemyShots = [.init(x: g.playerX, y: BreakGame.playerY, vy: 0)]
        let over = g.step(dt: 0.001)
        #expect(over.gameOver)
        #expect(g.phase == .over)
        #expect(g.lives == 0)
    }

    @Test func aClearedWaveBringsAFasterOne() {
        var g = playing()
        let pace = g.pace
        g.enemies = []
        let e = g.step(dt: 0.01)
        #expect(e.waveCleared)
        #expect(g.wave == 2)
        #expect(g.pace > pace)
        #expect(g.enemies.count == BreakGame.formation().count)
        if case .intro = g.phase {} else { Issue.record("expected the wave banner, got \(g.phase)") }
        _ = run(&g, seconds: BreakGame.waveIntro + 0.1)
        #expect(g.phase == .playing)
    }

    @Test func diversLeaveAndComeBack() {
        var g = playing(seed: 9)
        g.diveIn = 0
        g.step(dt: 0.01)
        #expect(g.enemies.contains { if case .diving = $0.motion { return true }; return false })
        // Out of the way of the divers, so nothing ends the run early.
        g.shield = 999
        _ = run(&g, seconds: 12)
        #expect(g.enemies.allSatisfy { e in
            switch e.motion { case .formation, .returning, .diving: return true }
        })
    }

    /// A whole game with nobody at the keys ends, and never runs anything off the field.
    @Test func anIdleGameEndsAndStaysOnTheField() {
        var g = playing(seed: 3)
        let ev = run(&g, seconds: 240)
        #expect(ev.gameOver)
        #expect(g.phase == .over)
        #expect(g.playerX >= BreakGame.playerSize.w / 2 && g.playerX <= BreakGame.width - BreakGame.playerSize.w / 2)
    }

    @Test func theShipStaysInsideTheWalls() {
        var g = playing()
        g.diveIn = 999
        g.input = .init(left: true)
        _ = run(&g, seconds: 3)
        #expect(g.playerX == BreakGame.playerSize.w / 2)
        g.input = .init(right: true)
        _ = run(&g, seconds: 3)
        #expect(g.playerX == BreakGame.width - BreakGame.playerSize.w / 2)
    }

    @Test func aHugeOrNegativeStepIsClamped() {
        var g = playing()
        g.diveIn = 999
        let before = g
        g.step(dt: -5)
        #expect(g.clock == before.clock)
        g.step(dt: 30)                  // a laptop waking: one frame's worth, not thirty seconds
        #expect(g.clock <= before.clock + 0.05 + 1e-9)
    }

    @Test func aTokenCaughtScoresAHundred() {
        var g = playing()
        g.diveIn = 999
        g.droppedTokens = [.init(x: g.playerX, y: BreakGame.playerY)]
        let e = g.step(dt: 0.001)
        #expect(e.token)
        #expect(g.tokens == 1)
        #expect(g.score == BreakGame.tokenValue)
    }

    @Test func restartKeepsNothingButTheDice() {
        var g = playing()
        g.score = 999
        g.wave = 4
        g.phase = .over
        g.restart()
        #expect(g.score == 0 && g.wave == 1 && g.lives == BreakGame.startLives)
        #expect(g.phase == .playing)
    }

    @Test func theSameSeedPlaysTheSameGame() {
        var a = playing(seed: 77), b = playing(seed: 77)
        _ = run(&a, seconds: 20)
        _ = run(&b, seconds: 20)
        #expect(a.score == b.score && a.enemies == b.enemies && a.lives == b.lives)
    }

    // MARK: - Yielding

    @Test func onlySomethingNewMakesItStepAside() {
        let before: Set = ["req:a", "ses:x"]
        #expect(!BreakGame.yields(before: before, now: before))
        #expect(!BreakGame.yields(before: before, now: ["req:a"]))       // one answered
        #expect(BreakGame.yields(before: before, now: before.union(["req:b"])))
        #expect(BreakGame.yields(before: [], now: ["ses:y"]))
    }

    // MARK: - The high score

    @Test func theHighScoreIsKeptOnlyWhenBeaten() throws {
        let d = try #require(UserDefaults(suiteName: "agentbar-break-\(UUID().uuidString)"))
        #expect(BreakGame.Prefs.highScore(d) == 0)
        #expect(BreakGame.Prefs.record(500, d))
        #expect(!BreakGame.Prefs.record(400, d))
        #expect(!BreakGame.Prefs.record(500, d))
        #expect(BreakGame.Prefs.highScore(d) == 500)
    }

    // MARK: - The art

    @Test func everyPictureIsRectangularAndInThePalette() {
        var arts = [BreakGameArt.ship, BreakGameArt.token] + BreakGameArt.burst
        arts += BreakGameArt.bugs.values.flatMap { $0 }
        #expect(BreakGameArt.bugs.count == BreakGame.Kind.allCases.count)
        for art in arts {
            let lines = art.split(separator: "\n")
            #expect(Set(lines.map(\.count)).count == 1, "ragged: \(art)")
            for ch in art where ch != "\n" && ch != "." {
                #expect(BreakGameArt.palette[ch] != nil, "no colour for \(ch)")
            }
            #expect(BreakGameArt.image(art, pixel: 2) != nil)
        }
    }

    @Test func theFontCoversEverythingTheGameSays() {
        for (k, g) in BreakGameArt.glyphs { #expect(g.count == 15, "\(k)") }
        let said = "TAKE A BREAK SPACE TO START WAVE GAME OVER NEW HIGH SCORE! RETURN PLAY AGAIN "
            + "ESC CLOSE PAUSED CLICK OR SPACE TO PLAY SCORE HI SHIPS TOKENS < > MOVE FIRE P 0123456789"
        for ch in said where ch != " " {
            #expect(!BreakGameArt.cells(ch).isEmpty, "\(ch) is blank")
        }
    }

    /// The offscreen render is how the game is looked at without a panel over
    /// anybody's screen; it must keep working.
    @Test @MainActor func itRendersOffscreen() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("break-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(BreakGameView.renderForVerification(to: url))
        let img = try #require(NSImage(contentsOf: url))
        #expect(img.size.width > BreakGameView.size.width * 3)
    }

    @Test func scoresReadWithAThinSpace() {
        #expect(IslandController.grouped(1230) == "1 230")
        #expect(IslandController.grouped(7) == "7")
    }
}
