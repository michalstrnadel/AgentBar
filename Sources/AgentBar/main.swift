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
    private let antigravityWatcher = AntigravityWatcher()
    private let coworkWatcher = CoworkWatcher()

    private var sessions: [Session] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AgentActions.currentSessions = { [weak self] in self?.sessions ?? [] }

        store.onChange = { [weak self] sessions in
            guard let self else { return }
            self.sessions = sessions
            self.mascot.update(sessions: sessions, systemColor: self.controller.systemColor)
            self.controller.apply(sessions)
        }
        requestStore.onChange = { [weak self] in self?.controller.requestsChanged() }

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
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only: no dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
