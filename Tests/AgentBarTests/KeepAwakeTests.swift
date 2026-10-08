import Foundation
import IOKit.ps
import Testing
@testable import AgentBar

private func session(_ fields: [String: Any]) throws -> Session {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ka-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    var o: [String: Any] = ["agent": "claude", "state": "thinking", "started": true, "ts": 1_000,
                            "project": "AgentBar", "pid": 4242]
    o.merge(fields) { $1 }
    try JSONSerialization.data(withJSONObject: o).write(to: url)
    return try #require(Session(fileURL: url))
}

private let t0 = Date(timeIntervalSince1970: 1_000)

private func inputs(_ mode: KeepAwakeMode?, _ sessions: [Session] = [], now: Date = t0,
                    lastWorkAt: Date? = nil, battery: BatteryReading? = nil,
                    active: Bool = true, settings: KeepAwakeSettings = KeepAwakeSettings())
    -> KeepAwakePolicy.Inputs {
    KeepAwakePolicy.Inputs(mode: mode, sessions: sessions, now: now, lastWorkAt: lastWorkAt,
                           battery: battery, userSessionActive: active, settings: settings)
}

/// Keep Mac Awake: what holds the Mac up, for how long, and what lets it go.
@Suite struct KeepAwakePolicyTests {
    @Test func offHoldsNothing() {
        let d = KeepAwakePolicy.decide(inputs(nil))
        #expect(d.assertion == .none)
        #expect(!d.isOn)
        #expect(KeepAwakePolicy.nextEvaluation(inputs(nil)) == nil)
    }

    @Test func onlyLocalLiveWorkCounts() throws {
        #expect(KeepAwakePolicy.isLocalWork(try session([:]), now: t0))
        #expect(KeepAwakePolicy.isLocalWork(try session(["state": "tool"]), now: t0))
        for fields: [String: Any] in [["state": "done"], ["state": "idle"], ["state": "error"],
                                      ["entrypoint": "cloud"]] {
            #expect(!KeepAwakePolicy.isLocalWork(try session(fields), now: t0), "\(fields)")
        }
        var decayed = try session([:])
        decayed.decayed = true
        #expect(!KeepAwakePolicy.isLocalWork(decayed, now: t0))
    }

    /// A request waiting on you is mid-work, but only for so long.
    @Test func aWaitingRequestCountsUntilItsCap() throws {
        let waiting = try session(["state": "permission", "ts": 1_000])
        #expect(KeepAwakePolicy.isLocalWork(waiting, now: t0.addingTimeInterval(29 * 60)))
        #expect(!KeepAwakePolicy.isLocalWork(waiting, now: t0.addingTimeInterval(31 * 60)))
        let next = KeepAwakePolicy.nextEvaluation(inputs(.whileAgentsWork, [waiting]))
        #expect(next == t0.addingTimeInterval(KeepAwakePolicy.humanWaitCap))
    }

    @Test func whileAgentsWorkHoldsWhileWorkingAndForTheGraceAfter() throws {
        let working = try session([:])
        let d = KeepAwakePolicy.decide(inputs(.whileAgentsWork, [working, try session(["state": "tool"])]))
        #expect(d.assertion == .system)
        #expect(d.working == 2)
        #expect(d.reason == "Awake while 2 agents work")

        let done = try session(["state": "done"])
        let inGrace = KeepAwakePolicy.decide(inputs(.whileAgentsWork, [done], now: t0.addingTimeInterval(120),
                                                    lastWorkAt: t0))
        #expect(inGrace.assertion == .system)
        #expect(inGrace.endsAt == t0.addingTimeInterval(KeepAwakePolicy.grace))
        #expect(inGrace.reason == "Agents done · sleeps in 3 min")

        let after = KeepAwakePolicy.decide(inputs(.whileAgentsWork, [done],
                                                  now: t0.addingTimeInterval(KeepAwakePolicy.grace + 1),
                                                  lastWorkAt: t0))
        #expect(after.assertion == .none)
        #expect(after.reason == "Waiting for an agent to start")
        #expect(!after.expired, "the mode stays armed for the next agent")
    }

