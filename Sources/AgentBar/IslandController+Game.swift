import Cocoa

/// **Take a break**: the island opened into a small game, on the person's click
/// from its ⋯ menu — and only then. It holds the island open and takes the keys
/// the way a denial note does (`IslandController+Composing`), and gives both back
/// when it closes.
///
/// It yields to work. The moment something new waits on the person — a request,
/// a session asking — the game pauses and the island shows its rows, with that
/// request in them; the ⋯ menu offers the way back, score intact. A click
/// elsewhere pauses it too. Closed, paused or yielded, its clock does not run.
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

    /// The ⋯ menu's row for it: start one, or go back to the one put aside.
    func breakMenuItem() -> NSMenuItem {
        if let suspended = breakSuspendedAt, Date().timeIntervalSince(suspended) > Self.breakKept {
            dropBreak()
        }
        let title = breakGame.map { "Back to the break — \(Self.grouped($0.score))" } ?? "Take a break…"
        let item = NSMenuItem(title: title, action: #selector(breakClicked(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)
        item.toolTip = "A small game in the island. It steps aside the moment an agent needs you."
        return item
    }

    @objc func breakClicked(_ sender: Any?) {
        // After the menu has gone: a menu still tracking would take the key back.
        DispatchQueue.main.async { [weak self] in self?.beginBreak() }
    }

    func beginBreak() {
        guard Presentation.current.showsIsland else { return }
        if composing != nil { endComposing(relayout: false) }
        let view = breakGame ?? makeBreakView()
        breakGame = view
        breakSuspendedAt = nil
        // What is already waiting was the person's to leave for later; only what
        // arrives after this does the game step aside for.
        breakWaiting = waitingKeys
        breakShown = true
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
        if BreakGame.yields(before: breakWaiting, now: waitingKeys) {
            yieldBreak()
        } else {
            // Something answered meanwhile: forget it, so a new one still counts.
            breakWaiting.formIntersection(waitingKeys)
        }
    }

    private func makeBreakView() -> BreakGameView {
        let view = BreakGameView()
        view.onClose = { [weak self] in self?.endBreak() }
        view.onWantsKeys = { [weak self, weak view] in
            guard let self, let view, self.breakShown else { return }
            self.panel.acceptsKeys = true
            self.panel.makeKey()
            self.panel.makeFirstResponder(view)
        }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: BreakGameView.size.width),
            view.heightAnchor.constraint(equalToConstant: BreakGameView.size.height),
        ])
        return view
    }

    private func dropBreak() {
        breakGame?.stop()
        breakGame = nil
        breakShown = false
        breakSuspendedAt = nil
        breakWaiting = []
        stopWatchingKey()
    }

    /// The keyboard back to the app that had it, and the island back to the pointer.
    private func handBackKeys(stayOpen: Bool = false) {
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
        if let app = keysCameFrom, !app.isTerminated { app.activate() }
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
