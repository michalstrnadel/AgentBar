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
                    active: Bool = true, settings: KeepAwakeSettings = KeepAwakeSettings(),
                    lowPower: Bool = false, locked: Bool = false, trigger: TriggerHold? = nil)
    -> KeepAwakePolicy.Inputs {
    KeepAwakePolicy.Inputs(mode: mode, sessions: sessions, now: now, lastWorkAt: lastWorkAt,
                           battery: battery, userSessionActive: active, settings: settings,
                           lowPower: lowPower, screenLocked: locked, trigger: trigger)
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
        #expect(KeepAwakePrefs.settings(d).pauseInLowPower)
        #expect(KeepAwakePrefs.settings(d).lockWhenAway, "a Mac kept lit is locked when you leave")
        #expect(KeepAwakePrefs.settings(d).lockAfter == 600)
        #expect(!KeepAwakePrefs.settings(d).sleepWhenDone)
        #expect(!KeepAwakePrefs.shortcut(d), "no chord is claimed until asked for")
        #expect(KeepAwakePrefs.triggers(d) == KeepAwakeTriggerSettings(), "no trigger until switched on")
        #expect(!KeepAwakePrefs.lid(d))
        #expect(KeepAwakePrefs.mode(d) == nil)
        #expect(KeepAwakePrefs.keyboardDark(d), "the keys go dark unless that is switched off")
        KeepAwakePrefs.setKeyboardDark(false, d)
        #expect(!KeepAwakePrefs.keyboardDark(d))
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

@Suite struct KeyboardLightPolicyTests {
    @Test func darkOnlyWhileKeptAwakeAndAway() {
        #expect(!KeyboardLightPolicy.shouldBeDark(active: false, humanIdle: 3600, dark: false))
        #expect(!KeyboardLightPolicy.shouldBeDark(active: false, humanIdle: 3600, dark: true),
                "Keep Awake ending gives the light back")
        #expect(!KeyboardLightPolicy.shouldBeDark(active: true, humanIdle: 29, dark: false))
        #expect(KeyboardLightPolicy.shouldBeDark(active: true, humanIdle: 30, dark: false))
    }

    @Test func theFirstKeystrokeBringsItBack() {
        #expect(KeyboardLightPolicy.shouldBeDark(active: true, humanIdle: 5, dark: true),
                "once dark it stays dark until the person is back, not merely under the threshold")
        #expect(!KeyboardLightPolicy.shouldBeDark(active: true, humanIdle: 0.3, dark: true))
    }

    @Test func ourOwnNudgeDoesNotCountAsComingBack() {
        // Four minutes away, then the nudge resets the system clock to zero.
        let idle = InputIdle.humanIdle(system: 0.2, nudge: (Date(), 240), now: Date())
        #expect(KeyboardLightPolicy.shouldBeDark(active: true, humanIdle: idle, dark: true))
    }
}

@Suite struct KeepAwakeBeyondTests {
    private let xcode = TriggerHold(trigger: .app("com.apple.dt.Xcode"), mode: .indefinite, because: "Xcode is running")

