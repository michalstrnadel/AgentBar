import Cocoa

// AgentBar — menu bar status for AI coding agents.
// Copyright (c) 2026 Michal Strnadel. MIT licensed.

/// App wiring. Owns the two stores and the mascot so every surface reads one poll
/// and one animation timer, then fans each change out to whichever surfaces the
/// chosen presentation has on screen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let requestStore = RequestStore()
    private let mascot = MascotDriver()
    private let history = HistoryStore()

    private lazy var controller = StatusItemController(store: store, requestStore: requestStore,
                                                       mascot: mascot)
    private lazy var island = IslandController(mascot: mascot)
    private let antigravityWatcher = AntigravityWatcher()
    private let coworkWatcher = CoworkWatcher()

    private var sessions: [Session] = []
    private var islandRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, before any surface exists: an update staged before the last quit
        // installs now, while a relaunch is invisible. True means we are leaving.
        if UpdateChecker.shared.resumeAtLaunch() { return }
        // Which release notes are unread, worked out before anything is drawn so
        // the menu and Settings agree from the first frame. Announces nothing.
        ReleaseNotes.noteLaunch(current: AppMenuModel.appVersion,
                                existingInstall: ReleaseNotes.looksLikeExistingInstall(),
                                releases: ReleaseNotes.bundled)
        // What a quiet moment is measured against, from the live stores.
        UpdateChecker.shared.pendingRequests = { [weak self] in self?.requestStore.requests.count ?? 1 }
        UpdateChecker.shared.waitingSessions = { [weak self] in
            self?.sessions.filter { $0.state.waitsOnHuman }.count ?? 1
        }
        AgentActions.currentSessions = { [weak self] in self?.sessions ?? [] }

        URLCommands.sessions = { [weak self] in self?.sessions ?? [] }
        store.onChange = { [weak self] sessions in
            guard let self else { return }
            self.sessions = sessions
            // A link that launched the app waited for this: before the first poll
            // there is no session for `agentbar://focus` to find.
            defer { URLCommands.storesReady() }
            self.mascot.update(sessions: sessions, systemColor: IconColor.system)
            SoundCenter.shared.observe(sessions)
            // Takes the git baseline a session's record is later measured against.
            // A session that appears and ends inside one tick gets none, which is
            // correct: there is no span there to measure.
            WorkDiff.shared.observe(sessions)
            self.history.observe(sessions)
            Notifier.shared.observe(sessions)
            self.controller.apply(sessions)
            if self.islandRunning {
                self.island.apply(sessions: sessions, requests: self.requestStore.requests)
            }
        }
        // The launcher reads the same poll every other surface does, rather than
        // going to disk for a session list of its own.
        LauncherPanel.sessions = { [weak self] in self?.sessions ?? [] }
        TodayStripView.onChange = { [weak self] in
            guard let self, self.islandRunning else { return }
            self.island.settingsChanged()
        }
        IconColor.onChange = { [weak self] system in
            guard let self else { return }
            self.mascot.update(sessions: self.sessions, systemColor: system)
        }
        // Before a pending request reaches any surface: a rule the human wrote may
        // already have an answer for it. The store publishes what is left, so a
        // rule-answered request never flashes on screen as a question nobody asked.
        requestStore.answeredElsewhere = { [weak self] request in
            RuleEngine.shared.handle(request,
                                     session: self?.sessions.first { $0.id == request.sessionId })
        }
        requestStore.onChange = { [weak self] in
            guard let self else { return }
            self.controller.requestsChanged()
            Notifier.shared.requestsChanged(self.requestStore.requests, sessions: self.sessions)
            if self.islandRunning {
                self.island.apply(sessions: self.sessions, requests: self.requestStore.requests)
            }
        }

        // Before anything can be posted: the delegate is what receives button taps,
        // and it must be in place from launch even with notifications switched off —
        // a banner can outlive the setting that created it. Asks for nothing.
        Notifier.shared.requests = { [weak self] in self?.requestStore.requests ?? [] }
        Notifier.shared.sessions = { [weak self] in self?.sessions ?? [] }
        Notifier.shared.start()

        controller.start()
        store.start()
        requestStore.start()
        SoundCenter.shared.start()
        UsageCenter.shared.onChange = { [weak self] in
            guard let self, self.islandRunning else { return }
            self.island.usageChanged() // re-render the footer's usage line
        }
        UsageCenter.shared.start()

        // Settings changes fan out from here — the surfaces never reach into
        // each other. (One closure, single-assignment: this is the only owner.)
        SettingsWindow.shared.onChange = { [weak self] in
            guard let self else { return }
            self.controller.settingsChanged()
            if self.islandRunning { self.island.settingsChanged() }
        }

        HookInstaller.onFinish = {
            WelcomeWindow.shared.refreshWired()
            // Only now: running the checks before the installer has finished would
            // report a machine as unwired while the install that wires it is still
            // in flight.
            Diagnostics.runInBackground()
        }
        Diagnostics.onVerdict = { [weak self] in self?.controller.apply(self?.sessions ?? []) }
        HookInstaller.installIfNeeded()
        // Off the main queue: it reads and may rewrite a file that has had a month
        // to grow, and nothing on screen is waiting for it.
        DispatchQueue.global(qos: .utility).async {
            HistoryStore.prune()
            DecisionLedger.prune()
        }
        antigravityWatcher.start()
        coworkWatcher.start()

        Presentation.onChange = { [weak self] in self?.applyPresentation() }
        // Pinning the island to another display moves it now, not next launch.
        IslandScreen.onChange = { [weak self] in self?.applyPresentation() }
        applyPresentation()

        if WelcomeWindow.showOnLaunch { WelcomeWindow.shared.show() }
        // Layout work on Settings otherwise means clicking through the menu bar on
        // every rebuild, which is how a window ships unlooked-at. CONTRIBUTING lists
        // it next to islandExpandDebug.
        if UserDefaults.standard.bool(forKey: "settingsOnLaunchDebug") {
            // `settingsPageDebug` names the page (`SettingsWindow.Page`'s raw value).
            let page = UserDefaults.standard.string(forKey: "settingsPageDebug")
                .flatMap(SettingsWindow.Page.init(rawValue:))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SettingsWindow.shared.show(page: page) }
        }
        // Same reason, for the launcher: it is a panel that closes the instant it
        // loses focus, which is exactly what happens when you go to look at it.
        if UserDefaults.standard.bool(forKey: "launcherOnLaunchDebug") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { LauncherPanel.shared.show() }
        }
    }

    /// `agentbar://` links, from Shortcuts, Raycast, a script — or any web page,
    /// which is why everything a link can do is decided in `URLCommands` and none
    /// of it answers, writes or runs anything. AppKit routes the `kAEGetURL` event
    /// here once `CFBundleURLTypes` declares the scheme (see `Scripts/build.sh`),
    /// including the one that launched the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        URLCommands.handle(urls)
    }

    private func applyPresentation() {
        controller.applyPresentation()
        let wanted = Presentation.current.showsIsland
        guard wanted != islandRunning else { return }
        islandRunning = wanted
        if wanted {
            island.start()
            island.apply(sessions: sessions, requests: requestStore.requests)
        } else {
            island.stop()
        }
    }
}