    /// Wall clock, not a countdown: a deadline that passed while the Mac slept
    /// ends the mode on the first look after waking.
    @Test func aDeadlineExpiresOnTheWallClock() {
        let end = t0.addingTimeInterval(3600)
        let running = KeepAwakePolicy.decide(inputs(.until(end), now: t0.addingTimeInterval(18 * 60)))
        #expect(running.assertion == .system)
        #expect(running.endsAt == end)
        #expect(running.reason.hasSuffix("· 42 min left"))
        let woke = KeepAwakePolicy.decide(inputs(.until(end), now: t0.addingTimeInterval(5 * 3600)))
        #expect(woke.expired)
        #expect(woke.assertion == .none)
    }

    @Test func indefiniteHoldsUntilTurnedOff() {
        let d = KeepAwakePolicy.decide(inputs(.indefinite))
        #expect(d.assertion == .system)
        #expect(d.endsAt == nil)
        #expect(KeepAwakePolicy.nextEvaluation(inputs(.indefinite)) == nil)
    }

    @Test func theDisplayStaysOnWhenAskedOrWhenTheNudgeRuns() {
        #expect(KeepAwakePolicy.decide(inputs(.indefinite, settings: .init(keepDisplayOn: true))).assertion
                == .systemAndDisplay)
        #expect(KeepAwakePolicy.decide(inputs(.indefinite, settings: .init(nudge: true))).assertion
                == .systemAndDisplay)
    }

    /// Paused, not ended: the mode stays, and a pause never holds the Mac up.
    @Test func batteryPausesOnlyOnBatteryBelowTheFloor() {
        let low = BatteryReading(onBattery: true, percent: 15)
        let paused = KeepAwakePolicy.decide(inputs(.indefinite, battery: low))
        #expect(paused.paused == .battery(15))
        #expect(paused.assertion == .none)
        #expect(paused.reason == "Paused — battery at 15%")
        #expect(KeepAwakePolicy.decide(inputs(.indefinite, battery: .init(onBattery: false, percent: 15)))
                .assertion == .system, "plugged in")
        #expect(KeepAwakePolicy.decide(inputs(.indefinite, battery: .init(onBattery: true, percent: 20)))
                .assertion == .system, "at the floor is not below it")
        #expect(KeepAwakePolicy.decide(inputs(.indefinite, battery: nil)).assertion == .system, "no battery")
        #expect(KeepAwakePolicy.decide(inputs(.indefinite, battery: low, settings: .init(batteryGuard: false)))
                .assertion == .system, "guard off")
    }

    @Test func anotherUserPauses() {
        let d = KeepAwakePolicy.decide(inputs(.indefinite, active: false))
        #expect(d.paused == .otherUser)
        #expect(d.assertion == .none)
    }

    @Test func theNextLookIsTheEarliestBoundary() {
        let end = t0.addingTimeInterval(3600)
        #expect(KeepAwakePolicy.nextEvaluation(inputs(.until(end))) == t0.addingTimeInterval(60),
                "the countdown's next minute comes before the deadline")
        let nearEnd = t0.addingTimeInterval(3590)
        #expect(KeepAwakePolicy.nextEvaluation(inputs(.until(end), now: nearEnd)) == end)
    }

    @Test func words() {
        #expect(KeepAwakePolicy.left(30) == "under a minute left")
        #expect(KeepAwakePolicy.left(42 * 60) == "42 min left")
        #expect(KeepAwakePolicy.left(80 * 60) == "1 h 20 min left")
        #expect(KeepAwakePolicy.left(120 * 60) == "2 h left")
        #expect(KeepAwakePolicy.badge(42 * 60) == "42m")
        #expect(KeepAwakePolicy.badge(80 * 60) == "1h 20m")
        #expect(KeepAwakePolicy.clock(18 * 60) == "18:00")
        #expect(KeepAwakePolicy.clock(9 * 60 + 5) == "09:05")
    }

    /// "Until 18:00" picked at 19:00 is tomorrow evening, not a mode already over.
    @Test func untilATimeIsItsNextOccurrence() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "Europe/Prague"))
        let at = { (h: Int, m: Int) in
            cal.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: h, minute: m))!
        }
        #expect(KeepAwakePolicy.nextOccurrence(of: 18 * 60, after: at(9, 0), calendar: cal) == at(18, 0))
        #expect(KeepAwakePolicy.nextOccurrence(of: 18 * 60, after: at(19, 0), calendar: cal)
                == cal.date(byAdding: .day, value: 1, to: at(18, 0)))
        #expect(KeepAwakePolicy.nextOccurrence(of: 18 * 60, after: at(18, 0), calendar: cal)
                == cal.date(byAdding: .day, value: 1, to: at(18, 0)), "exactly now is already past")
    }

    @Test func choicesBecomeModes() {
        #expect(KeepAwakeChoice.fifteenMinutes.mode(now: t0, untilMinutes: 0) == .until(t0.addingTimeInterval(900)))
        #expect(KeepAwakeChoice.thirtyMinutes.mode(now: t0, untilMinutes: 0) == .until(t0.addingTimeInterval(1800)))
        #expect(KeepAwakeChoice.matching(.until(t0), lastChoice: .fifteenMinutes) == .fifteenMinutes)
        #expect(KeepAwakeChoice.oneHour.mode(now: t0, untilMinutes: 0) == .until(t0.addingTimeInterval(3600)))
        #expect(KeepAwakeChoice.twoHours.mode(now: t0, untilMinutes: 0) == .until(t0.addingTimeInterval(7200)))
        #expect(KeepAwakeChoice.whileAgentsWork.mode(now: t0, untilMinutes: 0) == .whileAgentsWork)
        #expect(KeepAwakeChoice.indefinite.mode(now: t0, untilMinutes: 0) == .indefinite)
        #expect(KeepAwakeChoice.matching(.until(t0), lastChoice: .twoHours) == .twoHours)
        #expect(KeepAwakeChoice.matching(.until(t0), lastChoice: .indefinite) == .untilTime)
        #expect(KeepAwakeChoice.matching(nil, lastChoice: .twoHours) == nil)
    }
}