    @Test func onlyWhilePluggedInPausesOnAnyBattery() {
        let always = KeepAwakeSettings(batteryFloor: KeepAwakePolicy.anyBattery)
        let d = KeepAwakePolicy.decide(inputs(.indefinite, battery: .init(onBattery: true, percent: 98),
                                              settings: always))
        #expect(d.paused == .battery(98))
        #expect(d.reason == "Paused — on battery")
        #expect(KeepAwakePolicy.decide(inputs(.indefinite, battery: .init(onBattery: false, percent: 98),
                                              settings: always)).assertion == .system)
        #expect(KeepAwakePolicy.decide(inputs(.indefinite, battery: nil, settings: always)).assertion == .system,
                "a desktop is always plugged in")
    }

    @Test func lowPowerModePausesOnlyWhenAskedTo() {
        let d = KeepAwakePolicy.decide(inputs(.indefinite, lowPower: true))
        #expect(d.paused == .lowPower)
        #expect(d.reason == "Paused — Low Power Mode")
        #expect(KeepAwakePolicy.decide(inputs(.indefinite, settings: .init(pauseInLowPower: false), lowPower: true))
                .assertion == .system)
    }

    @Test func aLockedScreenMaySleepWhileTheMacWorks() {
        let lit = KeepAwakeSettings(keepDisplayOn: true)
        #expect(KeepAwakePolicy.decide(inputs(.indefinite, settings: lit)).assertion == .systemAndDisplay)
        let locked = KeepAwakePolicy.decide(inputs(.indefinite, settings: lit, locked: true))
        #expect(locked.assertion == .system)
        #expect(locked.reason == "Awake until you turn it off · locked")
    }

    @Test func locksOnceWhenYouLeaveAndOnlyWhileTheScreenIsHeld() {
        let lit = KeepAwakeSettings(keepDisplayOn: true)
        let held = KeepAwakePolicy.decide(inputs(.indefinite, settings: lit))
        #expect(!KeepAwakePolicy.shouldLock(held, settings: lit, humanIdle: 599, locked: false))
        #expect(KeepAwakePolicy.shouldLock(held, settings: lit, humanIdle: 600, locked: false))
        #expect(!KeepAwakePolicy.shouldLock(held, settings: lit, humanIdle: 3600, locked: true), "already locked")
        var off = lit
        off.lockWhenAway = false
        #expect(!KeepAwakePolicy.shouldLock(held, settings: off, humanIdle: 3600, locked: false))
        let dark = KeepAwakeSettings()
        let systemOnly = KeepAwakePolicy.decide(inputs(.indefinite, settings: dark))
        #expect(!KeepAwakePolicy.shouldLock(systemOnly, settings: dark, humanIdle: 3600, locked: false),
                "the screen is macOS's to lock when AgentBar is not holding it on")
        // Four minutes of absence, then our own nudge: the human clock still says away.
        let idle = InputIdle.humanIdle(system: 1, nudge: (Date(), 600), now: Date())
        #expect(KeepAwakePolicy.shouldLock(held, settings: lit, humanIdle: idle, locked: false))
    }

    @Test func sleepsOnlyWhenTheAgentsAreDoneAndNobodyIsHere() {
        let on = KeepAwakeSettings(sleepWhenDone: true)
        let done = t0.addingTimeInterval(-KeepAwakePolicy.grace)
        func sleep(_ mode: KeepAwakeMode?, _ s: KeepAwakeSettings = on, working: Int = 0, last: Date? = done,
                   idle: TimeInterval = 600) -> Bool {
            KeepAwakePolicy.shouldSleepNow(mode: mode, settings: s, working: working, lastWorkAt: last,
                                           humanIdle: idle, now: t0)
        }
        #expect(sleep(.whileAgentsWork))
        #expect(!sleep(.whileAgentsWork, KeepAwakeSettings()), "off unless switched on")
        #expect(!sleep(.whileAgentsWork, working: 1), "an agent still works")
        #expect(!sleep(.whileAgentsWork, last: nil), "no work was ever seen")
        #expect(!sleep(.whileAgentsWork, last: t0.addingTimeInterval(-60)), "still in the grace")
        #expect(!sleep(.whileAgentsWork, idle: 30), "someone is using the Mac")
        #expect(!sleep(.indefinite) && !sleep(.until(t0.addingTimeInterval(60))), "only while agents work")
    }

    @Test func aTriggerHoldsWithoutAClickAndSaysWhich() {
        let d = KeepAwakePolicy.decide(inputs(nil, trigger: xcode))
        #expect(d.assertion == .system)
        #expect(d.trigger == xcode)
        #expect(d.reason == "Awake while Xcode is running")
        // A click beats a trigger: the mode speaks, and no trigger is named.
        let clicked = KeepAwakePolicy.decide(inputs(.until(t0.addingTimeInterval(600)), trigger: xcode))
        #expect(clicked.trigger == nil)
        #expect(clicked.reason.hasPrefix("Awake until"))
        // Pauses still apply to a trigger.
        #expect(KeepAwakePolicy.decide(inputs(nil, lowPower: true, trigger: xcode)).paused == .lowPower)
    }

    @Test func theAgentsTriggerIsOffUntilAnAgentWorks() throws {
        let agents = TriggerHold(trigger: .agents, mode: .whileAgentsWork, because: "an agent works")
        let idle = KeepAwakePolicy.decide(inputs(nil, trigger: agents))
        #expect(idle == KeepAwakeDecision(), "armed is not on: no cup, no row, no assertion")
        let working = KeepAwakePolicy.decide(inputs(nil, [try session([:])], trigger: agents))
        #expect(working.assertion == .system)
        #expect(working.reason == "Awake while 1 agent works · started by itself")
        let grace = KeepAwakePolicy.decide(inputs(nil, lastWorkAt: t0.addingTimeInterval(-60), trigger: agents))
        #expect(grace.isOn, "the grace after the last turn holds too")
    }
}

@Suite struct KeepAwakeTriggerPolicyTests {
    private func name(_ id: String) -> String { id == "com.apple.dt.Xcode" ? "Xcode" : id }

