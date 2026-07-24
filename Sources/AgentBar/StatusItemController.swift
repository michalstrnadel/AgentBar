import Cocoa

/// Owns the NSStatusItem: picks the session the bar should surface, drives the mascot
/// animation and the rotating thinking verbs. Menu construction is delegated to MenuBuilder.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = SessionStore()
    private let requestStore = RequestStore()

    private var sessions: [Session] = []
    private var animationTimer: Timer?
    private var wordTimer: Timer?
    private var hopTimer: Timer?
    private var frameIndex = 0
    private var currentWord = ""
    private var previousTopState: Session.State?

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
            self?.refreshOpenMenu()   // keep an open dropdown live as state changes
        }
        store.start()
        requestStore.onChange = { [weak self] in self?.refreshOpenMenu() }
        requestStore.start()
        UpdateChecker.shared.onChange = { [weak self] in self?.refreshOpenMenu() }
        UpdateChecker.shared.startPeriodicChecks()
        SettingsWindow.shared.onChange = { [weak self] in
            self?.applyHotKeyState()
            self?.refreshOpenMenu()   // tooltip on the shortcut row shows the combos
        }
        applyHotKeyState()
        render()
    }

    // MARK: - Global Allow/Deny shortcut (opt-in)

    var approvalShortcutEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "globalApprovalShortcut") }
        set { UserDefaults.standard.set(newValue, forKey: "globalApprovalShortcut"); applyHotKeyState() }
    }

    private var lastHotkey = Date.distantPast

    private func applyHotKeyState() {
        HotKeyCenter.shared.setEnabled(approvalShortcutEnabled,
            allow: KeyCombo.allow, deny: KeyCombo.deny,
            onAllow: { [weak self] in self?.hotkeyAnswer("allow") },
            onDeny:  { [weak self] in self?.hotkeyAnswer("deny") })
    }

    /// Answer the newest pending request. Debounced so a held chord can't double-fire.
    private func hotkeyAnswer(_ behavior: String) {
        let now = Date()
        guard now.timeIntervalSince(lastHotkey) > 1 else { return }
        lastHotkey = now
        guard let r = requestStore.requests.first else { return }  // no-op when nothing pending
        AnswerWriter.write(behavior: behavior, for: r)
    }

    // MARK: - Rendering

    private var topSession: Session? { sessions.first }

    /// One entry per agent with a live session, most urgent first. Sessions are
    /// already sorted by (priority, recency), so the first session seen for an
    /// agent is that agent's most urgent one.
    private var agentRow: [(agent: Agent, state: Session.State)] {
        var seen = Set<String>()
        var row: [(Agent, Session.State)] = []
        for s in sessions where seen.insert(s.agentID).inserted {
            row.append((Agent.byID(s.agentID), s.state))
        }
        return row
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let row = agentRow
        if row.count > 1 { return renderMulti(row, button: button) }
        let agent = Agent.byID(topSession?.agentID ?? "claude")
        let sprite = IconRenderer.shared.sprite(for: agent)
        let frames = systemColor ? sprite.templateFrames : sprite.colorFrames
        let resting = systemColor ? sprite.restingTemplate : sprite.restingColor
        let state = topSession?.state
        defer { previousTopState = state }

        switch state {
        case .some(let s) where s.isWorking:
            stopHop()
            startAnimation(frames: frames, fps: sprite.fps)
            // Rotating verbs are Clawd's voice; other agents' dot clusters carry
            // the "working" signal on their own.
            if agent.id == "claude" { startWords() } else { stopWords() }
        case .permission:
            stopHop(); stopAnimation(); stopWords()
            button.image = IconRenderer.withPermissionDot(resting)
            button.title = ""
        case .question:
            stopHop(); stopAnimation(); stopWords()
            button.image = IconRenderer.withPermissionDot(resting, color: IconRenderer.questionDot)
            button.title = ""
        default:
            stopAnimation()
            stopWords()
            button.title = ""
            // A task just finished → a brief celebratory hop, then settle to calm.
            if state == .some(.done), previousTopState?.isWorking == true {
                playHop(resting: resting)
            } else if hopTimer == nil {
                button.image = resting
            }
        }
    }

    /// Two or more agents live at once: their marks sit side by side, no words.
    /// Exactly one working agent animates — Claude wins (it has a real walk cycle),
    /// otherwise the most urgent working one. Everyone else shows the plain resting
    /// mark; a waiting session still carries its amber/blue dot.
    private func renderMulti(_ row: [(agent: Agent, state: Session.State)],
                             button: NSStatusBarButton) {
        stopHop(); stopWords()
        defer { previousTopState = topSession?.state }
        let workingIDs = row.filter { $0.state.isWorking }.map(\.agent.id)
        let animatorID = workingIDs.contains("claude") ? "claude" : workingIDs.first
        let parts = row.map { (id: $0.agent.id,
                               sprite: IconRenderer.shared.sprite(for: $0.agent),
                               state: $0.state) }
        let sys = systemColor
        let build: (Int) -> NSImage = { idx in
            IconRenderer.compose(parts.map { p in
                let resting = sys ? p.sprite.restingTemplate : p.sprite.restingColor
                switch p.state {
                case .permission:
                    return IconRenderer.withPermissionDot(resting)
                case .question:
                    return IconRenderer.withPermissionDot(resting, color: IconRenderer.questionDot)
                case let s where s.isWorking && p.id == animatorID:
                    let frames = sys ? p.sprite.templateFrames : p.sprite.colorFrames
                    return frames.isEmpty ? resting : frames[idx % frames.count]
                default:
                    return resting
                }
            })
        }
        stopAnimation()
        button.title = ""
        button.image = build(0)
        guard animatorID != nil else { return }
        frameIndex = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            self.frameIndex += 1
            button.image = build(self.frameIndex)
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

    /// One-shot "yay, done" hop: two small bounces over ~0.5s, then rest. Art-free —
    /// just redraws the resting mark at a vertical offset.
    private func playHop(resting: NSImage) {
        stopHop()
        let steps = 12
        var i = 0
        statusItem.button?.image = resting
        hopTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            if i >= steps { self.stopHop(); button.image = resting; return }
            let dy = abs(sin(Double(i) / Double(steps) * .pi * 2)) * 3.0  // two hops
            button.image = Self.offset(resting, dy: CGFloat(dy))
            i += 1
        }
    }

    private func stopHop() {
        hopTimer?.invalidate()
        hopTimer = nil
    }

    /// Copy of a mark drawn shifted up by `dy` points (top clips a hair; fine for a hop).
    private static func offset(_ img: NSImage, dy: CGFloat) -> NSImage {
        let out = NSImage(size: img.size)
        out.lockFocus()
        img.draw(at: NSPoint(x: 0, y: dy), from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        out.isTemplate = img.isTemplate
        return out
    }

    // MARK: - NSMenuDelegate

    private var menuIsOpen = false
    /// Root + any visible submenu (MenuBuilder wires every submenu's delegate here).
    private var openMenuDepth = 0
    /// What the currently displayed menu was built from — refresh skips rebuilds
    /// that would reproduce the exact same rows.
    private var builtSignature = ""

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return } // submenus are built by populate
        store.refresh()
        requestStore.refresh()
        populateRootMenu(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        openMenuDepth += 1
        if menu === statusItem.menu { menuIsOpen = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenuDepth = max(0, openMenuDepth - 1)
        if menu === statusItem.menu {
            menuIsOpen = false
            openMenuDepth = 0 // survive out-of-order submenu close notifications
            UpdateChecker.shared.clearTransient()
        }
    }

    /// Live-refresh the dropdown while it is open (state change, new request, update
    /// check finishing). Existing rows are updated in place — an open NSMenu window
    /// never shrinks, so removing rows would leave a blank band at the bottom — and
    /// a full rebuild happens only for growth (new session / request). Skipped while
    /// the user is on an item or any submenu is showing (a rebuild would orphan it),
    /// and when the content signature is unchanged, so the menu never flickers for a
    /// no-op. The store's 2s poll catches up once the user moves.
    private func refreshOpenMenu() {
        guard menuIsOpen, let menu = statusItem.menu,
              menu.highlightedItem == nil, openMenuDepth <= 1 else { return }
        let content = contentSignature()
        guard content != builtSignature else { return }
        if MenuBuilder.updateInPlace(menu, sessions: sessions, requests: requestStore.requests,
                                     controller: self) {
            builtSignature = content
        } else {
            populateRootMenu(menu) // growth: needs new rows, which an open menu renders fine
        }
    }

    private func populateRootMenu(_ menu: NSMenu) {
        MenuBuilder.populate(menu, sessions: sessions, requests: requestStore.requests,
                             controller: self)
        builtSignature = contentSignature()
    }

    /// Everything the menu renders from, flattened. Must cover the same fields the
    /// row builders read, or a real change would be skipped as a no-op.
    private func contentSignature() -> String {
        let rows = sessions.map {
            "\($0.id)|\($0.state.rawValue)|\($0.label)|\($0.project)|\($0.gitBranch ?? "")|\($0.termProgram)"
        }
        let pending = requestStore.requests.map(\.fileName)
        return (rows + ["req:"] + pending
                + ["upd:\(UpdateChecker.shared.status)",
                   "hk:\(approvalShortcutEnabled):\(KeyCombo.allow.display)\(KeyCombo.deny.display)",
                   "mode:\(systemColor)"]).joined(separator: "\n")
    }

    // MARK: - Actions (targets for MenuBuilder items)

    @objc func sessionRowClicked(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Session else { return }
        // A waiting session must be released to its terminal prompt before we focus
        // it, or the user lands on a spinner with the hook still blocked.
        if s.state == .permission,
           let r = requestStore.requests.first(where: { $0.sessionId == s.id }) {
            AnswerWriter.write(behavior: "defer", for: r)
        }
        if s.entrypoint == "claude-desktop" {
            openAgent(Agent.byID("claude"))
            return
        }
        if s.entrypoint == "antigravity-app" {
            openAgent(Agent.byID("antigravity"))
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

    @objc func openShortcutSettings(_ sender: NSMenuItem) {
        SettingsWindow.shared.show()
    }

    /// Called by the inline Allow/Always/Deny button strip on permission rows.
    func answer(_ a: ApprovalAction) {
        switch a.behavior {
        case "always":
            AnswerWriter.write(behavior: "always", rule: a.request.ruleSuggestion, for: a.request)
        case "defer":
            AnswerWriter.write(behavior: "defer", for: a.request)
            // The prompt is about to reappear where the session lives: bring it forward.
            if a.session.entrypoint == "claude-desktop" {
                openAgent(Agent.byID(a.session.agentID))
            } else {
                Self.focusTerminal(named: a.session.termProgram)
            }
        default:
            AnswerWriter.write(behavior: a.behavior, for: a.request)
        }
    }

    @objc func checkForUpdatesClicked(_ sender: NSMenuItem) {
        UpdateChecker.shared.check(manual: true)
    }

    @objc func installUpdateClicked(_ sender: NSMenuItem) {
        UpdateChecker.shared.installAvailable()
    }

    @objc func keystrokeApproveClicked(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Session,
              let keys = Agent.byID(s.agentID).approveKeys else { return }
        if KeystrokeApprover.trusted {
            KeystrokeApprover.approve(session: s, keys: keys)
        } else {
            KeystrokeApprover.requestAccess()
        }
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