@Suite struct KeepAwakePrefsTests {
    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "agentbar-keepawake-\(UUID().uuidString)"))
    }

    @Test func defaults() throws {
        let d = try suite()
        #expect(KeepAwakePrefs.lastChoice(d) == .whileAgentsWork)
        #expect(KeepAwakePrefs.untilMinutes(d) == 18 * 60)
        #expect(KeepAwakePrefs.settings(d) == KeepAwakeSettings(keepDisplayOn: false, batteryGuard: true,
                                                                batteryFloor: 20, nudge: false))
        #expect(!KeepAwakePrefs.lid(d))
        #expect(KeepAwakePrefs.mode(d) == nil)
    }

    @Test func roundTrips() throws {
        let d = try suite()
        KeepAwakePrefs.setLastChoice(.twoHours, d)
        KeepAwakePrefs.setUntilMinutes(21 * 60 + 30, d)
        KeepAwakePrefs.setKeepDisplayOn(true, d)
        KeepAwakePrefs.setBatteryGuard(false, d)
        KeepAwakePrefs.setBatteryFloor(30, d)
        KeepAwakePrefs.setNudge(true, d)
        KeepAwakePrefs.setLid(true, d)
        #expect(KeepAwakePrefs.lastChoice(d) == .twoHours)
        #expect(KeepAwakePrefs.untilMinutes(d) == 21 * 60 + 30)
        #expect(KeepAwakePrefs.settings(d) == KeepAwakeSettings(keepDisplayOn: true, batteryGuard: false,
                                                                batteryFloor: 30, nudge: true))
        #expect(KeepAwakePrefs.lid(d))
        for mode: KeepAwakeMode in [.whileAgentsWork, .indefinite, .until(t0)] {
            KeepAwakePrefs.setMode(mode, d)
            #expect(KeepAwakePrefs.mode(d) == mode)
        }
        KeepAwakePrefs.setMode(nil, d)
        #expect(KeepAwakePrefs.mode(d) == nil)
    }

    @Test func outOfRangeValuesFallBack() throws {
        let d = try suite()
        KeepAwakePrefs.setBatteryFloor(37, d)
        #expect(KeepAwakePrefs.settings(d).batteryFloor == 20)
        KeepAwakePrefs.setUntilMinutes(5000, d)
        #expect(KeepAwakePrefs.untilMinutes(d) == 1439)
        d.set("nonsense", forKey: "keepAwakeLastChoice")
        #expect(KeepAwakePrefs.lastChoice(d) == .whileAgentsWork)
    }
}

