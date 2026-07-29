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

// Two copies running at once — a dev build next to the /Applications install —
// fight over the same island: each draws its own panel in the same spot and
// whichever window is stacked on top wins, so fixes appear and disappear at
// random. The copy the user just launched is the one they mean; every other
// running AgentBar is told to quit.
if let bundleID = Bundle.main.bundleIdentifier {
    let me = ProcessInfo.processInfo.processIdentifier
    for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where other.processIdentifier != me {
        other.terminate()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only: no dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