// Silent verification of the synthesized cues (offline render, writes WAVs and
// asserts audibility/headroom). MUST run before the kill-other-copies loop below,
// or checking the sounds would terminate the user's live AgentBar.
if let i = CommandLine.arguments.firstIndex(of: "--render-sounds"),
   CommandLine.arguments.indices.contains(i + 1) {
    exit(SoundCenter.renderAllForVerification(
        to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) ? 0 : 1)
}

// The same idea for the one drawn surface in the menu: render the usage meters to
// a PNG so they can be looked at without opening a menu and losing it to the
// screenshot. See UsageMeterView.renderForVerification.
if let i = CommandLine.arguments.firstIndex(of: "--render-usage"),
   CommandLine.arguments.indices.contains(i + 1) {
    exit(UsageMeterView.renderForVerification(
        to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) ? 0 : 1)
}

// Session rows as the menu draws them, every state, light and dark. See
// SessionRowView.renderForVerification.
if let i = CommandLine.arguments.firstIndex(of: "--render-break-game"),
   CommandLine.arguments.indices.contains(i + 1) {
    _ = NSApplication.shared
    exit(BreakGameView.renderForVerification(
        to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) ? 0 : 1)
}

if let i = CommandLine.arguments.firstIndex(of: "--render-hunt-game"),
   CommandLine.arguments.indices.contains(i + 1) {
    _ = NSApplication.shared
    exit(HuntGameView.renderForVerification(
        to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) ? 0 : 1)
}

if let i = CommandLine.arguments.firstIndex(of: "--render-menu-rows"),
   CommandLine.arguments.indices.contains(i + 1) {
    _ = NSApplication.shared
    exit(SessionRowView.renderForVerification(
        to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) ? 0 : 1)
}