/// Our own nudge must not convince AgentBar that you never leave.
@Suite struct InputIdleNudgeTests {
    @Test func withoutANudgeTheSystemIsRight() {
        #expect(InputIdle.humanIdle(system: 42, nudge: nil, now: t0) == 42)
    }

    @Test func nothingSinceTheNudgeMeansStillAway() {
        let nudge = (at: t0, idleBefore: TimeInterval(240))
        // 30 s after our nudge, the system clock says 30 s: that was us.
        #expect(InputIdle.humanIdle(system: 30, nudge: nudge, now: t0.addingTimeInterval(30)) == 270)
    }

    @Test func aRealInputAfterTheNudgeWins() {
        let nudge = (at: t0, idleBefore: TimeInterval(240))
        // The person touched the trackpad 5 s ago, 25 s after the nudge.
        #expect(InputIdle.humanIdle(system: 5, nudge: nudge, now: t0.addingTimeInterval(30)) == 5)
    }

    @Test func theNudgeWaitsForFourMinutesAndThePermission() {
        #expect(!PresenceNudge.shouldNudge(systemIdle: 200, trusted: true))
        #expect(PresenceNudge.shouldNudge(systemIdle: 240, trusted: true))
        #expect(!PresenceNudge.shouldNudge(systemIdle: 600, trusted: false))
    }
}

@Suite struct PowerSourceTests {
    @Test func readsPercentAndSource() {
        let onBattery: [String: Any] = [kIOPSCurrentCapacityKey: 18, kIOPSMaxCapacityKey: 100,
                                        kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]
        #expect(PowerSource.reading(from: onBattery) == BatteryReading(onBattery: true, percent: 18))
        let charging: [String: Any] = [kIOPSCurrentCapacityKey: 50, kIOPSMaxCapacityKey: 200,
                                       kIOPSPowerSourceStateKey: kIOPSACPowerValue]
        #expect(PowerSource.reading(from: charging) == BatteryReading(onBattery: false, percent: 25))
        #expect(PowerSource.reading(from: [:]) == nil)
        #expect(PowerSource.reading(from: [kIOPSCurrentCapacityKey: 5, kIOPSMaxCapacityKey: 0]) == nil)
    }
}

/// The closed-lid mode's root command is built here; it is never run in a test.
@Suite struct LidSleepTests {
    @Test func theRootCommandDisablesSleepUnderAWatcher() {
        let script = LidSleep.rootScript(pid: 4242, stopFile: "/Users/me/.agentbar/awake-lid.stop",
                                         deadline: 1_900_000_000)
        #expect(script.hasPrefix("/usr/bin/pmset -a disablesleep 1 && "))
        #expect(script.contains("/bin/kill -0 4242"))
        #expect(script.contains("1900000000"))
        #expect(script.contains("/usr/bin/pmset -a disablesleep 0"))
        #expect(script.contains("/Users/me/.agentbar/awake-lid.stop"))
    }

    /// A path with a quote in it cannot break out of its quoting.
    @Test func pathsAreQuotedForTheShell() {
        #expect(LidSleep.shellQuote("/Users/o'neil/x") == #"'/Users/o'\''neil/x'"#)
        #expect(LidSleep.shellQuote("/a b") == "'/a b'")
        #expect(LidSleep.appleScriptLiteral(#"say "hi" \ there"#) == #""say \"hi\" \\ there""#)
    }

    @Test func aLeftoverIsOnlyAMarkerWithSleepStillOffFromSomebodyElse() {
        #expect(LidSleep.isLeftover(markerExists: true, sleepDisabled: true, ownSession: false))
        #expect(!LidSleep.isLeftover(markerExists: true, sleepDisabled: true, ownSession: true))
        #expect(!LidSleep.isLeftover(markerExists: true, sleepDisabled: false, ownSession: false))
        #expect(!LidSleep.isLeftover(markerExists: false, sleepDisabled: true, ownSession: false),
                "somebody else's disablesleep is not ours to undo")
    }
}
