import Cocoa

/// Keep Mac Awake: gathers what `KeepAwakePolicy` needs, asks it, and applies the
/// answer — the power assertion, the battery watch, the presence nudge, the
/// keyboard's light, the screen lock, sleep when the agents are done and, when
/// asked for, the closed-lid mode.
///
/// Turned on by a click (the island's cup, the shared menu, Settings), the
/// shortcut, or a trigger the person set up in Settings ("Start by itself"). No
/// link, rule or agent turns it on, and nothing about it appears on screen by
/// itself.
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
    /// Polls the human idle clock while a lock or a sleep is waiting on it.
    private var idleTimer: Timer?
    private var started = false
    private let triggerWatch = KeepAwakeTriggerWatch()
    /// Triggers turned off by a click while they held; each waits for its
    /// condition to go away before it can hold again.
    private var snoozed = Set<KeepAwakeTrigger>()
    private var hold: TriggerHold?
    /// The human idle time when AgentBar last locked the screen: no second lock
    /// until the person has been back.
    private var lockedAtIdle: TimeInterval?
    /// A sleep was asked for; nothing more until the Mac wakes.
    private var sleeping = false
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
                startedAt = KeepAwakePrefs.since()
            }
        }
        AwakeLog.prune()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false
            self?.reevaluate()
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.reevaluate()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { _ in
            AwakeLog.shared.holding(nil)
        }
        ScreenLock.shared.onChange = { [weak self] in self?.reevaluate() }
        triggerWatch.onChange = { [weak self] in self?.reevaluate() }
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

    /// On by a click, or held by a trigger right now.
    var isOn: Bool { mode != nil || decision.trigger != nil }

    /// The cup: off → the last choice, on → off.
    func toggle() {
        if isOn { stop() } else { start(KeepAwakePrefs.lastChoice()) }
    }

    func start(_ choice: KeepAwakeChoice) {
        KeepAwakePrefs.setLastChoice(choice)
        let now = Date()
        setMode(choice.mode(now: now, untilMinutes: KeepAwakePrefs.untilMinutes()))
        startedAt = now
        KeepAwakePrefs.setSince(now)
        lastWorkAt = nil
        wasWorking = false
        lidRequested = KeepAwakePrefs.lid()
        inClick = true
        reevaluate()
        inClick = false
    }

    /// What "Add 15 Minutes" adds.
    static let extendStep: TimeInterval = 15 * 60

    /// "Add 15 Minutes": a running countdown gets longer instead of starting over,
    /// so the bar keeps its beginning and simply has more left. Only a deadline
    /// can be extended. A closed-lid session keeps the end its root watcher was
    /// started with — moving that would take the password again.
    func extend(by seconds: TimeInterval = KeepAwake.extendStep) {
        guard case .until(let end) = mode else { return }
        setMode(.until(max(end, Date()).addingTimeInterval(seconds)))
        reevaluate()
    }

    /// The deadline closed-lid mode was started with, when it runs.
    var lidEndsAt: Date? { LidSleep.shared.isOn ? LidSleep.shared.deadline : nil }

    /// The status line every Keep Mac Awake menu opens with and the cup counts.
    var statusLine: KeepAwakeStatusLine {
        guard isOn else { return .off }
        return KeepAwakeStatusLine.make(mode: mode, decision: decision, since: startedAt,
                                        lastWorkAt: lastWorkAt)
    }

    /// A menu pick of the mode already on turns it off — the menu's toggle.
    func pick(_ choice: KeepAwakeChoice) {
        if currentChoice == choice { stop() } else { start(choice) }
    }

    /// Off. A trigger holding the Mac up is snoozed until its condition goes away,
    /// so off means off.
    func stop() {
        if let t = decision.trigger?.trigger { snoozed.insert(t) }
        setMode(nil)
        lidRequested = false
        reevaluate()
    }

    /// The global shortcut: the cup's click, with a sound to say which way it
    /// went, since nothing was clicked to look at.
    func toggleFromShortcut() {
        toggle()
        NSSound(named: isOn ? "Purr" : "Pop")?.play()
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
            + "|\(KeepAwakePrefs.settings().sleepWhenDone)"
    }

    /// The menu badge: what is left, or where it is.
    var badge: String? {
        guard isOn else { return nil }
        if decision.paused != nil { return "paused" }
        if decision.trigger != nil, decision.endsAt == nil { return "auto" }
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
                               settings: KeepAwakePrefs.settings(),
                               lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                               screenLocked: ScreenLock.shared.isLocked,
                               trigger: hold)
    }

    func reevaluate() {
        let now = Date()
        // The grace runs from the moment work was last seen, which is the moment
        // it stopped: a session that worked for an hour without a state change is
        // still "working" until the poll that says otherwise.
        let workingNow = sessions.contains { KeepAwakePolicy.isLocalWork($0, now: now) }
        if workingNow || wasWorking { lastWorkAt = now }
        wasWorking = workingNow

        // Triggers: what holds, and which snoozes have run out.
        let triggers = KeepAwakePrefs.triggers()
        triggerWatch.update(triggers)
        let conditions = triggerWatch.conditions(agentsWorking: workingNow)
        let lifted = snoozed.subtracting(KeepAwakeTriggerPolicy.liftSnoozes(snoozed, conditions))
        snoozed.subtract(lifted)
        // The agents trigger snoozed during work comes back armed for the next
        // agent, not holding the grace of the work that was turned off.
        if lifted.contains(.agents), mode == nil { lastWorkAt = nil }
        hold = triggers.any
            ? KeepAwakeTriggerPolicy.hold(triggers, conditions, snoozed: snoozed,
                                          appName: KeepAwakeTriggerWatch.appName)
            : nil

        // The battery is watched only while something could hold the Mac up.
        if mode != nil || hold != nil, battery == nil {
            battery = PowerSource.Watch { [weak self] in self?.reevaluate() }
        } else if mode == nil, hold == nil {
            battery = nil
        }

        var d = KeepAwakePolicy.decide(inputs(now))
        if d.expired {
            setMode(nil)
            lidRequested = false
            d = KeepAwakePolicy.decide(inputs(now))
        }
        let settings = KeepAwakePrefs.settings()
        let locked = ScreenLock.shared.isLocked
        assertion.apply(d.assertion, reason: d.reason)
        AwakeLog.shared.holding(logKind(d))
        // A locked Mac shows Away whatever moves the pointer.
        nudge.setRunning(d.isOn && settings.nudge && !locked)
        KeyboardLight.shared.setActive(d.isOn && KeepAwakePrefs.keyboardDark())
        applyLid(d, now: now)
        applyLockAndSleep(d, settings: settings, locked: locked, now: now)

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

    private func logKind(_ d: KeepAwakeDecision) -> AwakeLog.Stretch.Kind? {
        guard d.isOn else { return nil }
        if d.trigger != nil { return .trigger }
        switch mode {
        case .whileAgentsWork: return .agents
        case .until:           return .timed
        case .indefinite:      return .indefinite
        case nil:              return nil
        }
    }

    /// Locks the screen once you have been gone long enough, and puts the Mac to
    /// sleep once the agents are done and you are gone. Both read the human idle
    /// clock, which nothing announces, so a light poll runs while either waits.
    private func applyLockAndSleep(_ d: KeepAwakeDecision, settings: KeepAwakeSettings, locked: Bool, now: Date) {
        let idle = InputIdle.seconds()
        if let at = lockedAtIdle, idle < at { lockedAtIdle = nil }  // back since the lock
        if lockedAtIdle == nil, ScreenLock.shared.canLock,
           KeepAwakePolicy.shouldLock(d, settings: settings, humanIdle: idle, locked: locked) {
            lockedAtIdle = idle
            ScreenLock.shared.lock()
        }

        let effective = mode ?? hold?.mode
        if !sleeping, KeepAwakePolicy.shouldSleepNow(mode: effective, settings: settings, working: d.working,
                                                     lastWorkAt: lastWorkAt, humanIdle: idle, now: now) {
            sleepNow()
            return
        }

        let lockWaits = d.assertion == .systemAndDisplay && settings.lockWhenAway && !locked
            && ScreenLock.shared.canLock
        var sleepWaits = false
        if settings.sleepWhenDone, case .whileAgentsWork = effective, lastWorkAt != nil, d.working == 0 {
            sleepWaits = !sleeping
        }
        if lockWaits || sleepWaits {
            if idleTimer == nil {
                let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.reevaluate() }
                t.tolerance = 5
                RunLoop.main.add(t, forMode: .common)
                idleTimer = t
            }
        } else {
            idleTimer?.invalidate()
            idleTimer = nil
        }
    }

    /// The agents are done and nobody is here: end the mode and sleep. A closed-lid
    /// session is let go first — sleep is disabled while it holds — and the Mac
    /// sleeps once its watcher has turned sleep back on.
    private func sleepNow() {
        sleeping = true
        if mode != nil {
            setMode(nil)
        } else {
            lastWorkAt = nil  // a trigger stays armed for the next agent
        }
        lidRequested = false
        let lid = LidSleep.shared
        let delay: TimeInterval = lid.isOn ? 7 : 0.5
        if lid.isOn { lid.stop() }
        reevaluate()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.sleeping else { return }
            SystemSleep.now()
        }
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
        // Only a mode a click started: a trigger never holds the lid open.
        let holding = mode != nil && (d.isOn || (d.paused == nil && lidWaitEnd(now) != nil))
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
