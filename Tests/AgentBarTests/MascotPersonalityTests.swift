import AppKit
import Testing
@testable import AgentBar

/// The island mascot's small signs of life. Everything here runs against the pure
/// decisions with the clock passed in; nothing touches a panel or a timer.
struct MascotPersonalityTests {
    typealias P = MascotPersonality

    // MARK: - Switch

    @Test func reduceMotionWinsOverTheSwitch() {
        #expect(P.plays(enabled: true, reduceMotion: false))
        #expect(!P.plays(enabled: true, reduceMotion: true))
        #expect(!P.plays(enabled: false, reduceMotion: false))
    }

    // MARK: - Gaze

    /// A moving pointer: each call lands somewhere new, so boredom never kicks in.
    private func look(_ g: inout P.Gaze, _ dx: Double, _ dy: Double, at now: TimeInterval) -> P.Pupil {
        g.follow(dx: dx, dy: dy, pointer: (dx + now, dy), now: now)
    }

    @Test func eyesTurnTowardThePointer() {
        var g = P.Gaze()
        var r = look(&g, 200, 0, at: 0)
        #expect(r == P.Pupil(dx: 1, dy: 0))
        r = look(&g, -200, 0, at: 1)
        #expect(r == P.Pupil(dx: -1, dy: 0))
        // Below and to the right — the usual place for a pointer under the notch.
        r = look(&g, 100, -100, at: 2)
        #expect(r == P.Pupil(dx: 1, dy: -1))
        r = look(&g, 0, -150, at: 3)
        #expect(r == P.Pupil(dx: 0, dy: -1))
    }

    @Test func farAwayLooksAhead() {
        var g = P.Gaze()
        var r = look(&g, 1000, -400, at: 0)
        #expect(r == .ahead)
        r = look(&g, 200, 0, at: 1)
        #expect(r == P.Pupil(dx: 1, dy: 0))
        // Following: a little past `reach` still holds, past `releaseReach` lets go.
        r = look(&g, P.Gaze.reach + 20, 0, at: 2)
        #expect(r == P.Pupil(dx: 1, dy: 0))
        r = look(&g, P.Gaze.releaseReach + 1, 0, at: 3)
        #expect(r == .ahead)
    }

    @Test func hysteresisHoldsAnAxisNearItsBoundary() {
        // 0.35 is between release (0.28) and engage (0.45): it cannot turn an eye
        // that is ahead, and it does not bring back one that already turned.
        #expect(P.Gaze.step(0.35, current: 0) == 0)
        #expect(P.Gaze.step(0.35, current: 1) == 1)
        #expect(P.Gaze.step(-0.35, current: -1) == -1)
        #expect(P.Gaze.step(0.2, current: 1) == 0)
        #expect(P.Gaze.step(0.5, current: 0) == 1)
        // Swinging straight across needs the full engage on the other side.
        #expect(P.Gaze.step(-0.35, current: 1) == 0)
    }

    @Test func pointerOnTheMarkHoldsTheEyes() {
        var g = P.Gaze()
        var r = look(&g, 200, 0, at: 0)
        #expect(r == P.Pupil(dx: 1, dy: 0))
        r = look(&g, -2, 1, at: 1)
        #expect(r == P.Pupil(dx: 1, dy: 0))
    }

    @Test func aStillPointerIsForgottenAfterAWhile() {
        var g = P.Gaze()
        var r = g.follow(dx: 200, dy: 0, pointer: (10, 10), now: 0)
        #expect(r == P.Pupil(dx: 1, dy: 0))
        r = g.follow(dx: 200, dy: 0, pointer: (10, 10), now: P.Gaze.boredAfter - 0.5)
        #expect(r == P.Pupil(dx: 1, dy: 0))
        r = g.follow(dx: 200, dy: 0, pointer: (10, 10), now: P.Gaze.boredAfter + 0.5)
        #expect(r == .ahead)
        // It moves again: interesting again.
        r = g.follow(dx: 200, dy: 0, pointer: (11, 10), now: P.Gaze.boredAfter + 1)
        #expect(r == P.Pupil(dx: 1, dy: 0))
    }

