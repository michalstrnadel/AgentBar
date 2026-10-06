import AppKit
import Foundation
import Testing
@testable import AgentBar

/// Bug Hunt, played frame by frame. Like Take a break, the model has no clock and
/// no chance of its own, so each of these is the same game every run.
@Suite struct HuntGameTests {
    /// A game with its first flight in the air.
    private func flying(seed: UInt64 = 1, mode: HuntGame.Mode = .a) -> HuntGame {
        var g = HuntGame(seed: seed)
        g.start(mode)
        run(&g, seconds: HuntGame.introTime + HuntGame.bannerTime + 0.1)
        #expect(g.phase == .flight)
        return g
    }

    @discardableResult
    private func run(_ g: inout HuntGame, seconds: Double) -> HuntGame.Events {
        var all = HuntGame.Events()
        for _ in 0..<Int(seconds * 60) {
            let e = g.step(dt: 1.0 / 60)
            all.fell = all.fell || e.fell
            all.flyAway = all.flyAway || e.flyAway
            all.laugh = all.laugh || e.laugh
            all.retrieve = all.retrieve || e.retrieve
            all.roundPassed = all.roundPassed || e.roundPassed
            all.perfect = all.perfect || e.perfect
            all.gameOver = all.gameOver || e.gameOver
        }
        return all
    }

    private func isFlying(_ b: HuntGame.Bug) -> Bool {
        if case .flying = b.state { return true }
        return false
    }

    @Test func aRoundOpensWithClawdThenTheBanner() {
        var g = HuntGame(seed: 1)
        #expect(g.phase == .title)
        g.start(.a)
        if case .intro = g.phase {} else { Issue.record("expected the walk-in, got \(g.phase)") }
        g.skipIntro()
        if case .banner = g.phase {} else { Issue.record("a click skips the walk-in, got \(g.phase)") }
        run(&g, seconds: HuntGame.bannerTime + 0.05)
        #expect(g.phase == .flight)
        #expect(g.bugs.count == 1)
        #expect(g.shotsLeft == HuntGame.shotsPerFlight)
    }

    @Test func aShotOnTheBugHitsAndScoresByKind() {
        var g = flying()
        let b = g.bugs[0]
        let ev = g.shoot(x: b.x + 3, y: b.y - 3)
        #expect(ev.shot && ev.hits == 1)
        #expect(g.score == HuntGame.points(b.kind, round: 1))
        #expect(g.bugs[0].state == .hit(age: 0))
        #expect(g.shotsLeft == 2)
    }

