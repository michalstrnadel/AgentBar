import Cocoa

/// Keep Mac Awake: gathers what `KeepAwakePolicy` needs, asks it, and applies the
/// answer — the power assertion, the battery watch, the presence nudge, the
/// keyboard's light and, when asked for, the closed-lid mode.
///
/// Changed only by a click (the island's cup, the shared menu, Settings). No link,
/// rule or schedule turns it on, and nothing about it appears on screen by itself.
final class KeepAwake {
    static let shared = KeepAwake()

    /// Fires when anything a surface shows may have changed.
    var onChange: (() -> Void)?

    private(set) var mode: KeepAwakeMode?
    private(set) var decision = KeepAwakeDecision()
    private var sessions: [Session] = []
    private var lastWorkAt: Date?
    private var wasWorking = false
    /// When the current mode was started by a click.
    private var startedAt: Date?
    /// "While agents work" started before any agent is working: how long the
    /// closed-lid half waits for one to start before it lets the Mac sleep again.
    static let lidWaitForWork: TimeInterval = 10 * 60
    private var userSessionActive = true
    private let assertion = KeepAwakeAssertionHolder()
    private let nudge = PresenceNudge()
    private var battery: PowerSource.Watch?
    private var timer: Timer?
    private var started = false
    /// Closed-lid mode was asked for with the current mode. Cleared when it ends for
    /// any reason; only another click starts it again — the password dialog must
    /// never appear because, say, the charger was plugged back in.
    private var lidRequested = false
    /// True only while handling the click that started a mode: the one moment a
    /// password dialog is something the person just asked for.
    private var inClick = false

