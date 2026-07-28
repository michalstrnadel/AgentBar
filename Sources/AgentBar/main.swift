import Cocoa

// AgentBar — menu bar status for AI coding agents.
// Copyright (c) 2026 Michal Strnadel. MIT licensed.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = StatusItemController()
    private let antigravityWatcher = AntigravityWatcher()
    private let coworkWatcher = CoworkWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        HookInstaller.installIfNeeded()
        antigravityWatcher.start()
        coworkWatcher.start()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only: no dock icon; sole window is Settings
let delegate = AppDelegate()
app.delegate = delegate
app.run()
