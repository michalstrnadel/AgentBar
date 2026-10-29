import Cocoa

/// The approval queue on the keyboard: one shortcut (off until switched on) opens
/// the island with the first waiting request picked, and the keys answer it —
/// Return allows (held as long as the card would hold the button), Delete denies,
/// N denies with a note, A always-allows where that is offered, ↑ ↓ pick another,
/// Esc hands the keyboard back.
///
/// The island takes the keyboard the way a note or the game takes it, and only
/// because the person pressed the shortcut: a request arriving never does this.
/// It closes when the queue is empty or the panel loses the keyboard.
extension IslandController {
    /// Requests the queue answers, in the order the panel lists them.
    var queueRequests: [ApprovalRequest] {
        visibleSessions.prefix(Self.maxRows).flatMap { s in
            s.state == .permission
                ? requests.filter { $0.sessionId == s.id && $0.questions == nil }
                : []
        }
    }

    func beginQueue(selecting fileName: String? = nil) {
        guard Presentation.current.showsIsland else { NSSound.beep(); return }
        let waiting = queueRequests
        guard !waiting.isEmpty else {
            flashText("Nothing waiting", tint: NSColor.white.withAlphaComponent(0.85))
            return
        }
        if breakShown { yieldBreak() }
        if composing != nil { endComposing(relayout: false) }
        queueSelection = fileName.flatMap { f in waiting.first { $0.fileName == f }?.fileName }
            ?? waiting[0].fileName
        if keysCameFrom == nil {
            let front = NSWorkspace.shared.frontmostApplication
            keysCameFrom = front?.processIdentifier == getpid() ? nil : front
        }
        let keys = queueKeys ?? IslandQueueKeys()
        keys.onKey = { [weak self] key, down in self?.queueKey(key, down: down) }
        queueKeys = keys
        collapseWork?.cancel()
        expandWork?.cancel()
        wantsExpanded = true
        panel.acceptsKeys = true
        rebuild(animated: true)
        layout(animated: true, force: true)
        panel.contentView?.addSubview(keys)
        panel.makeKey()
        panel.makeFirstResponder(keys)
        markQueueSelection()
        if queueKeyWatch == nil {
            queueKeyWatch = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                guard let self, self.composing == nil else { return }
                self.endQueue()
            }
        }
    }

    /// Esc, an empty queue, or the keyboard went elsewhere.
    func endQueue(handBack: Bool = true) {
        guard queueKeys != nil else { return }
        stopQueue()
        guard handBack else { return }
        panel.makeFirstResponder(nil)
        panel.acceptsKeys = false
        panel.resignKey()
        wantsExpanded = hovered
        peeking = hovered
        if let app = keysCameFrom, !app.isTerminated { app.activate() }
        keysCameFrom = nil
        rebuild(animated: true)
    }

    private func stopQueue() {
        if let o = queueKeyWatch { NotificationCenter.default.removeObserver(o) }
        queueKeyWatch = nil
        queueSelectedCard?.cancelHold()
        queueKeys?.removeFromSuperview()
        queueKeys = nil
        queueSelection = nil
        markQueueSelection()
    }

    /// After every store change: the picked request may have been answered (here
    /// or anywhere else). Move to the next one, or close when none is left.
    func checkQueue() {
        guard queueKeys != nil else { return }
        let waiting = queueRequests
        guard !waiting.isEmpty else { endQueue(); return }
        if !waiting.contains(where: { $0.fileName == queueSelection }) {
            queueSelection = waiting[0].fileName
        }
        wantsExpanded = true
        markQueueSelection()
        if panel.firstResponder !== queueKeys, composing == nil, let keys = queueKeys {
            panel.makeFirstResponder(keys)
        }
    }

    private var queueSelectedCard: IslandApprovalView? {
        queueSelection.flatMap { approvalCards[$0] }.flatMap(Self.cardView(in:))
    }

    private func markQueueSelection() {
        for (name, wrapper) in approvalCards {
            Self.cardView(in: wrapper)?.selected = name == queueSelection
        }
    }

    private func queueKey(_ key: IslandQueueKeys.Key, down: Bool) {
        let waiting = queueRequests
        guard let card = queueSelectedCard,
              let index = waiting.firstIndex(where: { $0.fileName == queueSelection })
        else { checkQueue(); return }
        switch (key, down) {
        case (.allow, true): card.pressAllow()
        case (.allow, false): card.releaseAllow()
        case (.deny, true): card.choose("deny")
        case (.always, true): card.choose("always")
        case (.note, true):
            // The note takes the keyboard from here; the queue is over once it does.
            stopQueue()
            card.setComposing(true)
        case (.up, true), (.down, true):
            card.cancelHold()
            let next = key == .up ? index - 1 : index + 1
            guard waiting.indices.contains(next) else { NSSound.beep(); return }
            queueSelection = waiting[next].fileName
            markQueueSelection()
        case (.close, true): endQueue()
        default: break
        }
    }

    static func cardView(in wrapper: NSView) -> IslandApprovalView? {
        (wrapper as? NSStackView)?.arrangedSubviews.first as? IslandApprovalView
    }
}

/// The invisible first responder that reads the queue's keys. Raw key codes, so a
/// layout that moves letters still finds Return and the arrows where they are.
final class IslandQueueKeys: NSView {
    enum Key { case allow, deny, note, always, up, down, close }
    var onKey: ((Key, Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    static func key(for code: UInt16) -> Key? {
        switch code {
        case 36, 76: return .allow      // Return, Enter
        case 51, 117: return .deny      // Delete, Forward Delete
        case 45: return .note           // N
        case 0: return .always          // A
        case 126: return .up
        case 125: return .down
        case 53: return .close          // Esc
        default: return nil
        }
    }

    override func keyDown(with event: NSEvent) {
        // A held key repeats; only the first press counts, or holding Return
        // would read as a hundred presses.
        guard !event.isARepeat, let k = Self.key(for: event.keyCode) else {
            if event.isARepeat { return }
            super.keyDown(with: event); return
        }
        onKey?(k, true)
    }

    override func keyUp(with event: NSEvent) {
        guard let k = Self.key(for: event.keyCode) else { return }
        onKey?(k, false)
    }

    override func cancelOperation(_ sender: Any?) { onKey?(.close, true) }
}
