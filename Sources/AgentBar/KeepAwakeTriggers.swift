import Cocoa

/// "Start by itself": conditions the person chose in Settings ▸ Keep Awake that
/// hold the Mac awake without a click. The amendment to rule 2 (CLAUDE.md): a
/// trigger the person set up may start Keep Awake, the way a rule they wrote may
/// answer — every hold names its trigger, no link, agent or rule can create one,
/// and the closed lid still needs a click.
enum KeepAwakeTrigger: Hashable {
    /// "When an agent starts working": "while agents work", armed all the time.
    case agents
    case charger
    case display
    /// An app, by bundle id.
    case app(String)
}

/// What the triggers are set to.
struct KeepAwakeTriggerSettings: Equatable {
    var agents = false
    var charger = false
    var display = false
    /// Bundle ids, in the order they were added.
    var apps: [String] = []

    var any: Bool { agents || charger || display || !apps.isEmpty }
}

/// What the Mac looks like right now, as far as triggers care.
struct KeepAwakeTriggerConditions: Equatable {
    var pluggedIn = false
    var externalDisplay = false
    /// Bundle ids of running apps.
    var runningApps: Set<String> = []
    /// A local session is working (`KeepAwakePolicy.isLocalWork`).
    var agentsWorking = false
}

/// A trigger holding the Mac up, and how to say so.
struct TriggerHold: Equatable {
    var trigger: KeepAwakeTrigger
    var mode: KeepAwakeMode
    /// "Xcode is running", "plugged in".
    var because: String
}

enum KeepAwakeTriggerPolicy {
    /// Whether the trigger's condition is true now. The agents trigger is "true"
    /// while an agent works: that is what a snooze of it waits out.
    static func isMet(_ t: KeepAwakeTrigger, _ c: KeepAwakeTriggerConditions) -> Bool {
        switch t {
        case .agents:      return c.agentsWorking
        case .charger:     return c.pluggedIn
        case .display:     return c.externalDisplay
        case .app(let id): return c.runningApps.contains(id)
        }
    }

    /// The trigger that holds, if any. Conditions that are true now come first,
    /// each as "until it stops being true"; the agents trigger, which is armed
    /// all the time, comes last, as "while agents work".
    static func hold(_ s: KeepAwakeTriggerSettings, _ c: KeepAwakeTriggerConditions,
                     snoozed: Set<KeepAwakeTrigger>, appName: (String) -> String) -> TriggerHold? {
        for id in s.apps where !snoozed.contains(.app(id)) && c.runningApps.contains(id) {
            return TriggerHold(trigger: .app(id), mode: .indefinite, because: "\(appName(id)) is running")
        }
        if s.display, !snoozed.contains(.display), c.externalDisplay {
            return TriggerHold(trigger: .display, mode: .indefinite, because: "a display is connected")
        }
        if s.charger, !snoozed.contains(.charger), c.pluggedIn {
            return TriggerHold(trigger: .charger, mode: .indefinite, because: "plugged in")
        }
        if s.agents, !snoozed.contains(.agents) {
            return TriggerHold(trigger: .agents, mode: .whileAgentsWork, because: "an agent works")
        }
        return nil
    }

    /// A snooze lasts until its condition goes away; then the trigger is armed
    /// again for the next time it comes true.
    static func liftSnoozes(_ snoozed: Set<KeepAwakeTrigger>, _ c: KeepAwakeTriggerConditions) -> Set<KeepAwakeTrigger> {
        snoozed.filter { isMet($0, c) }
    }
}

/// Watches what the triggers need: the charger (through `PowerSource`), displays
/// and running apps. Agents come from `KeepAwake`'s own sessions. Only watches
/// while a trigger that needs it is switched on.
final class KeepAwakeTriggerWatch {
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var power: PowerSource.Watch?
    private var watching = KeepAwakeTriggerSettings()

    func update(_ s: KeepAwakeTriggerSettings) {
        guard s != watching || (observers.isEmpty && power == nil && s.any) else { return }
        watching = s
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers = []
        power = s.charger ? PowerSource.Watch { [weak self] in self?.onChange?() } : nil
        if s.display {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                queue: .main) { [weak self] _ in self?.onChange?() })
        }
        if !s.apps.isEmpty {
            let ws = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.onChange?()
                })
            }
        }
    }

    /// Reads the conditions now. `agentsWorking` is the caller's.
    func conditions(agentsWorking: Bool) -> KeepAwakeTriggerConditions {
        var c = KeepAwakeTriggerConditions(agentsWorking: agentsWorking)
        // A Mac with no battery is always plugged in.
        if watching.charger { c.pluggedIn = PowerSource.reading().map { !$0.onBattery } ?? true }
        if watching.display { c.externalDisplay = Self.externalDisplayConnected() }
        if !watching.apps.isEmpty {
            c.runningApps = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
        return c
    }

    static func externalDisplayConnected() -> Bool {
        NSScreen.screens.contains { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return CGDisplayIsBuiltin(n.uint32Value) == 0
        }
    }

    /// The app's own name for a bundle id, or the id.
    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
