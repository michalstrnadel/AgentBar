import Foundation

/// Keep Mac Awake's preferences, owned here because the island's cup, the shared
/// menu and the Settings page all read them. The defaults store is passed in so a
/// test can use a suite of its own instead of the person's settings.
enum KeepAwakePrefs {
    /// The battery pause's choices, as the popup lists them: 100 is "always"
    /// (`KeepAwakePolicy.anyBattery`), the rest are "below N %".
    static let floorChoices = [KeepAwakePolicy.anyBattery, 50, 30, 20, 10]
    /// "Lock the screen when you leave": after this many minutes.
    static let lockChoices = [2, 5, 10, 15, 30]

    private enum Key {
        static let lastChoice = "keepAwakeLastChoice"
        static let untilMinutes = "keepAwakeUntilTime"
        static let display = "keepAwakeDisplay"
        static let batteryGuard = "keepAwakeBatteryGuard"
        static let batteryFloor = "keepAwakeBatteryFloor"
        static let nudge = "keepAwakeNudge"
        static let lid = "keepAwakeLid"
        static let mode = "keepAwakeMode"
        static let since = "keepAwakeSince"
        static let keyboard = "keepAwakeKeyboardDark"
        static let lowPower = "keepAwakePauseLowPower"
        static let lock = "keepAwakeLockWhenAway"
        static let lockMinutes = "keepAwakeLockMinutes"
        static let sleepWhenDone = "keepAwakeSleepWhenDone"
        static let shortcut = "keepAwakeShortcut"
        static let triggerAgents = "keepAwakeTriggerAgents"
        static let triggerCharger = "keepAwakeTriggerCharger"
        static let triggerDisplay = "keepAwakeTriggerDisplay"
        static let triggerApps = "keepAwakeTriggerApps"
    }

    /// What one click on the cup starts. "While agents work" until something else
    /// is picked: it is the one only AgentBar can offer.
    static func lastChoice(_ d: UserDefaults = .standard) -> KeepAwakeChoice {
        d.string(forKey: Key.lastChoice).flatMap(KeepAwakeChoice.init(rawValue:)) ?? .whileAgentsWork
    }
    static func setLastChoice(_ c: KeepAwakeChoice, _ d: UserDefaults = .standard) {
        d.set(c.rawValue, forKey: Key.lastChoice)
    }

    /// "Until 18:00", as minutes past midnight.
    static func untilMinutes(_ d: UserDefaults = .standard) -> Int {
        (d.object(forKey: Key.untilMinutes) as? Int).map { min(max($0, 0), 1439) } ?? 18 * 60
    }
    static func setUntilMinutes(_ m: Int, _ d: UserDefaults = .standard) {
        d.set(min(max(m, 0), 1439), forKey: Key.untilMinutes)
    }

    static func settings(_ d: UserDefaults = .standard) -> KeepAwakeSettings {
        KeepAwakeSettings(
            keepDisplayOn: d.bool(forKey: Key.display),
            // On unless switched off: running a laptop flat is the one way this
            // feature could cost someone their work.
            batteryGuard: d.object(forKey: Key.batteryGuard) as? Bool ?? true,
            batteryFloor: floorChoices.contains(d.integer(forKey: Key.batteryFloor))
                ? d.integer(forKey: Key.batteryFloor) : 20,
            nudge: d.bool(forKey: Key.nudge),
            pauseInLowPower: d.object(forKey: Key.lowPower) as? Bool ?? true,
            // Off until switched on. It was on by default in 1.51–1.54, and a person
            // who had asked for the screen to stay on watched it go dark ten
            // minutes later, with no way to tell the agents were still working:
            // a screen that locks itself is something to choose, not to discover.
            lockWhenAway: d.object(forKey: Key.lock) as? Bool ?? false,
            lockAfter: TimeInterval(lockMinutes(d) * 60),
            sleepWhenDone: d.bool(forKey: Key.sleepWhenDone))
    }

    static func lockMinutes(_ d: UserDefaults = .standard) -> Int {
        lockChoices.contains(d.integer(forKey: Key.lockMinutes)) ? d.integer(forKey: Key.lockMinutes) : 10
    }
    static func setLockMinutes(_ m: Int, _ d: UserDefaults = .standard) {
        d.set(lockChoices.contains(m) ? m : 10, forKey: Key.lockMinutes)
    }
    static func setLockWhenAway(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: Key.lock) }
    static func setPauseInLowPower(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: Key.lowPower) }
    static func setSleepWhenDone(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: Key.sleepWhenDone) }

    /// The global shortcut for the cup. Off until switched on: a chord claimed
    /// system-wide by an app you did not ask to claim it is a chord stolen.
    static func shortcut(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: Key.shortcut) }
    static func setShortcut(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: Key.shortcut) }

    /// "Start by itself". All off until the person switches one on.
    static func triggers(_ d: UserDefaults = .standard) -> KeepAwakeTriggerSettings {
        KeepAwakeTriggerSettings(agents: d.bool(forKey: Key.triggerAgents),
                                 charger: d.bool(forKey: Key.triggerCharger),
                                 display: d.bool(forKey: Key.triggerDisplay),
                                 apps: d.stringArray(forKey: Key.triggerApps) ?? [])
    }
    static func setTriggers(_ t: KeepAwakeTriggerSettings, _ d: UserDefaults = .standard) {
        d.set(t.agents, forKey: Key.triggerAgents)
        d.set(t.charger, forKey: Key.triggerCharger)
        d.set(t.display, forKey: Key.triggerDisplay)
        var seen = Set<String>()
        d.set(t.apps.filter { seen.insert($0).inserted }, forKey: Key.triggerApps)
    }

    static func setKeepDisplayOn(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: Key.display) }
    static func setBatteryGuard(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: Key.batteryGuard) }
    static func setBatteryFloor(_ p: Int, _ d: UserDefaults = .standard) {
        d.set(floorChoices.contains(p) ? p : 20, forKey: Key.batteryFloor)
    }
    static func setNudge(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: Key.nudge) }

    /// Also awake with the lid closed. Off unless switched on; it asks for an
    /// administrator password each time it starts (`LidSleep`).
    static func lid(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: Key.lid) }
    static func setLid(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: Key.lid) }

    /// The keyboard's light goes off while you are away (`KeyboardLight`). On unless
    /// switched off: a Mac held up all night should not sit there with its keys lit.
    static func keyboardDark(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: Key.keyboard) as? Bool ?? true
    }
    static func setKeyboardDark(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: Key.keyboard) }

    /// The live mode, kept so a relaunch — an automatic update, say — does not
    /// quietly drop "for 2 hours" halfway through. nil is off.
    static func mode(_ d: UserDefaults = .standard) -> KeepAwakeMode? {
        d.data(forKey: Key.mode).flatMap { try? JSONDecoder().decode(KeepAwakeMode.self, from: $0) }
    }
    static func setMode(_ m: KeepAwakeMode?, _ d: UserDefaults = .standard) {
        if let m, let data = try? JSONEncoder().encode(m) {
            d.set(data, forKey: Key.mode)
        } else {
            d.removeObject(forKey: Key.mode)
            d.removeObject(forKey: Key.since)
        }
    }

    /// When the live mode was clicked on, kept with it so the countdown's bar and
    /// "On for 1:02:03" survive a relaunch too.
    static func since(_ d: UserDefaults = .standard) -> Date? {
        d.object(forKey: Key.since) as? Date
    }
    static func setSince(_ date: Date?, _ d: UserDefaults = .standard) {
        if let date { d.set(date, forKey: Key.since) } else { d.removeObject(forKey: Key.since) }
    }
}
