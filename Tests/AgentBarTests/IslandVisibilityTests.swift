import Foundation
import Testing
@testable import AgentBar

/// Whether the pill is on screen. Pure: every input is passed in, so none of these
/// touch defaults, the window server or the pointer.
struct IslandVisibilityTests {
    /// The island as it ships: both switches off, one session running, nobody
    /// pointing at it, the user at the keyboard.
    private func inputs(_ change: (inout IslandVisibility.Inputs) -> Void = { _ in })
        -> IslandVisibility.Inputs {
        var i = IslandVisibility.Inputs(presentation: .both, hasSessions: true, hasRequests: false,
                                        open: false, flashing: false, peeking: false,
                                        hideWhenEmpty: false, hideWhenAway: false,
                                        idleSeconds: 0)
        change(&i)
        return i
    }

    @Test func showsByDefaultWithOrWithoutWork() {
        #expect(IslandVisibility.shows(inputs()))
        #expect(IslandVisibility.shows(inputs { $0.hasSessions = false }))
        // Idle for an hour changes nothing while the away switch is off.
        #expect(IslandVisibility.shows(inputs { $0.idleSeconds = 3600 }))
    }

    @Test func neverShowsWhereTheIslandIsOff() {
        #expect(!IslandVisibility.shows(inputs { $0.presentation = .menuBar; $0.hasRequests = true }))
    }

    @Test func hidesWhenEmptyInEveryIslandMode() {
        for mode in [Presentation.both, .island] {
            #expect(!IslandVisibility.shows(inputs {
                $0.presentation = mode; $0.hasSessions = false; $0.hideWhenEmpty = true
            }))
            #expect(IslandVisibility.shows(inputs { $0.presentation = mode; $0.hideWhenEmpty = true }))
        }
    }

    @Test func aPeekSummonsAHiddenPill() {
        #expect(IslandVisibility.shows(inputs {
            $0.hasSessions = false; $0.hideWhenEmpty = true; $0.peeking = true
        }))
        #expect(IslandVisibility.shows(inputs {
            $0.hideWhenAway = true; $0.idleSeconds = 600; $0.peeking = true
        }))
    }

    @Test func awayHidesEvenWithWorkRunningOnlyPastTheThreshold() {
        let threshold = IslandVisibility.awayAfter
        #expect(IslandVisibility.shows(inputs { $0.hideWhenAway = true; $0.idleSeconds = threshold - 1 }))
        #expect(!IslandVisibility.shows(inputs { $0.hideWhenAway = true; $0.idleSeconds = threshold }))
    }

    /// The one thing the pill exists to say outranks both switches.
    @Test func aPendingRequestKeepsThePillUp() {
        #expect(IslandVisibility.shows(inputs {
            $0.hasRequests = true; $0.hideWhenAway = true; $0.idleSeconds = 3600
        }))
        #expect(IslandVisibility.shows(inputs {
            $0.hasRequests = true; $0.hasSessions = false; $0.hideWhenEmpty = true
        }))
    }

    @Test func anOpenPanelOrAFlashIsNeverPulledAway() {
        let hiddenOtherwise: (inout IslandVisibility.Inputs) -> Void = {
            $0.hasSessions = false; $0.hideWhenEmpty = true; $0.hideWhenAway = true
            $0.idleSeconds = 3600
        }
        #expect(!IslandVisibility.shows(inputs(hiddenOtherwise)))
        #expect(IslandVisibility.shows(inputs { hiddenOtherwise(&$0); $0.open = true }))
        #expect(IslandVisibility.shows(inputs { hiddenOtherwise(&$0); $0.flashing = true }))
    }

    @Test func awayNeedsTheSwitch() {
        #expect(!IslandVisibility.away(hideWhenAway: false, idleSeconds: 3600))
        #expect(IslandVisibility.away(hideWhenAway: true, idleSeconds: 3600))
        #expect(!IslandVisibility.away(hideWhenAway: true, idleSeconds: 10))
        #expect(IslandVisibility.away(hideWhenAway: true, idleSeconds: 10, awayAfter: 5))
    }

    // MARK: - Migration

    /// Ticked in island-only mode back when it did nothing there: cleared once, so
    /// the only surface does not vanish on an update. Ticked again, it sticks.
    @Test func anIslandOnlyTickFromWhenItDidNothingIsClearedOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "agentbar-island-\(UUID().uuidString)"))
        defaults.set(true, forKey: "hideIslandWhenEmpty")
        IslandVisibility.Prefs.migrate(presentation: .island, defaults)
        #expect(!defaults.bool(forKey: "hideIslandWhenEmpty"))

        defaults.set(true, forKey: "hideIslandWhenEmpty")
        IslandVisibility.Prefs.migrate(presentation: .island, defaults)
        #expect(defaults.bool(forKey: "hideIslandWhenEmpty"))
    }

    /// In `.both` it always worked, so it is kept — and the question is settled,
    /// so a later move to island-only does not clear it either.
    @Test func aTickThatAlreadyWorkedIsKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "agentbar-island-\(UUID().uuidString)"))
        defaults.set(true, forKey: "hideIslandWhenEmpty")
        IslandVisibility.Prefs.migrate(presentation: .both, defaults)
        IslandVisibility.Prefs.migrate(presentation: .island, defaults)
        #expect(defaults.bool(forKey: "hideIslandWhenEmpty"))
    }

    /// Menu bar only: no island, nothing decided yet.
    @Test func menuBarOnlyLeavesTheQuestionOpen() throws {
        let defaults = try #require(UserDefaults(suiteName: "agentbar-island-\(UUID().uuidString)"))
        defaults.set(true, forKey: "hideIslandWhenEmpty")
        IslandVisibility.Prefs.migrate(presentation: .menuBar, defaults)
        #expect(defaults.bool(forKey: "hideIslandWhenEmpty"))
        IslandVisibility.Prefs.migrate(presentation: .island, defaults)
        #expect(!defaults.bool(forKey: "hideIslandWhenEmpty"))
    }
}
