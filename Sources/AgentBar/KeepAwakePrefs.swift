import Foundation

/// Keep Mac Awake's preferences, owned here because the island's cup, the shared
/// menu and the Settings page all read them. The defaults store is passed in so a
/// test can use a suite of its own instead of the person's settings.
enum KeepAwakePrefs {
    static let floorChoices = [10, 20, 30, 50]

    private enum Key {
        static let lastChoice = "keepAwakeLastChoice"
        static let untilMinutes = "keepAwakeUntilTime"
        static let display = "keepAwakeDisplay"
        static let batteryGuard = "keepAwakeBatteryGuard"
        static let batteryFloor = "keepAwakeBatteryFloor"
        static let nudge = "keepAwakeNudge"
        static let lid = "keepAwakeLid"
        static let mode = "keepAwakeMode"
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
            nudge: d.bool(forKey: Key.nudge))
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
        }
    }
}