    @Test func restingStartsFresh() {
        var g = P.Gaze()
        _ = look(&g, 200, 0, at: 0)
        g.rest()
        #expect(g.pupil == .ahead)
    }

    // MARK: - Blink

    @Test func blinksBrieflyThenWaitsForTheNextGap() {
        var b = P.Blink(firstAt: 4)
        var r = b.closed(at: 3.9, gap: { 5 })
        #expect(!r)
        r = b.closed(at: 4.0, gap: { 5 })
        #expect(r)
        // One poll later (0.12 s) it is still shut; two polls later it is open.
        r = b.closed(at: 4.12, gap: { 5 })
        #expect(r)
        r = b.closed(at: 4.24, gap: { 5 })
        #expect(!r)
        #expect(b.nextAt == 9)
        r = b.closed(at: 8.9, gap: { 5 })
        #expect(!r)
        r = b.closed(at: 9.0, gap: { 5 })
        #expect(r)
    }

    // MARK: - Celebration

    private typealias S = P.Celebrations.Sample

    @Test func aLongTurnFinishingCelebratesOnce() {
        var c = P.Celebrations()
        var r = c.observe([S(id: "a", state: .thinking)], now: 0)
        #expect(!r)
        r = c.observe([S(id: "a", state: .tool)], now: 60)
        #expect(!r)
        r = c.observe([S(id: "a", state: .done)], now: 120)
        #expect(r)
        // Staying done is not another finish.
        r = c.observe([S(id: "a", state: .done)], now: 121)
        #expect(!r)
    }

    @Test func aQuickReplyDoesNotCelebrate() {
        var c = P.Celebrations()
        _ = c.observe([S(id: "a", state: .thinking)], now: 0)
        var r = c.observe([S(id: "a", state: .done)], now: 8)
        #expect(!r)
    }

    /// The fifty-turn conversation: every turn long enough, one sparkle per
    /// cooldown rather than one per turn.
    @Test func aConversationOfLongTurnsIsThrottledPerSession() {
        var c = P.Celebrations()
        var fired = 0
        var t: TimeInterval = 0
        for _ in 0..<50 {
            _ = c.observe([S(id: "a", state: .thinking)], now: t)
            t += P.Celebrations.minWork + 10
            if c.observe([S(id: "a", state: .done)], now: t) { fired += 1 }
            t += 5
        }
        let span = t
        let ceiling = Int(span / P.Celebrations.perSession) + 1
        #expect(fired >= 1)
        #expect(fired <= ceiling)
        #expect(fired < 10)
    }

    @Test func waitsOnTheUserStayInsideTheTurn() {
        var c = P.Celebrations()
        _ = c.observe([S(id: "a", state: .tool)], now: 0)
        _ = c.observe([S(id: "a", state: .permission)], now: 20)
        _ = c.observe([S(id: "a", state: .tool)], now: 100)
        var r = c.observe([S(id: "a", state: .done)], now: 105)
        #expect(r)
    }

    @Test func aGuessedFinishOrAFirstSightingIsNotAFinish() {
        var c = P.Celebrations()
        _ = c.observe([S(id: "a", state: .thinking)], now: 0)
        var r = c.observe([S(id: "a", state: .done, decayed: true)], now: 200)
        #expect(!r)
        // Already done the first time it is seen.
        r = c.observe([S(id: "b", state: .done)], now: 300)
        #expect(!r)
        // An error ends the turn without a sparkle, and the next turn starts over.
        _ = c.observe([S(id: "c", state: .thinking)], now: 300)
        _ = c.observe([S(id: "c", state: .error)], now: 500)
        _ = c.observe([S(id: "c", state: .thinking)], now: 510)
        r = c.observe([S(id: "c", state: .done)], now: 520)
        #expect(!r)
    }

    @Test func twoSessionsFinishingTogetherMakeOneSparkle() {
        var c = P.Celebrations()
        _ = c.observe([S(id: "a", state: .thinking), S(id: "b", state: .thinking)], now: 0)
        var r = c.observe([S(id: "a", state: .done), S(id: "b", state: .tool)], now: 200)
        #expect(r)
        r = c.observe([S(id: "a", state: .done), S(id: "b", state: .done)], now: 205)
        #expect(!r)
    }

