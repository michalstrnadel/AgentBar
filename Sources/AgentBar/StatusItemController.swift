import Cocoa

/// Owns the NSStatusItem and its dropdown. The mascot itself comes from the shared
/// `MascotDriver` (the island renders the same frames from the same timer) and row
/// actions live in `AgentActions`, so this file is the menu bar surface and nothing
/// else. Menu construction is delegated to MenuBuilder.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: SessionStore
    private let requestStore: RequestStore
    private let mascot: MascotDriver

    private var sessions: [Session] = []

    /// Stores and mascot are owned by the app so both surfaces share one poll and
    /// one animation timer.
    init(store: SessionStore, requestStore: RequestStore, mascot: MascotDriver) {
        self.store = store
        self.requestStore = requestStore
        self.mascot = mascot
        super.init()
    }

    /// System mode renders monochrome templates that follow the menu bar; Color mode
    /// uses each agent's brand artwork. Shared with the island's menu and the
    /// Appearance window through `IconColor`, whose onChange repaints every surface.
    var systemColor: Bool {
        get { IconColor.system }
        set { IconColor.system = newValue }
    }

    func start() {
        statusItem.behavior = []
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        UpdateChecker.shared.onChange = { [weak self] in self?.refreshOpenMenu() }
        UpdateChecker.shared.startPeriodicChecks()
        SettingsWindow.shared.onChange = { [weak self] in
            self?.applyHotKeyState()
            self?.refreshOpenMenu()   // tooltip on the shortcut row shows the combos
        }
        applyHotKeyState()
        mascot.sink("statusItem") { [weak self] image, word in
            guard let button = self?.statusItem.button else { return }
            button.image = image
            button.title = word.isEmpty ? "" : " \(word)…"
            if !word.isEmpty { button.imagePosition = .imageLeft }
        }
        applyPresentation()
    }

    /// A new session snapshot. Drawing the mark is the mascot's job; this only has
    /// to keep an open dropdown live as state changes.
    func apply(_ sessions: [Session]) {
        self.sessions = sessions
        refreshOpenMenu()
    }

    func requestsChanged() { refreshOpenMenu() }

    /// In Island mode the mark is hidden — the panel is the whole surface.
    ///
    /// Hiding an NSStatusItem DELETES its remembered slot ("NSStatusItem
    /// Preferred Position", distance from the bar's right edge) — verified
    /// empirically on macOS 26. A re-shown item therefore lands at the far
    /// left of the item area, which is exactly the hidden section of menu bar
    /// managers like Ice. So: stash the slot before hiding, write it back
    /// before showing, and the mark returns where the user left it.
    func applyPresentation() {
        let show = Presentation.current.showsStatusItem
        let d = UserDefaults.standard
        // AppKit auto-generates "Item-0" for an app's first status item.
        let positionKey = "NSStatusItem Preferred Position \(statusItem.autosaveName ?? "Item-0")"
        if !show, statusItem.isVisible, let slot = d.object(forKey: positionKey) {
            d.set(slot, forKey: "stashedStatusItemPosition")
        }
        if show, !statusItem.isVisible, let slot = d.object(forKey: "stashedStatusItemPosition") {
            d.set(slot, forKey: positionKey)
        }
        statusItem.isVisible = show
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
        AgentActions.ack(AgentActions.reportFailedAnswer(
            AnswerWriter.write(behavior: behavior, for: r)))
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
            "\($0.id)|\($0.state.rawValue)|\($0.label)|\($0.project)|\($0.gitBranch ?? "")|\($0.termProgram)|\($0.recap)"
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
        AgentActions.focus(s, requests: requestStore.requests)
    }

    @objc func openAgentClicked(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? Agent else { return }
        AgentActions.open(agent)
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

    @objc func openWelcome(_ sender: NSMenuItem) {
        WelcomeWindow.shared.show()
    }

    /// Called by the inline Allow/Always/Deny button strip on permission rows.
    /// A failed write leaves the request in the store, so the next open still
    /// offers the same row.
    @discardableResult
    func answer(_ a: ApprovalAction) -> Bool {
        AgentActions.answer(a)
    }

    @objc func checkForUpdatesClicked(_ sender: NSMenuItem) {
        UpdateChecker.shared.check(manual: true)
    }

    @objc func installUpdateClicked(_ sender: NSMenuItem) {
        UpdateChecker.shared.installAvailable()
    }

    /// Inline strip on keystroke-backed permission rows (Antigravity, Codex, Copilot).
    func keystrokeAnswer(_ behavior: String, session: Session) {
        AgentActions.keystroke(behavior, session: session)
    }

    @objc func keystrokeApproveClicked(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Session else { return }
        AgentActions.keystroke("allow", session: s)
    }

    /// One clicked option on an inline question row.
    @objc func questionOptionClicked(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? QuestionAnswerAction else { return }
        AgentActions.answerQuestion(a.labels, request: a.request)
    }
}
