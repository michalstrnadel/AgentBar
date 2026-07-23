import Cocoa

/// Owns the NSStatusItem: picks the session the bar should surface, drives the mascot
/// animation and the rotating thinking verbs. Menu construction is delegated to MenuBuilder.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = SessionStore()

    private var sessions: [Session] = []
    private var animationTimer: Timer?
    private var wordTimer: Timer?
    private var frameIndex = 0
    private var currentWord = ""

    private static let thinkingWords = [
        "Thinking", "Brewing", "Pondering", "Tinkering", "Cooking",
        "Weaving", "Scheming", "Crunching", "Sketching", "Mulling",
    ]

    /// System mode renders monochrome templates that follow the menu bar; Color mode
    /// uses each agent's brand artwork. Persisted across launches.
    var systemColor: Bool {
        get { UserDefaults.standard.bool(forKey: "systemColor") }
        set { UserDefaults.standard.set(newValue, forKey: "systemColor"); render() }
    }

    func start() {
        statusItem.behavior = []
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        store.onChange = { [weak self] sessions in
            self?.sessions = sessions
            self?.render()
        }
        store.start()
        render()
    }

    // MARK: - Rendering

    private var topSession: Session? { sessions.first }

    private func render() {
        guard let button = statusItem.button else { return }
        let agent = Agent.byID(topSession?.agentID ?? "claude")
        let sprite = IconRenderer.shared.sprite(for: agent)
        let frames = systemColor ? sprite.templateFrames : sprite.colorFrames

        switch topSession?.state {
        case .some(let s) where s.isWorking:
            startAnimation(frames: frames, fps: sprite.fps)
            startWords()
        case .permission:
            stopAnimation()
            stopWords()
            button.image = IconRenderer.withPermissionDot(
                systemColor ? sprite.restingTemplate : sprite.restingColor)
            button.title = ""
        default:
            stopAnimation()
            stopWords()
            button.image = systemColor ? sprite.restingTemplate : sprite.restingColor
            button.title = ""
        }
    }

    private func startAnimation(frames: [NSImage], fps: Double) {
        stopAnimation()
        guard !frames.isEmpty else { return }
        frameIndex = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            self.frameIndex = (self.frameIndex + 1) % frames.count
            button.image = frames[self.frameIndex]
        }
        statusItem.button?.image = frames[0]
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func startWords() {
        guard wordTimer == nil else { return }
        rotateWord()
        wordTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.rotateWord()
        }
    }

    private func rotateWord() {
        currentWord = Self.thinkingWords.filter { $0 != currentWord }.randomElement() ?? "Thinking"
        statusItem.button?.title = " \(currentWord)…"
        statusItem.button?.imagePosition = .imageLeft
    }

    private func stopWords() {
        wordTimer?.invalidate()
        wordTimer = nil
        statusItem.button?.title = ""
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        store.refresh()
        MenuBuilder.populate(menu, sessions: sessions, controller: self)
    }

    // MARK: - Actions (targets for MenuBuilder items)

    @objc func sessionRowClicked(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Session else { return }
        if s.entrypoint == "claude-desktop" {
            openAgent(Agent.byID("claude"))
            return
        }
        Self.focusTerminal(named: s.termProgram)
    }

    @objc func openAgentClicked(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? Agent else { return }
        openAgent(agent)
    }

    @objc func openTerminalClicked(_ sender: NSMenuItem) {
        guard let terminal = sender.representedObject as? TerminalApp else { return }
        TerminalApp.setPreferred(terminal)
        terminal.open()
    }

    @objc func chooseColor(_ sender: NSMenuItem) {
        systemColor = (sender.representedObject as? Bool) ?? false
    }

    private func openAgent(_ agent: Agent) {
        let ws = NSWorkspace.shared
        switch agent.open {
        case .bundle(let id):
            if let url = ws.urlForApplication(withBundleIdentifier: id) {
                ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                TerminalApp.preferred(sessions: sessions).open()
            }
        case .appNamed(let name):
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", name]
            try? p.run()
        case .terminal:
            // CLI-only agents open into the user's terminal (chosen in Open ▸ Terminal,
            // or auto-detected from the most recent session).
            TerminalApp.preferred(sessions: sessions).open()
        }
    }

    /// Bring a terminal app to the front. TERM_PROGRAM values map to app names almost
    /// verbatim; unknown values are tried as-is (Ghostty, WezTerm, kitty, …).
    static func focusTerminal(named termProgram: String) {
        let app: String
        switch termProgram {
        case "Apple_Terminal", "": app = "Terminal"
        case "iTerm.app":          app = "iTerm"
        case "vscode":             app = "Visual Studio Code"
        case "WarpTerminal":       app = "Warp"
        default:                   app = termProgram
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", app]
        try? p.run()
    }
}
