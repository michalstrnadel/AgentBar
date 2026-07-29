import Cocoa

/// The island surface: a small pill under the notch that says what the agents are
/// doing, and opens into the full session list — with the pending approval
/// answerable in place — when the user puts the pointer on it. It only ever grows
/// on purpose; nothing unfolds over the screen on its own.
final class IslandController: NSObject {
    /// The pill is always on screen — it is the app's presence, the way the menu bar
    /// mark is. With nothing running it is just the mark; work adds a line of text.
    private enum Mode {
        case collapsed
        case expanded
    }

    private let panel = IslandPanel()
    private let content = IslandContentView()
    private let pill = IslandPillView()
    private let mascot: MascotDriver

    private var sessions: [Session] = []
    private var requests: [ApprovalRequest] = []
    private var mode: Mode = .collapsed
    private var hovered = false
    private var tracking: NSTrackingArea?
    private var collapseWork: DispatchWorkItem?

    private static let expandedWidth: CGFloat = 460
    /// Deliberately small. The collapsed island is a glance, not a panel — anything
    /// taller starts covering the screen for no gain.
    private static let pillHeight: CGFloat = 30
    /// Nothing running: mark only, no wider than it needs to be.
    private static let idleWidth: CGFloat = 58
    private static let rowSpacing: CGFloat = 8
    /// Beyond this the panel would run down the screen; the rest are summarised.
    private static let maxRows = 6

    init(mascot: MascotDriver) {
        self.mascot = mascot
        super.init()
        panel.contentView = content
        content.autoresizingMask = [.width, .height]
        content.onHover = { [weak self] inside in self?.hover(inside) }
        // The panel is always dark, whatever the system is set to. Without this the
        // reused approval strip and mini-diff render for a light background and go
        // nearly invisible on it.
        panel.appearance = NSAppearance(named: .darkAqua)
    }

