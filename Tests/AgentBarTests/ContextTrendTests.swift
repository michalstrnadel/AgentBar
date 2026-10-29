import Foundation
import Testing
@testable import AgentBar

/// "Compacts soon": a forecast only from turns AgentBar watched, never from
/// fewer than two increases, reset by any drop, silent under 70%.
struct ContextTrendTests {
    /// Plays turns through `step`: first seen resting at the first value, then
    /// each further value is where one more turn ended.
    private func track(_ turnEnds: [Int]) -> ContextTrend.Track {
        var t = ContextTrend.step(nil, percent: turnEnds[0], resting: true)
        for p in turnEnds.dropFirst() {
            t = ContextTrend.step(t, percent: p, resting: false)  // working
            t = ContextTrend.step(t, percent: p, resting: true)   // turn ends
        }
        return t
    }

    @Test func noForecastFromFewerThanTwoIncreases() {
        #expect(ContextTrend.forecast(ends: [80], current: 80) == nil)
        #expect(ContextTrend.forecast(ends: [72, 82], current: 82) == nil)
        // Two turns, but only one of them grew.
        #expect(ContextTrend.forecast(ends: [72, 82, 82], current: 82) == nil)
        #expect(ContextTrend.forecast(ends: [74, 78, 82], current: 82) == ContextTrend.Forecast(turns: 2))
    }

    @Test func silentUnderSeventy() {
        // A fast climb, but the figure is still one the row does not show.
        #expect(ContextTrend.forecast(ends: [40, 52, 64, 69], current: 69) == nil)
        #expect(ContextTrend.forecast(ends: [46, 58, 70], current: 70) == ContextTrend.Forecast(turns: 2))
    }

    @Test func theHorizonIsThreeTurns() {
        // 4 points a turn from 78 to 90: exactly 3 turns — said.
        #expect(ContextTrend.forecast(ends: [70, 74, 78], current: 78) == ContextTrend.Forecast(turns: 3))
        // From 77, 13 points at 4 a turn is 4 turns — not yet.
        #expect(ContextTrend.forecast(ends: [69, 73, 77], current: 77) == nil)
        // At or past the assumed point: soon, whatever the pace.
        #expect(ContextTrend.forecast(ends: [86, 88, 91], current: 91) == ContextTrend.Forecast(turns: 0))
        #expect(ContextTrend.Forecast(turns: 0).text == "compacts soon")
        #expect(ContextTrend.Forecast(turns: 1).text == "compacts in about 1 turn")
        #expect(ContextTrend.Forecast(turns: 2).text == "compacts in about 2 turns")
    }

    @Test func turnsAreCountedWhereTheyEnd() {
        // A late measurement while resting belongs to the turn that just ended.
        var t = ContextTrend.step(nil, percent: 74, resting: true)
        t = ContextTrend.step(t, percent: 76, resting: false)
        t = ContextTrend.step(t, percent: 78, resting: false)
        t = ContextTrend.step(t, percent: 78, resting: true)
        t = ContextTrend.step(t, percent: 79, resting: true)
        #expect(t.ends == [74, 79])
        // Ticks inside one turn add no turn.
        #expect(track([74, 78, 82]).ends == [74, 78, 82])
    }

    @Test func aDropResetsTheHistory() {
        var t = track([74, 78, 82])
        #expect(ContextTrend.forecast(ends: t.ends, current: 82) != nil)
        // Compaction: the context shrank, and what came before no longer counts.
        t = ContextTrend.step(t, percent: 30, resting: false)
        #expect(t.ends == [30])
        t = ContextTrend.step(t, percent: 84, resting: true)
        // One increase since the drop is not enough, however steep.
        #expect(ContextTrend.forecast(ends: t.ends, current: 84) == nil)
    }

    @Test func theRowSaysItInAmber() {
        let soon = ContextTrend.Forecast(turns: 2)
        #expect(ContextGauge.level(76) == .notice)
        #expect(ContextGauge.level(76, forecast: soon) == .high)
        #expect(ContextGauge.level(96, forecast: soon) == .critical)
        #expect(ContextGauge.level(60, forecast: soon) == .hidden)
        #expect(ContextGauge.detail(84, forecast: soon) == "ctx 84% · compacts in about 2 turns")
        #expect(ContextGauge.detail(84, forecast: nil) == "ctx 84%")
        #expect(ContextGauge.spoken(84, forecast: soon) == "context 84% full, compacts in about 2 turns")
    }
}
