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
    /// The pending requests as the menu shows them: the store's, plus the "Try an
    /// approval" demo while it waits (`DemoApproval` — on screen only).
    private var shownRequests: [ApprovalRequest] { DemoApproval.shared.merged(requestStore.requests) }

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

    /// A Settings control (or menu quick-toggle) changed something. Re-register
    /// hotkeys — idempotent, unregister-then-register — and refresh the open
    /// menu so its checkmarks and tooltips tell the truth.
    func settingsChanged() {
        applyHotKeyState()
        refreshOpenMenu()
    }

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
        var bindings: [(combo: KeyCombo, handler: () -> Void)] = []
        if approvalShortcutEnabled {
            bindings.append((KeyCombo.allow, { [weak self] in self?.hotkeyAnswer("allow") }))
            bindings.append((KeyCombo.deny, { [weak self] in self?.hotkeyAnswer("deny") }))
        }
        if LauncherPanel.shortcutEnabled {
            bindings.append((KeyCombo.launch, { LauncherPanel.shared.toggle() }))
        }
        HotKeyCenter.shared.apply(bindings)
    }

    @objc func openLauncher(_ sender: Any?) { LauncherPanel.shared.show() }

    /// Answer the newest pending PERMISSION request. Debounced so a held chord
    /// can't double-fire. Questions are skipped: Allow/Deny is not an answer to
    /// "which option?", and the hook would silently defer while the chord's tick
    /// claimed success.
    private func hotkeyAnswer(_ behavior: String) {
        let now = Date()
        guard now.timeIntervalSince(lastHotkey) > 1 else { return }
        lastHotkey = now
        guard let r = shownRequests.first(where: { $0.questions == nil })
        else { return }  // no-op when nothing answerable is pending
        // Routed through the same path the buttons use, so a plan gets its
        // keystroke approval instead of an allow the hook is obliged to
        // swallow — the chord must never tick success over a no-op.
        guard let session = sessions.first(where: { $0.id == r.sessionId }) else {
            // Without the session a plan can't take its keystroke approval, and a
            // raw "allow" is swallowed by the hook (docs/protocol.md) — acking it
            // would tick success over a no-op, the exact thing the comment above
            // promises never happens. Deny still works: it's a real hook decision.
            if r.isPlanRequest, behavior == "allow" { return }
            let written = AgentActions.reportFailedAnswer(
                AnswerWriter.write(behavior: behavior, for: r))
            // Recorded like every other decision that reached disk. It was not
            // until 1.28.0: this branch wrote the answer straight out and skipped
            // the ledger, so a chord pressed on a session the app had not yet seen
            // was a decision that never happened as far as "allowed 23× here" was
            // concerned — and that count is what a rule is offered from.
            if written {
                DecisionLedger.shared.record(behavior, request: r, session: nil)
            }
            AgentActions.ack(written)
            return
        }
        AgentActions.answer(ApprovalAction(request: r, behavior: behavior, session: session))
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
        if MenuBuilder.updateInPlace(menu, sessions: sessions, requests: shownRequests,
                                     controller: self) {
            builtSignature = content
        } else {
            populateRootMenu(menu) // growth: needs new rows, which an open menu renders fine
        }
    }

    private func populateRootMenu(_ menu: NSMenu) {
        MenuBuilder.populate(menu, sessions: sessions, requests: shownRequests,
                             controller: self)
        builtSignature = contentSignature()
    }

    /// Everything the menu renders from, flattened. Must cover the same fields the
    /// row builders read, or a real change would be skipped as a no-op.
    private func contentSignature() -> String {
        let rows = sessions.map {
            "\($0.id)|\($0.state.rawValue)|\($0.label)|\($0.project)|\($0.gitBranch ?? "")|\($0.termProgram)|\($0.recap)"
        }
        // Name AND identity (ts:hookPid): a request replaced under the same file
        // name (names repeat across the tools of one turn) must not read as "no
        // change" — the strip would stay bound to the old request and answer the
        // new one while showing the old command.
        let pending = shownRequests.map { "\($0.fileName)|\($0.identity)" }
        return (rows + ["req:"] + pending
                + ["upd:\(UpdateChecker.shared.status)",
                   "hk:\(approvalShortcutEnabled):\(KeyCombo.allow.display)\(KeyCombo.deny.display)",
                   "mode:\(systemColor)",
                   "snd:\(SoundCenter.enabled)",
                   "diag:\(Diagnostics.failures)"]).joined(separator: "\n")
    }

    // MARK: - Actions (targets for MenuBuilder items)

    @objc func sessionRowClicked(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Session else { return }
        AgentActions.focus(s, requests: shownRequests)
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

    /// Every row of the shared app section (`AppMenuModel`) lands here. The model
    /// decided what the row says; this only runs it. A sound toggle is followed by
    /// a refresh so a menu still open somewhere tells the truth.
    @objc func appMenuClicked(_ sender: NSMenuItem) {
        guard let action = AppMenuRenderer.action(of: sender) else { return }
        action.perform()
        if action == .toggleSounds { refreshOpenMenu() }
    }

    @objc func openShortcutSettings(_ sender: NSMenuItem) {
        SettingsWindow.shared.show()
    }

    /// The offer beside a repeat count: open the rule sheet, filled in with the
    /// prompt that is on screen. It writes nothing — the person still presses Add,
    /// and the sheet spends most of its room saying what the rule would refuse.
    @objc func makeRule(_ sender: NSMenuItem) {
        guard let payload = sender.identifier?.rawValue else { return }
        let parts = payload.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let r = requestStore.requests.first(where: { $0.fileName == parts[1] })
        else { return }
        let session = sessions.first { $0.id == r.sessionId }
        SettingsWindow.shared.addRule(from: RuleSheet.Prefill(
            decision: parts[0],
            shape: DecisionLedger.shape(of: r),
            cwd: r.cwd.isEmpty ? (session?.cwd ?? "") : r.cwd,
            display: r.display))
    }

    /// "Allow all N" under a pending request: each identical request that was in
    /// the menu when it opened and is still waiting, answered as its own Allow.
    @objc func allowAllAlike(_ sender: NSMenuItem) {
        guard let shown = sender.identifier?.rawValue.split(separator: ",").map(String.init) else { return }
        for q in ApprovalBatch.stillPending(shown, in: requestStore.requests) {
            guard let s = sessions.first(where: { $0.id == q.sessionId }) else { continue }
            AgentActions.answer(ApprovalAction(request: q, behavior: "allow", session: s))
        }
    }

    /// A finished session's project folder. The session itself is gone — there is no
    /// tab to jump back to — so the useful thing left is where the work happened.
    @objc func openPastProject(_ sender: NSMenuItem) {
        guard let cwd = sender.representedObject as? String, !cwd.isEmpty,
              FileManager.default.fileExists(atPath: cwd) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }

    /// Called by the inline Allow/Always/Deny button strip on permission rows.
    /// A failed write leaves the request in the store, so the next open still
    /// offers the same row.
    @discardableResult
    func answer(_ a: ApprovalAction) -> Bool {
        AgentActions.answer(a)
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
