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

    private lazy var controller = StatusItemController(store: store, requestStore: requestStore,
                                                       mascot: mascot)
    private lazy var island = IslandController(mascot: mascot)
    private let antigravityWatcher = AntigravityWatcher()
    private let coworkWatcher = CoworkWatcher()

    private var sessions: [Session] = []
    private var islandRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AgentActions.currentSessions = { [weak self] in self?.sessions ?? [] }

        store.onChange = { [weak self] sessions in
            guard let self else { return }
            self.sessions = sessions
            self.mascot.update(sessions: sessions, systemColor: IconColor.system)
            SoundCenter.shared.observe(sessions)
            self.controller.apply(sessions)
            if self.islandRunning {
                self.island.apply(sessions: sessions, requests: self.requestStore.requests)
            }
        }
        IconColor.onChange = { [weak self] system in
            guard let self else { return }
            self.mascot.update(sessions: self.sessions, systemColor: system)
        }
        requestStore.onChange = { [weak self] in
            guard let self else { return }
            self.controller.requestsChanged()
            if self.islandRunning {
                self.island.apply(sessions: self.sessions, requests: self.requestStore.requests)
            }
        }

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

        HookInstaller.onFinish = { WelcomeWindow.shared.refreshWired() }
        HookInstaller.installIfNeeded()
        antigravityWatcher.start()
        coworkWatcher.start()

        Presentation.onChange = { [weak self] in self?.applyPresentation() }
        applyPresentation()

        if WelcomeWindow.showOnLaunch { WelcomeWindow.shared.show() }
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

// Two copies running at once — a dev build next to the /Applications install —
// fight over the same island: each draws its own panel in the same spot and
// whichever window is stacked on top wins, so fixes appear and disappear at
// random. The copy the user just launched is the one they mean; every other
// running AgentBar is told to quit. One exception: hooks auto-launch the app by
// bundle ID, which LaunchServices may resolve to an OLDER installed copy — that
// stale launch must bow out instead of stomping the newer running one (and
// downgrading the installed hook scripts with it).
if let bundleID = Bundle.main.bundleIdentifier {
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only: no dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
