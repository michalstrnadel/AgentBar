import Cocoa

/// **Take a break**: the island opened into a small game — Space Bugs or Bug
/// Hunt (`GameChoice`) — or into the office (`Office`), on the person's click
/// from its ⋯ menu or the joystick, and only then. It holds the island open and takes the keys
/// the way a denial note does (`IslandController+Composing`), and gives both back
/// when it closes.
///
/// It yields to work. The moment something new waits on the person — a request,
/// a session asking — the game pauses and the island shows its rows, with that
/// request in them; the ⋯ menu offers the way back, score intact. A click
/// elsewhere pauses it too. Closed, paused or yielded, its clock does not run.
///
/// The office yields the same way with one exception: a session already at a
/// desk that starts waiting raises its hand there instead (`Office.yields`). A
/// click on that hand closes the office onto the rows; a click on any other desk
/// brings its terminal forward and leaves the keys there.
extension IslandController {
    /// A paused game is kept this long for "Back to the break"; after that the
    /// break is over and the next one starts fresh.
    static let breakKept: TimeInterval = 15 * 60

    /// Everything waiting on the person right now, by a key that stays the same
    /// while it waits: request files, and sessions in an asking state.
    var waitingKeys: Set<String> {
        Set(requests.map { "req:" + $0.fileName })
            .union(sessions.filter { $0.state.waitsOnHuman }.map { "ses:" + $0.id })
    }