    func start() {
        // Going in or out of fullscreen, and switching desktop, change nothing about
        // the sessions — so without these the panel would sit hidden (or floating over
        // someone's fullscreen video) until an agent happened to do something.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(surroundingsChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(surroundingsChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        mascot.sink("island") { [weak self] image, word in
            guard let self else { return }
            let textChanged = word != self.word
            self.mark = image
            self.word = word
            guard self.mode == .collapsed else { return }
            // A sprite frame is not a layout change. Re-running the whole pass here
            // rebuilt the row and resized the panel ~12×/s, which is what made the
            // mascot look frozen; only the width can actually need revisiting.
            if textChanged { self.layout() } else { self.pill.update(mark: image) }
        }
        rebuild()
    }

    private var mark: NSImage?
    private var word = ""

    /// What the pill says. The panel no longer opens by itself, so the pill is the
    /// only thing a waiting session gets to say — it has to name the wait, not just
    /// animate. Otherwise it's Claude's rotating verb, as in the menu bar.
    private var pillText: String {
        switch visibleSessions.first?.state {
        case .permission: return "needs approval"
        case .question:   return "wants an answer"
        default:          return word.isEmpty ? "" : "\(word)…"
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        mascot.sink("island", nil)
        panel.orderOut(nil)
    }

    /// The Space or the displays changed. Rebuild now for the common case, and once
    /// more after the transition settles — the notification lands while the incoming
    /// fullscreen window is still animating into place, so an immediate look can
    /// still see the old shape.
    @objc private func surroundingsChanged() {
        rebuild()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.rebuild() }
    }

    func apply(sessions: [Session], requests: [ApprovalRequest]) {
        self.sessions = sessions
        self.requests = requests
        rebuild()
    }

    // MARK: - State

    /// Exactly what the menu lists. A finished session is still a session — it stays
    /// until its process dies or the store prunes it, so the panel and the dropdown
    /// never disagree about what is running.
    private var visibleSessions: [Session] { sessions }

    private func rebuild() {
        // No fullscreen exception. Hiding there was in the plan and it was wrong:
        // a fullscreen terminal is where the agents actually run, so that is the one
        // place the island must not disappear from.
        guard Presentation.current.showsIsland, IslandGeometry.screen != nil
        else { panel.orderOut(nil); return }

        // Only the pointer opens the panel. Even a pending approval stays a pill —
        // an island that unfolds over the screen on its own is in the way, which is
        // the opposite of the point. The pill says what is waiting; hovering acts.
        mode = hovered ? .expanded : .collapsed
        layout()
    }

    // MARK: - Layout

    private func layout() {
        guard let screen = IslandGeometry.screen else { return }
        switch mode {
        case .collapsed:
            content.alphaValue = 1
            content.topInset = 0
            pill.configure(mark: mark, text: pillText, count: visibleSessions.count,
                           height: Self.pillHeight)
            content.setRows([pill])
            // Idle it shrinks to just the mark; text and count widen it as they appear.
            let w = min(420, max(Self.idleWidth, pill.contentWidth + IslandContentView.hPad * 2))
            panel.setFrame(IslandGeometry.frame(width: w, height: Self.pillHeight, on: screen),
                           display: true)
        case .expanded:
            content.alphaValue = 1
            content.topInset = 10
            content.setRows(rows())
            panel.setFrame(IslandGeometry.frame(width: Self.expandedWidth,
                                                height: content.contentHeight, on: screen),
                           display: true)
        }
        panel.orderFront(nil)
        content.needsDisplay = true
    }

    private func rows() -> [NSView] {
        var out: [NSView] = []
        let visible = visibleSessions
        for s in visible.prefix(Self.maxRows) {
            let mark = IconRenderer.shared.sprite(for: Agent.byID(s.agentID)).restingColor
            let row = IslandRowView(session: s, mark: mark) { [weak self] session in
                self?.click(session)
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant:
                Self.expandedWidth - IslandContentView.hPad * 2).isActive = true
            out.append(row)
            out.append(contentsOf: approvalViews(for: s))
        }
        if visible.count > Self.maxRows {
            out.append(more(visible.count - Self.maxRows))
        }
        if visible.isEmpty { out.append(emptyRow()) }
        out.append(footer())
        return out
    }

    /// The pending request's own detail and buttons, reusing exactly what the menu
    /// shows — same mini-diff, same Allow / Always / Deny / defer.
    private func approvalViews(for s: Session) -> [NSView] {
        guard s.state == .permission else { return [] }
        let mine = requests.filter { $0.sessionId == s.id }
        guard !mine.isEmpty else { return [] }
        let indent = IslandRowView.markBox + 13
        var out: [NSView] = []
        for r in mine {
            let card = IslandApprovalView(
                request: r,
                deferTitle: s.entrypoint == "claude-desktop" ? "Answer in Claude" : "Answer in terminal",
                width: Self.expandedWidth - IslandContentView.hPad * 2 - indent
            ) { behavior in
                AgentActions.answer(ApprovalAction(request: r, behavior: behavior, session: s))
            }
            // Line the card up under the row's text, past the mascot column.
            let wrapper = NSStackView(views: [card])
            wrapper.orientation = .horizontal
            wrapper.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
            out.append(wrapper)
        }
        return out
    }

    private func more(_ n: Int) -> NSView {
        let l = NSTextField(labelWithString: "+\(n) more session\(n == 1 ? "" : "s")")
        l.font = .systemFont(ofSize: 11)
        l.textColor = NSColor.white.withAlphaComponent(0.45)
        return l
    }

    private func emptyRow() -> NSView {
        let l = NSTextField(labelWithString: "No active sessions")
        l.font = .systemFont(ofSize: 12)
        l.textColor = NSColor.white.withAlphaComponent(0.45)
        return l
    }

    /// In Island-only mode the menu bar mark is gone, so the panel carries the way
    /// into Settings, updates and Quit itself.
    private func footer() -> NSView {
        let dots = NSButton(title: "⋯", target: self, action: #selector(showMenu(_:)))
        dots.isBordered = false
        dots.font = .systemFont(ofSize: 15, weight: .semibold)
        dots.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        dots.toolTip = "AgentBar"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer, dots])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant:
            Self.expandedWidth - IslandContentView.hPad * 2).isActive = true
        return row
    }

    // MARK: - Interaction

    private func hover(_ inside: Bool) {
        hovered = inside
        if inside { return rebuild() }
        // A moment's grace on the way out, so crossing a gap between subviews — or
        // the panel shrinking out from under the pointer — doesn't snap it shut.
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovered else { return }
            self.rebuild()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func click(_ s: Session) {
        AgentActions.focus(s, requests: requests)
    }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Appearance…", action: #selector(openWelcome), keyEquivalent: "")
        menu.addItem(withTitle: "Global Allow / Deny shortcut…", action: #selector(openSettings),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AgentBar", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func openWelcome() { WelcomeWindow.shared.show() }
    @objc private func openSettings() { SettingsWindow.shared.show() }
    @objc private func checkUpdates() { UpdateChecker.shared.check(manual: true) }
}
