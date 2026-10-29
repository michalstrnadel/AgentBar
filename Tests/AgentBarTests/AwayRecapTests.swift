import Foundation
import Testing
@testable import AgentBar

/// Said once, on coming back, about the whole span away — and only when
/// something happened in it.
@Suite struct AwayRecapTests {
    @Test func comingBackShowsWhatHappenedSinceTheInputStopped() {
        let w = AwayWatch()
        var asked: TimeInterval?
        let make: (TimeInterval) -> AwayRecap = { since in
            asked = since
            return AwayRecap(since: since, done: 3, waiting: 1)
        }
        #expect(!w.tick(idle: 60, now: 1_000, make: make))
        #expect(!w.tick(idle: 200, now: 1_140, make: make))   // away since 940
        #expect(w.tick(idle: 1, now: 2_000, make: make))
        #expect(asked == 940)
        #expect(w.current?.pill == "away · 1 waiting · 3 done")
    }

    @Test func nothingHappenedSaysNothing() {
        let w = AwayWatch()
        _ = w.tick(idle: 300, now: 1_000) { AwayRecap(since: $0) }
        #expect(!w.tick(idle: 0, now: 1_100) { AwayRecap(since: $0) })
        #expect(w.current == nil)
    }

    @Test func itGoesAfterAMinuteAndAHalfOrOnceSeen() {
        let w = AwayWatch()
        _ = w.tick(idle: 300, now: 1_000) { AwayRecap(since: $0, done: 1) }
        _ = w.tick(idle: 0, now: 1_100) { AwayRecap(since: $0, done: 1) }
        #expect(w.current != nil)
        #expect(w.tick(idle: 3, now: 1_100 + AwayWatch.showFor + 1) { AwayRecap(since: $0) })
        #expect(w.current == nil)
    }

    @Test func theSentenceSaysAllOfIt() {
        let r = AwayRecap(since: 0, done: 2, failed: 1, waiting: 1, longestWait: 300, byRules: 4)
        #expect(r.sentence(until: 1_800)
                == "While you were away (30 min): 2 finished, 1 failed, 1 waiting on you, the longest 5 min, your rules answered 4.")
    }
}