    @Test func eachConditionHoldsAndReleases() {
        let s = KeepAwakeTriggerSettings(charger: true, display: true, apps: ["com.apple.dt.Xcode"])
        var c = KeepAwakeTriggerConditions()
        #expect(KeepAwakeTriggerPolicy.hold(s, c, snoozed: [], appName: name) == nil)
        c.pluggedIn = true
        #expect(KeepAwakeTriggerPolicy.hold(s, c, snoozed: [], appName: name)?.trigger == .charger)
        c.externalDisplay = true
        #expect(KeepAwakeTriggerPolicy.hold(s, c, snoozed: [], appName: name)?.trigger == .display)
        c.runningApps = ["com.apple.dt.Xcode", "com.other"]
        let app = KeepAwakeTriggerPolicy.hold(s, c, snoozed: [], appName: name)
        #expect(app?.trigger == .app("com.apple.dt.Xcode"))
        #expect(app?.because == "Xcode is running")
        #expect(app?.mode == .indefinite)
    }

    @Test func switchedOffTriggersNeverHold() {
        let c = KeepAwakeTriggerConditions(pluggedIn: true, externalDisplay: true, runningApps: ["x"],
                                           agentsWorking: true)
        #expect(KeepAwakeTriggerPolicy.hold(KeepAwakeTriggerSettings(), c, snoozed: [], appName: name) == nil)
    }

    @Test func theAgentsTriggerIsArmedAllTheTimeAndComesLast() {
        let s = KeepAwakeTriggerSettings(agents: true, charger: true)
        #expect(KeepAwakeTriggerPolicy.hold(s, .init(), snoozed: [], appName: name)?.mode == .whileAgentsWork)
        #expect(KeepAwakeTriggerPolicy.hold(s, .init(pluggedIn: true), snoozed: [], appName: name)?.trigger
                == .charger, "a condition that is true now speaks first")
    }

    @Test func aSnoozeLastsUntilItsConditionGoesAway() {
        let s = KeepAwakeTriggerSettings(charger: true)
        let plugged = KeepAwakeTriggerConditions(pluggedIn: true)
        #expect(KeepAwakeTriggerPolicy.hold(s, plugged, snoozed: [.charger], appName: name) == nil)
        #expect(KeepAwakeTriggerPolicy.liftSnoozes([.charger], plugged) == [.charger], "still plugged in")
        #expect(KeepAwakeTriggerPolicy.liftSnoozes([.charger], .init()).isEmpty, "unplugged: armed again")
        #expect(KeepAwakeTriggerPolicy.liftSnoozes([.agents], .init(agentsWorking: true)) == [.agents])
    }

    @Test func triggersRoundTripWithoutDuplicates() throws {
        let d = try #require(UserDefaults(suiteName: "agentbar-triggers-\(UUID().uuidString)"))
        KeepAwakePrefs.setTriggers(.init(agents: true, display: true, apps: ["a", "b", "a"]), d)
        #expect(KeepAwakePrefs.triggers(d) == .init(agents: true, display: true, apps: ["a", "b"]))
    }
}

@Suite struct AwakeLogTests {
    private func file() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("awake-\(UUID().uuidString).jsonl")
    }

    @Test func aStretchIsWrittenAtStartAndEndAndTheLastLineWins() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = AwakeLog(url: url)
        log.holding(.agents, now: t0)
        log.holding(.agents, now: t0.addingTimeInterval(60))  // same kind, same stretch
        log.holding(nil, now: t0.addingTimeInterval(3600))
        let all = AwakeLog.read(url: url)
        #expect(all.count == 1)
        #expect(all.first?.start == t0)
        #expect(all.first?.end == t0.addingTimeInterval(3600))
        #expect(all.first?.kind == .agents)
    }

    @Test func aTornLineCostsOnlyItself() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let ok = #"{"end":2000,"id":"a","kind":"timed","start":1000}"#
        try (ok + "\n" + #"{"end":30"# + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(AwakeLog.read(url: url).map(\.id) == ["a"])
    }

    @Test func stretchesAreClippedToTheRange() {
        let s = [AwakeLog.Stretch(id: "a", start: t0, end: t0.addingTimeInterval(7200), kind: .agents),
                 AwakeLog.Stretch(id: "b", start: t0.addingTimeInterval(7200), end: t0.addingTimeInterval(9000),
                                  kind: .timed)]
        let range = DateInterval(start: t0.addingTimeInterval(3600), end: t0.addingTimeInterval(8000))
        let total = AwakeLog.total(s, in: range)
        #expect(total.all == 3600 + 800)
        #expect(total.agents == 3600)
    }

    @Test func pruneDropsAMonthOldStretch() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = t0.addingTimeInterval(40 * 86_400)
        let log = AwakeLog(url: url)
        log.holding(.timed, now: t0)
        log.holding(nil, now: t0.addingTimeInterval(60))
        log.holding(.agents, now: now.addingTimeInterval(-60))
        log.holding(nil, now: now)
        AwakeLog.prune(url: url, now: now)
        #expect(AwakeLog.read(url: url).map(\.kind) == [.agents])
    }
}
