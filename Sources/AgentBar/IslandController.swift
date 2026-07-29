import Cocoa

/// The island surface: a panel that stays out of the way until an agent is doing
/// something, drops out of the notch while it works, and opens into the full
/// session list — with the pending approval answerable in place — when the user
/// looks at it or an agent needs them.
final class IslandController: NSObject {
    private enum Mode {
        /// On screen but invisible: a hover target over the notch, so the island is
        /// reachable even when there is nothing to report.
        case resting
        case collapsed
        case expanded
    }

    private let panel = IslandPanel()
    private let content = IslandContentView()
    private let pill = IslandPillView()
    private let mascot: MascotDriver

    private var sessions: [Session] = []
    private var requests: [ApprovalRequest] = []
    private var mode: Mode = .resting
    private var hovered = false
    private var tracking: NSTrackingArea?
    private var collapseWork: DispatchWorkItem?

    /// How long a finished session keeps the island out before it retracts.
    private static let lingerAfterDone: TimeInterval = 6
    private static let expandedWidth: CGFloat = 460
    /// Deliberately small. The collapsed island is a glance, not a panel — anything
    /// taller starts covering the screen for no gain.
    private static let pillHeight: CGFloat = 30
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
        mascot.sink("island", nil)
        panel.orderOut(nil)
    }

    func apply(sessions: [Session], requests: [ApprovalRequest]) {
        self.sessions = sessions
        self.requests = requests
        rebuild()
    }

    // MARK: - State

    /// Sessions worth showing: anything not already finished, plus finished ones
    /// still inside their linger window so a "done" doesn't vanish mid-glance.
    private var visibleSessions: [Session] {
        let now = Date().timeIntervalSince1970
        return sessions.filter {
            $0.state != .idle && ($0.state != .done || now - $0.ts < Self.lingerAfterDone)
        }
    }

    private var needsAttention: Bool {
        visibleSessions.contains { $0.state == .permission || $0.state == .question }
    }

    private func rebuild() {
        guard Presentation.current.showsIsland, let screen = IslandGeometry.screen,
              !IslandGeometry.isFullscreen(on: screen)
        else { panel.orderOut(nil); return }

        let visible = visibleSessions
        // Only the pointer opens the panel. Even a pending approval stays a pill —
        // an island that unfolds over the screen on its own is in the way, which is
        // the opposite of the point. The pill says what is waiting; hovering acts.
        if hovered {
            mode = .expanded
        } else {
            mode = visible.isEmpty ? .resting : .collapsed
        }
        layout()
        // A done-only island has to retract by itself: no further state change is
        // coming to trigger another pass.
        scheduleRetractIfNeeded(visible)
    }

    private func scheduleRetractIfNeeded(_ visible: [Session]) {
        collapseWork?.cancel()
        guard !visible.isEmpty, visible.allSatisfy({ $0.state == .done }) else { return }
        let newest = visible.map(\.ts).max() ?? 0
        let due = Self.lingerAfterDone - (Date().timeIntervalSince1970 - newest)
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, due), execute: work)
    }

    // MARK: - Layout

    private func layout() {
        guard let screen = IslandGeometry.screen else { return }
        switch mode {
        case .resting:
            // An invisible strip under the notch, still hoverable.
            let notchW = IslandGeometry.notch(on: screen)?.width ?? 180
            content.setRows([])
            content.alphaValue = 0
            panel.setFrame(IslandGeometry.frame(width: notchW, height: Self.pillHeight, on: screen),
                           display: true)
        case .collapsed:
            content.alphaValue = 1
            content.topInset = 0
            pill.configure(mark: mark, text: pillText, count: visibleSessions.count,
                           height: Self.pillHeight)
            content.setRows([pill])
            let w = min(420, max(150, pill.contentWidth + IslandContentView.hPad * 2))
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