    /// Restores a mode that was on when the app last quit, and starts listening
    /// for wake and user switches. Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        KeyboardLight.shared.restoreLeftover()
        if let saved = KeepAwakePrefs.mode() {
            if case .until(let end) = saved, end <= Date() {
                KeepAwakePrefs.setMode(nil)
            } else {
                mode = saved
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reevaluate()
        }
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            self?.userSessionActive = false
            self?.reevaluate()
        }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            self?.userSessionActive = true
            self?.reevaluate()
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.reevaluate()
        }
        reevaluate()
    }

    /// The real sessions, before any demo is merged in: a made-up request must
    /// never hold a real Mac awake.
    func observe(_ sessions: [Session]) {
        self.sessions = sessions
        reevaluate()
    }

    // MARK: - What a click does

    var isOn: Bool { mode != nil }

    /// The cup: off → the last choice, on → off.
    func toggle() {
        if isOn { stop() } else { start(KeepAwakePrefs.lastChoice()) }
    }

    func start(_ choice: KeepAwakeChoice) {
        KeepAwakePrefs.setLastChoice(choice)
        let now = Date()
        setMode(choice.mode(now: now, untilMinutes: KeepAwakePrefs.untilMinutes()))
        startedAt = now
        lastWorkAt = nil
        wasWorking = false
        lidRequested = KeepAwakePrefs.lid()
        inClick = true
        reevaluate()
        inClick = false
    }

    /// A menu pick of the mode already on turns it off — the menu's toggle.
    func pick(_ choice: KeepAwakeChoice) {
        if currentChoice == choice { stop() } else { start(choice) }
    }

    func stop() {
        setMode(nil)
        lidRequested = false
        reevaluate()
    }

    var currentChoice: KeepAwakeChoice? {
        KeepAwakeChoice.matching(mode, lastChoice: KeepAwakePrefs.lastChoice())
    }

    /// "Keep Screen On", from a menu or Settings.
    func setKeepDisplayOn(_ on: Bool) {
        KeepAwakePrefs.setKeepDisplayOn(on)
        reevaluate()
    }

    /// "Stay Awake With Lid Closed", from a menu or Settings. Switched on, it is a click
    /// asking for it now: if Keep Awake is off it starts with the last choice, and
    /// the password dialog comes up inside this click. Switched off, sleep with the
    /// lid closed comes back at once.
    func setLid(_ on: Bool) {
        KeepAwakePrefs.setLid(on)
        guard on else {
            lidRequested = false
            reevaluate()
            return
        }
        if !isOn {
            start(KeepAwakePrefs.lastChoice())
        } else {
            lidRequested = true
            inClick = true
            reevaluate()
            inClick = false
        }
    }

    /// Settings changed something the decision reads (display, battery, nudge,
    /// the keyboard's light).
    func settingsChanged() {
        if !KeepAwakePrefs.lid() { lidRequested = false }
        reevaluate()
    }

    // MARK: - Surface helpers

    /// A short summary for open-menu refreshes: changes whenever a row would.
    var signature: String {
        let minutes = decision.endsAt.map { Int($0.timeIntervalSinceNow / 60) } ?? -1
        return "\(currentChoice?.rawValue ?? "off")|\(decision.reason)|\(minutes)|\(LidSleep.shared.isOn)"
    }

    /// The menu badge: what is left, or where it is.
    var badge: String? {
        guard isOn else { return nil }
        if decision.paused != nil { return "paused" }
        if let end = decision.endsAt { return KeepAwakePolicy.badge(end.timeIntervalSinceNow) }
        switch mode {
        case .indefinite:      return "∞"
        case .whileAgentsWork: return decision.working > 0 ? "\(decision.working)" : "armed"
        default:               return nil
        }
    }

    // MARK: - Applying the answer

    private func setMode(_ m: KeepAwakeMode?) {
        mode = m
        KeepAwakePrefs.setMode(m)
    }

    private func inputs(_ now: Date) -> KeepAwakePolicy.Inputs {
        KeepAwakePolicy.Inputs(mode: mode, sessions: sessions, now: now, lastWorkAt: lastWorkAt,
                               battery: battery != nil ? PowerSource.reading() : nil,
                               userSessionActive: userSessionActive,
                               settings: KeepAwakePrefs.settings())
    }

    func reevaluate() {
        let now = Date()
        // The grace runs from the moment work was last seen, which is the moment
        // it stopped: a session that worked for an hour without a state change is
        // still "working" until the poll that says otherwise.
        let workingNow = sessions.contains { KeepAwakePolicy.isLocalWork($0, now: now) }
        if workingNow || wasWorking { lastWorkAt = now }
        wasWorking = workingNow

        // The battery is watched only while a mode is on.
        if mode != nil, battery == nil {
            battery = PowerSource.Watch { [weak self] in self?.reevaluate() }
        } else if mode == nil {
            battery = nil
        }

        var d = KeepAwakePolicy.decide(inputs(now))
        if d.expired {
            setMode(nil)
            lidRequested = false
            d = KeepAwakePolicy.decide(inputs(now))
        }
        assertion.apply(d.assertion, reason: d.reason)
        nudge.setRunning(d.isOn && KeepAwakePrefs.settings().nudge)
        KeyboardLight.shared.setActive(d.isOn && KeepAwakePrefs.keyboardDark())
        applyLid(d, now: now)

        timer?.invalidate()
        timer = nil
        var next = KeepAwakePolicy.nextEvaluation(inputs(now))
        if let wait = lidWaitEnd(now), LidSleep.shared.isOn || LidSleep.shared.isStarting {
            next = min(next ?? wait, wait)
        }
        if let next {
            let t = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
                self?.reevaluate()
            }
            t.tolerance = 2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        let changed = d != decision
        decision = d
        if changed { onChange?() }
    }

    /// While "while agents work" waits for its first agent after a click, the end
    /// of that wait; nil once work has been seen or the wait is over.
    private func lidWaitEnd(_ now: Date) -> Date? {
        guard case .whileAgentsWork = mode, lastWorkAt == nil, let startedAt else { return nil }
        let end = startedAt.addingTimeInterval(Self.lidWaitForWork)
        return end > now ? end : nil
    }

    /// Closed-lid mode starts only inside a click — the one moment a password
    /// dialog is something the person just asked for. Once it ends — agents done,
    /// battery low, too hot, turned off — it stays ended until the next click.
    ///
    /// It holds while the mode holds the Mac up, with one addition: "while agents
    /// work" clicked before any agent has started waits ten minutes for one, so
    /// the usual order — start it, start the agent, close the lid — works.
    private func applyLid(_ d: KeepAwakeDecision, now: Date) {
        let lid = LidSleep.shared
        let tooHot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let holding = d.isOn || (d.paused == nil && lidWaitEnd(now) != nil)
        let wanted = lidRequested && holding && !tooHot
        if wanted, inClick, !lid.isOn, !lid.isStarting {
            let deadline: Date = {
                if case .until(let end) = mode { return end }
                return now.addingTimeInterval(LidSleep.maxDuration)
            }()
            lid.start(until: deadline) { [weak self] ok in
                // Cancelled or refused: the switch goes back off, so it never
                // shows a lid mode that is not running.
                if !ok {
                    self?.lidRequested = false
                    KeepAwakePrefs.setLid(false)
                }
                self?.onChange?()
            }
            return
        }
        if !wanted || (!lid.isOn && !lid.isStarting) {
            lidRequested = false
            if lid.isOn {
                lid.stop()
                onChange?()
            }
        }
    }
}