    /// The ⋯ menu's rows for it: the games on offer, the last one played first —
    /// or the one put aside, to go back to.
    func breakMenuItems() -> [NSMenuItem] {
        if let suspended = breakSuspendedAt, Date().timeIntervalSince(suspended) > Self.breakKept {
            dropBreak()
        }
        if let game = breakGame, let choice = breakChoice {
            let item = NSMenuItem(title: choice.backTitle(score: game.score),
                                  action: #selector(breakClicked(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil)
            return [item]
        }
        // Both games are a break; the header says so, the rows say which.
        let header = NSMenuItem(title: "Take a break", action: nil, keyEquivalent: "")
        header.isEnabled = false
        return [header] + (Self.gameOrder + [.office]).map { choice in
            let item = NSMenuItem(title: "\(choice.title)…", action: #selector(gameChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil)
            item.toolTip = choice.detail + (choice.isGame
                ? " It steps aside the moment an agent needs you."
                : " A session at a desk that needs you raises its hand; anyone else steps it aside.")
            return item
        }
    }

    /// The last game played first; the office after the games.
    static var gameOrder: [GameChoice] {
        [GameChoice.last] + GameChoice.allCases.filter { $0 != GameChoice.last && $0.isGame }
    }

    /// The joystick, or the way back: a game put aside comes straight back; with
    /// none, the joystick offers the games.
    @objc func breakClicked(_ sender: Any?) {
        if breakGame == nil, let button = sender as? NSButton {
            let menu = NSMenu()
            for item in breakMenuItems() { menu.addItem(item) }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            return
        }
        // After the menu has gone: a menu still tracking would take the key back.
        DispatchQueue.main.async { [weak self] in self?.beginBreak() }
    }

    @objc func gameChosen(_ sender: NSMenuItem) {
        guard let choice = (sender.representedObject as? String).flatMap(GameChoice.init) else { return }
        DispatchQueue.main.async { [weak self] in self?.beginBreak(choice) }
    }

    /// Opens `choice` (or the game put aside, or the last one played). Choosing
    /// the other game ends the one put aside: one break at a time.
    func beginBreak(_ choice: GameChoice? = nil) {
        guard Presentation.current.showsIsland else { return }
        if composing != nil { endComposing(relayout: false) }
        if let choice, breakChoice != nil, breakChoice != choice { dropBreak() }
        let pick = choice ?? breakChoice ?? GameChoice.last
        let view = breakGame ?? makeBreakView(pick)
        breakGame = view
        breakChoice = pick
        GameChoice.last = pick
        breakSuspendedAt = nil
        // What is already waiting was the person's to leave for later; only what
        // arrives after this does the game step aside for.
        breakWaiting = waitingKeys
        breakShown = true
        if let office = view as? OfficeView { office.update(sessions: visibleSessions, requests: requests) }
        if keysCameFrom == nil {
            let front = NSWorkspace.shared.frontmostApplication
            keysCameFrom = front?.processIdentifier == getpid() ? nil : front
        }
        collapseWork?.cancel()
        expandWork?.cancel()
        wantsExpanded = true
        panel.acceptsKeys = true
        rebuild(animated: true)
        layout(animated: true, force: true)
        panel.makeKey()
        panel.makeFirstResponder(view)
        view.resume()
        watchKey()
    }

    /// Esc or Close: the game is over, and the island is the island again.
    func endBreak() {
        guard breakGame != nil else { return }
        dropBreak()
        handBackKeys()
    }

    /// A desk in the office was clicked. A raised hand closes the office onto the
    /// rows, the request among them — it never focuses that session, which would
    /// hand its request back to the terminal. Any other desk brings its terminal
    /// forward and the office closes without taking the keys back from it.
    func officePicked(_ target: Office.Target) {
        guard breakGame is OfficeView else { return }
        switch target {
        case .showRequest:
            dropBreak()
            handBackKeys(stayOpen: true)
        case .focus(let id):
            guard let s = sessions.first(where: { $0.id == id }) else { return }
            // It started waiting since the room was drawn: the rows, not the terminal.
            if s.state.waitsOnHuman { return officePicked(.showRequest(sessionID: id)) }
            dropBreak()
            handBackKeys(reactivate: false)
            // No requests passed: whatever happens, this click answers nothing.
            AgentActions.focus(s, requests: [])
        }
    }

    /// The office is open: it is told who is in, on every store change.
    func updateOffice() {
        guard let office = breakGame as? OfficeView else { return }
        office.update(sessions: visibleSessions, requests: requests)
    }

    /// Something new waits on the person: the game steps aside, kept for later.
    func yieldBreak() {
        guard let view = breakGame, breakShown else { return }
        view.pause()
        breakShown = false
        breakSuspendedAt = Date()
        handBackKeys(stayOpen: true)
    }

    /// Called from `apply` on every store change.
    func checkBreakYield() {
        guard breakShown else { return }
        let yields: Bool
        if let office = breakGame as? OfficeView {
            yields = Office.yields(before: breakWaiting, now: waitingKeys, seated: office.seated,
                                   requestSessions: Dictionary(requests.map { ($0.fileName, $0.sessionId) },
                                                               uniquingKeysWith: { a, _ in a }))
        } else {
            yields = BreakGame.yields(before: breakWaiting, now: waitingKeys)
        }
        if yields {
            yieldBreak()
        } else {
            // Something answered meanwhile: forget it, so a new one still counts.
            breakWaiting.formIntersection(waitingKeys)
        }
    }

    private func makeBreakView(_ choice: GameChoice) -> NSView & IslandGame {
        let view = choice.make()
        view.onClose = { [weak self] in self?.endBreak() }
        (view as? OfficeView)?.onPick = { [weak self] target in
            // After the click has finished: closing the panel under it would eat the mouse-up.
            DispatchQueue.main.async { self?.officePicked(target) }
        }
        view.onWantsKeys = { [weak self, weak view] in
            guard let self, let view, self.breakShown else { return }
            self.panel.acceptsKeys = true
            self.panel.makeKey()
            self.panel.makeFirstResponder(view)
        }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: GameChoice.size.width),
            view.heightAnchor.constraint(equalToConstant: GameChoice.size.height),
        ])
        return view
    }

    private func dropBreak() {
        breakGame?.stop()
        breakGame = nil
        breakChoice = nil
        breakShown = false
        breakSuspendedAt = nil
        breakWaiting = []
        stopWatchingKey()
    }

    /// The keyboard back to the app that had it, and the island back to the pointer.
    /// `reactivate: false` when a click already sent the person somewhere else —
    /// a desk's terminal — so the app from before must not take the front back.
    private func handBackKeys(stayOpen: Bool = false, reactivate: Bool = true) {
        stopWatchingKey()
        panel.makeFirstResponder(nil)
        panel.acceptsKeys = false
        panel.resignKey()
        if stayOpen {
            // The rows, with what is waiting in them, until the pointer says otherwise.
            wantsExpanded = true
            peeking = true
        } else {
            wantsExpanded = hovered
            peeking = hovered
        }
        if reactivate, let app = keysCameFrom, !app.isTerminated { app.activate() }
        keysCameFrom = nil
        rebuild(animated: true)
        layout(animated: true, force: true)
    }

    /// A click anywhere else takes the key from the panel: the game pauses, never
    /// running where nobody is looking.
    private func watchKey() {
        guard breakKeyWatch == nil else { return }
        breakKeyWatch = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.breakGame?.pause()
        }
    }

    private func stopWatchingKey() {
        if let o = breakKeyWatch { NotificationCenter.default.removeObserver(o) }
        breakKeyWatch = nil
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
