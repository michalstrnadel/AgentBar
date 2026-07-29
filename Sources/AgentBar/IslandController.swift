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
    private var expandWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?
    /// A just-given answer, echoed in the pill for a beat — "✓ Allowed" — before
    /// the island goes back to reporting.
    private var flash: (text: String, tint: NSColor)?
    /// What the last layout pass drew, so a mode change can animate differently
    /// from a same-shape refresh.
    private var lastLaidMode: Mode?

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
            // While a flash is up the pill isn't the mascot's — leave it alone.
            if textChanged { self.layout(animated: true) }
            else if self.flash == nil { self.pill.update(mark: image) }
        }
        rebuild()
    }

    private var mark: NSImage?
    private var word = ""

    /// What the pill says. The panel no longer opens by itself, so the pill is the
    /// only thing a waiting session gets to say — it has to name the wait, not just
    /// animate. Otherwise it's Claude's rotating verb, as in the menu bar.
    ///
    /// Kept short on purpose: the pill has to stay narrower than the notch to read as
    /// part of it, and "needs approval" was already wider than that.
    private var pillText: String {
        if let flash { return flash.text }
        switch visibleSessions.first?.state {
        case .permission: return "approve?"
        case .question:   return "answer?"
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
        rebuild(animated: true)
    }

    // MARK: - State

    /// The same set the menu lists — a finished session stays until its process
    /// dies or the store prunes it — but ordered for a panel: whatever needs the
    /// user first, then the working, then the finished. Stable within each group,
    /// so rows don't trade places on every poll.
    private var visibleSessions: [Session] {
        sessions.enumerated().sorted { a, b in
            a.1.priority != b.1.priority ? a.1.priority > b.1.priority : a.0 < b.0
        }.map(\.1)
    }

    private func rebuild(animated: Bool = false) {
        // No fullscreen exception. Hiding there was in the plan and it was wrong:
        // a fullscreen terminal is where the agents actually run, so that is the one
        // place the island must not disappear from.
        guard Presentation.current.showsIsland, IslandGeometry.screen != nil
        else { panel.orderOut(nil); return }

        // Only the pointer opens the panel. Even a pending approval stays a pill —
        // an island that unfolds over the screen on its own is in the way, which is
        // the opposite of the point. The pill says what is waiting; hovering acts.
        // (`islandExpandDebug` holds it open, for screenshots and layout work.)
        let held = UserDefaults.standard.bool(forKey: "islandExpandDebug")
        mode = (hovered || held) ? .expanded : .collapsed
        layout(animated: animated)
    }

    // MARK: - Layout

    private func layout(animated: Bool = false) {
        guard let screen = IslandGeometry.screen else { return }
        content.flushTop = IslandGeometry.notch(on: screen) != nil
        let target: NSRect
        switch mode {
        case .collapsed:
            content.topInset = 0
            pill.configure(mark: flash == nil ? mark : nil, text: pillText,
                           count: flash == nil ? visibleSessions.count : 0,
                           height: Self.pillHeight, tint: flash?.tint)
            content.setRows([pill])
            // Idle it shrinks to just the mark; text and count widen it as they appear
            // — but never past the notch it is meant to look like part of. Several
            // agents at once make the mark itself wide, so this is a real ceiling,
            // not a formality.
            let ceiling = IslandGeometry.notch(on: screen)?.width ?? 420
            let w = min(ceiling, max(Self.idleWidth, pill.contentWidth + IslandContentView.hPad * 2))
            target = IslandGeometry.frame(width: w, height: Self.pillHeight, on: screen)
        case .expanded:
            content.topInset = 10
            content.setRows(rows())
            target = IslandGeometry.frame(width: Self.expandedWidth,
                                          height: content.contentHeight, on: screen)
        }
        let modeChanged = mode != lastLaidMode
        lastLaidMode = mode
        if animated, panel.isVisible {
            // Slow enough to read as one shape inflating out of the notch, quick
            // enough not to gate the click that follows. Same-shape refreshes only
            // morph the width, and take less.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = modeChanged ? 0.38 : 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                ctx.allowsImplicitAnimation = true
                self.panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                // The window shadow is shaped from the rendered content; after an
                // animated resize it has to be recut or it keeps the old outline.
                self?.panel.invalidateShadow()
            })
            if modeChanged { content.fadeRowsIn(duration: 0.34) }
        } else {
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
        }
        content.alphaValue = 1
        panel.orderFront(nil)
        content.needsDisplay = true
    }

    private func rows() -> [NSView] {
        var out: [NSView] = []
        let visible = visibleSessions
        let rowW = Self.expandedWidth - IslandContentView.hPad * 2
        for (i, s) in visible.prefix(Self.maxRows).enumerated() {
            // The list leads with whatever needs the user, so the first row is the
            // hero — boxed, with the mark; the rest stay one quiet line each.
            let style: IslandRowView.Style = i == 0 ? .hero : .compact
            let mark = style == .hero
                ? IconRenderer.shared.sprite(for: Agent.byID(s.agentID)).restingColor : nil
            let row = IslandRowView(session: s, mark: mark, style: style) { [weak self] session in
                self?.click(session)
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: rowW).isActive = true
            out.append(row)
            out.append(contentsOf: approvalViews(for: s))
            if let q = questionView(for: s) { out.append(q) }
        }
        if visible.count > Self.maxRows {
            out.append(more(visible.count - Self.maxRows))
        }
        if visible.isEmpty { out.append(emptyRow()) }
        out.append(footer())
        return out
    }

    /// Cards sit under their session, indented just enough to read as belonging
    /// to it rather than to the panel.
    private static let cardIndent: CGFloat = 12

    private func card(_ view: NSView) -> NSView {
        let wrapper = NSStackView(views: [view])
        wrapper.orientation = .horizontal
        wrapper.edgeInsets = NSEdgeInsets(top: 0, left: Self.cardIndent, bottom: 0, right: 0)
        return wrapper
    }

    private func deferTitle(for s: Session) -> String {
        s.entrypoint == "claude-desktop" ? "Answer in Claude" : "Answer in terminal"
    }

    /// The pending request's own detail and buttons — same mini-diff the menu
    /// shows, Deny and Allow in front, the answer echoed in the pill on the way out.
    private func approvalViews(for s: Session) -> [NSView] {
        guard s.state == .permission else { return [] }
        let mine = requests.filter { $0.sessionId == s.id }
        var out: [NSView] = []
        for r in mine {
            out.append(card(IslandApprovalView(
                request: r,
                deferTitle: deferTitle(for: s),
                width: Self.expandedWidth - IslandContentView.hPad * 2 - Self.cardIndent
            ) { [weak self] behavior in
                AgentActions.answer(ApprovalAction(request: r, behavior: behavior, session: s))
                self?.flashAnswer(behavior)
            }))
        }
        return out
    }

    /// The question card under a session that asked one. The hooks don't carry the
    /// options yet, so it shows the question and hands over in one click.
    private func questionView(for s: Session) -> NSView? {
        guard s.state == .question else { return nil }
        var q = s.label
        if q.hasPrefix("❓") { q.removeFirst(); q = q.trimmingCharacters(in: .whitespaces) }
        if q.isEmpty { q = "Claude has a question" }
        return card(IslandQuestionView(
            question: q,
            deferTitle: deferTitle(for: s),
            width: Self.expandedWidth - IslandContentView.hPad * 2 - Self.cardIndent
        ) { [weak self] in
            guard let self else { return }
            AgentActions.focus(s, requests: self.requests)
        })
    }

    /// Echo the choice in the pill — "✓ Allowed" — for a beat, then go back to
    /// reporting. Defer skips the flash: the hand-off itself is the feedback.
    private func flashAnswer(_ behavior: String) {
        hovered = false
        collapseWork?.cancel()
        let green = NSColor(srgbRed: 0.35, green: 0.85, blue: 0.45, alpha: 1)
        switch behavior {
        case "allow":  flash = ("✓ Allowed", green)
        case "always": flash = ("✓ Always allowed", green)
        case "deny":   flash = ("✕ Denied", NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1))
        default:       flash = nil
        }
        rebuild(animated: true)
        guard flash != nil else { return }
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flash = nil
            self.rebuild(animated: true)
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
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
        collapseWork?.cancel()
        expandWork?.cancel()
        if inside {
            // Hover intent, not hover: the pill sits where window title bars get
            // clicked and where a Cmd-Tab flick crosses, and a panel that unfolds
            // for every drive-by looks like a bug. A short dwell filters those out
            // without being felt by anyone who actually aims at it.
            if mode == .expanded { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hovered else { return }
                self.rebuild(animated: true)
            }
            expandWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            return
        }
        // A moment's grace on the way out, so crossing a gap between subviews — or
        // the panel shrinking out from under the pointer — doesn't snap it shut.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovered else { return }
            self.rebuild(animated: true)
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