// The settings sheet as a picture, every section at once. See
// SettingsWindow.renderForVerification.
if let i = CommandLine.arguments.firstIndex(of: "--render-settings"),
   CommandLine.arguments.indices.contains(i + 1) {
    _ = NSApplication.shared
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    // A page name after the path renders that one page at its true size; the
    // six-up sheet is for the overview and too small to read a caption in.
    if CommandLine.arguments.indices.contains(i + 2),
       let page = SettingsWindow.Page(rawValue: CommandLine.arguments[i + 2]) {
        exit(SettingsWindow.shared.renderPageForVerification(page, to: url) ? 0 : 1)
    }
    exit(SettingsWindow.shared.renderForVerification(to: url) ? 0 : 1)
}

// The rule sheet, drawn to a file. Same purpose as --render-settings: the things
// that can be wrong about that window are its layout and its wording.
if let i = CommandLine.arguments.firstIndex(of: "--render-rule-sheet"),
   CommandLine.arguments.indices.contains(i + 1) {
    _ = NSApplication.shared
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    var prefill = RuleSheet.Prefill(
        decision: "allow", shape: "bash:git push",
        cwd: FileManager.default.currentDirectoryPath,
        display: "Bash: git push origin main")
    if CommandLine.arguments.indices.contains(i + 2) { prefill.shape = CommandLine.arguments[i + 2] }
    let trying = CommandLine.arguments.indices.contains(i + 3) ? CommandLine.arguments[i + 3] : ""
    exit(RuleSheet.renderForVerification(to: url, prefill: prefill, trying: trying) ? 0 : 1)
}

// Whether Claude's quota can be read at all, in one line, without the menu and
// without the app running: the same call the timer makes, the same status
// sentence Settings shows. It has to be the *bundle's* binary to mean anything —
// macOS decides Keychain access on the code signature, so
// `/Applications/AgentBar.app/Contents/MacOS/AgentBar --quota-status` answers for
// the installed app and a bare `.build/debug/AgentBar` answers only for itself.
// Prints no token, ever; there is nothing here that could.
if CommandLine.arguments.contains("--quota-status") {
    let was = ClaudeQuota.enabled
    ClaudeQuota.enabled = true
    let done = DispatchSemaphore(value: 0)
    ClaudeQuota.shared.checkNow { }
    // The fetch is asynchronous and this process has nothing else to do; poll the
    // status until it stops saying "asking", or give up out loud.
    DispatchQueue.global().async {
        for _ in 0..<40 {
            if case .asking = ClaudeQuota.shared.status { Thread.sleep(forTimeInterval: 0.5) }
            else { break }
        }
        done.signal()
    }
    done.wait()
    let status = ClaudeQuota.shared.status
    print(ClaudeQuota.sentence(for: status))
    for line in ClaudeQuota.candidates() { print("  " + line) }
    if let snap = ClaudeQuota.shared.latest() {
        for w in snap.windows {
            print("  \(w.name): \(Int(w.usedPercent.rounded()))% used, \(UsageCenter.short(w))")
        }
    }
    ClaudeQuota.enabled = was
    if case .ok = status { exit(0) }
    exit(1)
}

// Two copies running at once — a dev build next to the /Applications install —
// fight over the same island: each draws its own panel in the same spot and
// whichever window is stacked on top wins, so fixes appear and disappear at
// random. The copy the user just launched is the one they mean; every other
// running AgentBar is told to quit. One exception: hooks auto-launch the app by
// bundle ID, which LaunchServices may resolve to an OLDER installed copy — that
// stale launch must bow out instead of stomping the newer running one (and
// downgrading the installed hook scripts with it). A sandbox (`AgentBarHome`)
// stays out of it both ways: it exists to run next to the installed copy.
if let bundleID = Bundle.main.bundleIdentifier, !AgentBarHome.isSandbox {
    let me = ProcessInfo.processInfo.processIdentifier
    let myVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where other.processIdentifier != me {
        let otherVersion = other.bundleURL
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
            ?? "0"
        if otherVersion.compare(myVersion, options: .numeric) == .orderedDescending {
            exit(0) // a newer copy is already running — it wins
        }
        other.terminate()
    }
}

// Before anything below writes a preference, while an empty domain still means a
// copy that has never run here (`MascotPersonality.Prefs`).
if let bundleID = Bundle.main.bundleIdentifier {
    MascotPersonality.Prefs.seedForNewInstall(domain: UserDefaults.standard.persistentDomain(forName: bundleID))
}

let app = NSApplication.shared
// Menu bar only: no dock icon. This is also the ONLY place that may say so —
// `LSUIElement` in Info.plist does the same job, but macOS then refuses
// notification authorization to the bundle outright: no prompt, and no entry in
// System Settings ▸ Notifications to turn on. Setting the policy here, before
// `run()`, keeps the icon away without making the app ineligible.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