    @Test func aGoneSessionTakesItsCooldownWithIt() {
        var c = P.Celebrations()
        _ = c.observe([S(id: "a", state: .thinking)], now: 0)
        var r = c.observe([S(id: "a", state: .done)], now: 100)
        #expect(r)
        _ = c.observe([], now: 110)
        _ = c.observe([S(id: "a", state: .thinking)], now: 120)
        r = c.observe([S(id: "a", state: .done)], now: 240)
        #expect(r)
    }

    // MARK: - Pokes

    @Test func onePokeSquishesAndAFlurryGetsDizzy() {
        var p = P.Pokes()
        var r = p.poke(at: 0)
        #expect(r == .squish)
        r = p.poke(at: 0.3)
        #expect(r == .squish)
        r = p.poke(at: 0.6)
        #expect(r == .dizzy)
        // While dizzy, more pokes are swallowed.
        r = p.poke(at: 0.9)
        #expect(r == nil)
        #expect(p.current(at: 0.9)?.reaction == .dizzy)
        // Over: a fresh poke is a squish again, not the tail of the last flurry.
        r = p.poke(at: 2.0)
        #expect(r == .squish)
    }

    @Test func slowPokesNeverGetDizzy() {
        var p = P.Pokes()
        for i in 0..<6 {
            let r = p.poke(at: Double(i) * 1.5)
            #expect(r == .squish)
        }
    }

    @Test func aReactionCanBeResumedPartWay() {
        var p = P.Pokes()
        _ = p.poke(at: 10)
        let now = p.current(at: 10.1)
        #expect(now?.reaction == .squish)
        #expect(abs((now?.elapsed ?? 0) - 0.1) < 1e-9)
        #expect(p.current(at: 10 + P.Pokes.Reaction.squish.length + 0.01) == nil)
    }

    // MARK: - Eyes

    /// Two dots inside a block, drawn as a grid: what Clawd looks like to the search.
    @Test func findsTwoIslands() {
        let art = [
            "..........",
            ".########.",
            ".#oo##oo#.",
            ".#oo##oo#.",
            ".########.",
            "..........",
        ].map { Array($0) }
        let boxes = MascotEyes.islands(width: 10, height: 6) { x, y in art[y][x] == "o" }
        #expect(boxes == [MascotEyes.PixelBox(minX: 2, minY: 2, maxX: 3, maxY: 3), MascotEyes.PixelBox(minX: 6, minY: 2, maxX: 7, maxY: 3)])
        #expect(MascotEyes.looksLikeEyes(boxes, width: 10, height: 6))
    }

    @Test func refusesArtThatIsNotAPairOfEyes() {
        let one = [MascotEyes.PixelBox(minX: 2, minY: 2, maxX: 3, maxY: 3)]
        #expect(!MascotEyes.looksLikeEyes(one, width: 10, height: 6))
        // Touching the edge: an outline, not an eye.
        let edge = one + [MascotEyes.PixelBox(minX: 0, minY: 2, maxX: 1, maxY: 3)]
        #expect(!MascotEyes.looksLikeEyes(edge, width: 10, height: 6))
        // Too big to be an eye.
        let huge = one + [MascotEyes.PixelBox(minX: 3, minY: 1, maxX: 8, maxY: 4)]
        #expect(!MascotEyes.looksLikeEyes(huge, width: 10, height: 6))
    }

    /// The real sprite: if Clawd is ever regenerated and the search stops finding
    /// his eyes, the gaze switches itself off — this is what says so out loud.
    @Test func findsClawdsEyes() throws {
        let sprite = IconRenderer.shared.sprite(for: Agent.byID("claude"))
        let eyes = try #require(MascotEyes.find(in: sprite.restingColor))
        #expect(eyes.ink.count == 2)
        let (left, right) = (eyes.ink[0], eyes.ink[1])
        #expect(left.maxX < right.minX)
        // Upper half of the mark, and room for a one-point step every way.
        let size = sprite.restingColor.size
        for e in eyes.ink {
            #expect(e.midY > size.height / 2)
            #expect(e.minX - 1 > 0 && e.maxX + 1 < size.width && e.maxY + 1 < size.height)
        }
    }
}