    @Test func threeMissesAndItFliesAwayAndAFourthShotIsRefused() {
        var g = flying()
        for _ in 0..<3 { #expect(g.shoot(x: 1, y: HuntGame.height - 1).hits == 0) }
        #expect(g.shotsLeft == 0)
        #expect(g.bugs[0].state == .escaping)
        #expect(g.skyAlarmed)
        #expect(!g.shoot(x: g.bugs[0].x, y: g.bugs[0].y).shot)
        let ev = run(&g, seconds: 4)
        #expect(ev.laugh)
        #expect(g.results[0] == .miss)
    }

    @Test func runningOutOfTimeIsAFlyAwayToo() {
        var g = flying(seed: 4)
        let ev = run(&g, seconds: HuntGame.flightTime + 0.1)
        #expect(ev.flyAway)
        #expect(g.bugs.allSatisfy { !isFlying($0) })
    }

    @Test func aHitFreezesFallsAndClawdHoldsItUp() {
        var g = flying(seed: 2)
        let b = g.bugs[0]
        g.shoot(x: b.x, y: b.y)
        run(&g, seconds: HuntGame.freezeTime * 0.5)
        if case .hit = g.bugs[0].state {} else { Issue.record("still frozen, got \(g.bugs[0].state)") }
        #expect(g.bugs[0].x == b.x)
        let ev = run(&g, seconds: 4)
        #expect(ev.fell && ev.retrieve)
        if case .retrieve(_, _, let kinds) = g.phase {
            #expect(kinds == [b.kind])
        } else if g.phase != .flight {
            Issue.record("expected Clawd with the catch or the next flight, got \(g.phase)")
        }
        #expect(g.results[0] == .hit)
    }

    @Test func pointsNeededAndBonusesFollowTheRoundBands() {
        #expect(HuntGame.points(.drone, round: 1) == 500)
        #expect(HuntGame.points(.wasp, round: 5) == 1000)
        #expect(HuntGame.points(.boss, round: 6) == 2400)
        #expect(HuntGame.points(.drone, round: 11) == 1000)
        #expect([1, 10, 11, 13, 15, 20].map(HuntGame.needed) == [6, 6, 7, 8, 9, 10])
        #expect(HuntGame.perfectBonus(round: 3) == 10_000)
        #expect(HuntGame.perfectBonus(round: 21) == 30_000)
        #expect(HuntGame.speed(.drone, round: 5, mode: .a) > HuntGame.speed(.drone, round: 1, mode: .a))
        #expect(HuntGame.speed(.drone, round: 99, mode: .a) == HuntGame.speed(.drone, round: 200, mode: .a))
    }

    /// The end of a round, reached the way play reaches it: the last flight's laugh runs out.
    private func endRound(hits: Int) -> (HuntGame, HuntGame.Events) {
        var g = flying()
        g.bugs = []
        g.results = (0..<HuntGame.bugsPerRound).map { $0 < hits ? .hit : .miss }
        g.slot = HuntGame.bugsPerRound
        g.phase = .laugh(t: 0)
        let ev = run(&g, seconds: HuntGame.laughTime + 0.1)
        return (g, ev)
    }

    @Test func enoughHitsPassTheRoundAndTooFewEndTheGame() {
        var (pass, ev) = endRound(hits: 6)
        #expect(ev.roundPassed)
        run(&pass, seconds: HuntGame.roundEndTime + 0.1)
        #expect(pass.round == 2)
        if case .banner = pass.phase {} else { Issue.record("expected round 2's banner, got \(pass.phase)") }
        #expect(pass.results.allSatisfy { $0 == .pending })

        var (fail, _) = endRound(hits: 5)
        let over = run(&fail, seconds: HuntGame.roundEndTime + 0.1)
        #expect(over.gameOver)
        #expect(fail.phase == .over)
    }

    @Test func tenOutOfTenIsPerfectWithItsBonus() {
        var (g, _) = endRound(hits: 10)
        let before = g.score
        let ev = run(&g, seconds: HuntGame.roundEndTime + 0.1)
        #expect(ev.perfect)
        #expect(g.score == before + HuntGame.perfectBonus(round: 1))
        run(&g, seconds: HuntGame.perfectTime + 0.1)
        #expect(g.round == 2)
    }

    @Test func gameBFliesPairsThatShareThreeShots() {
        var g = flying(mode: .b)
        #expect(g.bugs.count == 2)
        let a = g.bugs[0]
        g.shoot(x: a.x, y: a.y)
        g.shoot(x: 1, y: HuntGame.height - 1)
        #expect(g.shotsLeft == 1)
        g.shoot(x: 1, y: HuntGame.height - 1)
        #expect(g.shotsLeft == 0)
        run(&g, seconds: 6)
        #expect(g.slot == 2)
        #expect(g.results[0] == .hit && g.results[1] == .miss)
    }

    @Test func bugsStayInTheSkyAndBounce() {
        var g = flying(seed: 9)
        var bounced = false
        let start = g.bugs[0].vx
        for _ in 0..<Int(HuntGame.flightTime * 60) - 10 {
            g.step(dt: 1.0 / 60)
            for b in g.bugs where isFlying(b) {
                #expect(b.x >= HuntGame.bugSize.w / 2 && b.x <= HuntGame.width - HuntGame.bugSize.w / 2)
                #expect(b.y <= HuntGame.height)
                if b.vx.sign != start.sign { bounced = true }
            }
        }
        #expect(bounced)
    }

    @Test func theSameSeedHuntsTheSameGame() {
        var a = flying(seed: 77), b = flying(seed: 77)
        run(&a, seconds: 3)
        run(&b, seconds: 3)
        #expect(a.bugs == b.bugs && a.score == b.score)
    }

    @Test func aHugeOrNegativeStepIsClamped() {
        var g = flying()
        let before = g.clock
        g.step(dt: -5)
        #expect(g.clock == before)
        g.step(dt: 30)
        #expect(g.clock <= before + 0.05 + 1e-9)
    }

    @Test func eachGameKeepsItsOwnHighScore() throws {
        let d = try #require(UserDefaults(suiteName: "agentbar-hunt-\(UUID().uuidString)"))
        #expect(HuntGame.Prefs.record(4_000, mode: .a, d))
        #expect(!HuntGame.Prefs.record(3_000, mode: .a, d))
        #expect(HuntGame.Prefs.highScore(.b, d) == 0)
        #expect(HuntGame.Prefs.record(1_000, mode: .b, d))
        #expect(HuntGame.Prefs.highScore(.a, d) == 4_000)
    }

    // MARK: - The art and the words

    @Test func everyPictureIsRectangularAndInThePalette() {
        for art in HuntGameArt.all {
            let lines = art.split(separator: "\n")
            #expect(Set(lines.map(\.count)).count == 1, "ragged: \(art)")
            for ch in art where ch != "\n" && ch != "." {
                #expect(HuntGameArt.palette[ch] != nil, "no colour for \(ch)")
            }
            #expect(HuntGameArt.image(art, pixel: 2) != nil)
        }
    }

    @Test func theFontCoversEverythingTheHuntSays() {
        let said = "BUG HUNT GAME A 1 BUG B 2 BUGS TOP SCORE A= CLICK A GAME OR PRESS 1 OR 2 ROUND FLY AWAY "
            + "PERFECT!! GAME OVER NEW HIGH SCORE! RETURN PLAY AGAIN ESC CLOSE PAUSED SPACE TO R= SHOT HIT 0123456789"
        for ch in said where ch != " " {
            #expect(!BreakGameArt.cells(ch).isEmpty, "\(ch) is blank")
        }
    }

    @Test @MainActor func itRendersOffscreen() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hunt-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(HuntGameView.renderForVerification(to: url))
        let img = try #require(NSImage(contentsOf: url))
        #expect(img.size.width > HuntGameView.size.width * 5)
    }

    @Test @MainActor func bothGamesFillTheSameIsland() throws {
        let d = try #require(UserDefaults(suiteName: "agentbar-games-\(UUID().uuidString)"))
        for choice in GameChoice.allCases {
            let v = choice.make(defaults: d)
            #expect(v.intrinsicContentSize == GameChoice.size, "\(choice)")
            #expect(v.score == 0)
        }
    }
}
