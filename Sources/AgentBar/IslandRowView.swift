import Cocoa

/// One session inside the island. The first row is the hero — the session the
/// panel is about right now: boxed, with the mark, a bold name and a status line
/// that says in colour what it wants. The rest are quiet one-liners, so several
/// sessions still fit under the notch. Clicking either jumps to the session.
final class IslandRowView: NSView {
    enum Style { case hero, compact }

    private let session: Session
    private let style: Style
    private let onClick: (Session) -> Void
    private let markView = IslandMascotView()
    /// The row's mark, for `IslandMascot` to wire up for pokes.
    var mascot: IslandMascotView { markView }
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }
    /// A file dropped here goes to this session (`DropToAgent`). Set by the panel.
    var onDrop: ((Session, NSPasteboard) -> Void)?
    private let hint = DropHint()

    static let markBox: CGFloat = 20

    init(session: Session, mark: NSImage?, style: Style, onClick: @escaping (Session) -> Void) {
        self.session = session
        self.style = style
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        // When the prompt takes the title, the repo identity survives here; a
        // recap rides along so even a compact one-liner can say what finished.
        toolTip = session.recap.isEmpty ? Self.name(session)
            : "\(Self.name(session))\n\(session.agent.name): \(session.recap)"
        // To VoiceOver a row is a button that says what the menu bar's row says,
        // and pressing it does what a click does: jump to the session.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(SessionRowView.plainTitle(SessionRowView.content(for: session)))

        let chips = NSStackView(views: Self.chips(session))
        chips.orientation = .horizontal
        chips.spacing = 5
        chips.setContentHuggingPriority(.required, for: .horizontal)
        chips.setContentCompressionResistancePriority(.required, for: .horizontal)

        switch style {
        case .hero:    buildHero(mark: mark, chips: chips)
        case .compact: buildCompact(mark: mark, chips: chips)
        }
        // Over everything else in the row, and hidden until a drag arrives.
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.isHidden = true
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor),
            hint.topAnchor.constraint(equalTo: topAnchor),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes(DropToAgent.pasteboardTypes)
    }

    // MARK: - Dropping a file on it

    private var dropColour: NSColor { WrapStyle.colour(for: session.agentID) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let why = DropToAgent.refusal(for: session) {
            hint.show("\(session.agent.name) \(why)", colour: NSColor.white.withAlphaComponent(0.6), refused: true)
            return []
        }
        hint.show("Drop to hand it to \(session.agent.name)", colour: dropColour, refused: false)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hint.isHidden = true }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DropToAgent.refusal(for: session) == nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard DropToAgent.refusal(for: session) == nil, let onDrop else { return false }
        onDrop(session, sender.draggingPasteboard)
        return true
    }

    /// What happened to a drop, said on the row for a moment.
    func report(_ outcome: DropToAgent.Outcome) {
        switch outcome {
        case .pasted:
            hint.show("✓ In \(session.agent.name)'s prompt — add a word and press Return", colour: dropColour, refused: false)
        case .copied(let app):
            hint.show("Path copied — press ⌘V in \(app)", colour: dropColour, refused: false)
        case .refused(let why):
            hint.show("\(session.agent.name) \(why)", colour: NSColor.white.withAlphaComponent(0.6), refused: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.hint.isHidden = true }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Mark, bold name, coloured status line, chips top-right — in its own box so
    /// the eye lands here first.
    private func buildHero(mark: NSImage?, chips: NSStackView) {
        markView.image = mark.map { $0.isTemplate ? IconRenderer.tint($0, with: .white) : $0 }
        markView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithAttributedString: Self.heroTitle(session))
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [title, spacer, chips])
        top.orientation = .horizontal
        top.spacing = 8

        let status = NSTextField(labelWithAttributedString: Self.heroStatus(session))
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 1

        var column: [NSView] = [top]
        if !session.prompt.isEmpty {
            let you = NSTextField(labelWithAttributedString: Self.youLine(session))
            you.lineBreakMode = .byTruncatingTail
            you.maximumNumberOfLines = 1
            column.append(you)
        }
        column.append(status)
        // The turn's recent tool steps under the live status — a quiet breadcrumb
        // (island plan, Phase 3.2). Only while working, and only once there is
        // more than the current step to show; head-truncated so the newest steps
        // survive a narrow panel.
        if session.state.isWorking, session.activity.count > 1 {
            let feed = NSTextField(labelWithAttributedString: Self.activityLine(session))
            feed.lineBreakMode = .byTruncatingHead
            feed.maximumNumberOfLines = 1
            column.append(feed)
        }
        // "You: …" asked; "Claude: …" answers — the pair reads as the exchange.
        if !session.recap.isEmpty, session.state == .done || session.state == .idle {
            let recap = NSTextField(labelWithAttributedString: Self.recapLine(session))
            recap.lineBreakMode = .byTruncatingTail
            recap.maximumNumberOfLines = 1
            column.append(recap)
        }
        let text = NSStackView(views: column)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(markView)
        addSubview(text)
        NSLayoutConstraint.activate([
            markView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            markView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            markView.widthAnchor.constraint(equalToConstant: Self.markBox),
            text.leadingAnchor.constraint(equalTo: markView.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    /// Mark, dot, name, chips — one quiet line. Same mark as the hero, so every
    /// row says who it belongs to; the dot keeps carrying the state colour.
    private func buildCompact(mark: NSImage?, chips: NSStackView) {
        markView.image = mark.map { $0.isTemplate ? IconRenderer.tint($0, with: .white) : $0 }
        markView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithAttributedString: Self.compactTitle(session))
        title.lineBreakMode = .byTruncatingTail
        // A wrapped task name would overflow the fixed row height and tear the
        // panel during resize animations — one line, truncated, no exceptions.
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false
        chips.translatesAutoresizingMaskIntoConstraints = false

        addSubview(markView)
        addSubview(title)
        addSubview(chips)
        NSLayoutConstraint.activate([
            // Leading 10 + box 20 + gap 10 lands the text at the hero column's x.
            markView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            markView.centerYAnchor.constraint(equalTo: centerYAnchor),
            markView.widthAnchor.constraint(equalToConstant: Self.markBox),
            title.leadingAnchor.constraint(equalTo: markView.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            chips.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            chips.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chips.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 27),
        ])
    }

    // MARK: - Text

    private static func name(_ s: Session) -> String {
        var name = s.project.isEmpty ? "session" : s.project
        if let branch = s.gitBranch { name += " · \(branch)" }
        return name
    }

    private static func heroTitle(_ s: Session) -> NSAttributedString {
        NSAttributedString(string: name(s), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
    }

    private static func compactTitle(_ s: Session) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "● ", attributes: [
            .foregroundColor: dotColor(s),
            .font: NSFont.systemFont(ofSize: 8),
        ])
        // The task, when the writer carries it — "optimize queries" places a row
        // faster than a repo name does. The repo stays in the tooltip.
        out.append(NSAttributedString(string: s.prompt.isEmpty ? name(s) : s.prompt, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]))
        return out
    }

    /// "You: fix the auth bug in middleware" — the instruction this session is on.
    private static func youLine(_ s: Session) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "You: ", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.4),
        ])
        out.append(NSAttributedString(string: s.prompt, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]))
        return out
    }

    /// "Claude: Fixed the auth bug…" — what the turn ended with, under "Done".
    private static func recapLine(_ s: Session) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "\(s.agent.name): ", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.4),
        ])
        out.append(NSAttributedString(string: s.recap, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]))
        return out
    }

    /// "Reading · Searching · Editing" — the turn's recent tool steps.
    private static func activityLine(_ s: Session) -> NSAttributedString {
        NSAttributedString(string: s.activity.joined(separator: " · "), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: IslandInk.quiet,
        ])
    }

    /// The hero's second line: what this session wants from the user, in its colour.
    private static func heroStatus(_ s: Session) -> NSAttributedString {
        let working = NSColor(srgbRed: 0.45, green: 0.72, blue: 1, alpha: 1)
        switch s.state {
        case .permission:
            let out = NSMutableAttributedString(string: s.permissionWord, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: IconRenderer.amberDot,
            ])
            if !s.label.isEmpty {
                out.append(NSAttributedString(string: "  \(s.label)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.55),
                ]))
            }
            return out
        case .question:
            let out = NSMutableAttributedString(string: "\(s.agent.name) asks", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: IconRenderer.questionDot,
            ])
            var q = s.label
            if q.hasPrefix("❓") { q.removeFirst(); q = q.trimmingCharacters(in: .whitespaces) }
            if !q.isEmpty {
                out.append(NSAttributedString(string: "  \(q)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.55),
                ]))
            }
            return out
        case .error:
            let out = NSMutableAttributedString(string: "failed", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1),
            ])
            if !s.label.isEmpty {
                out.append(NSAttributedString(string: "  \(s.label)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.55),
                ]))
            }
            return out
        case .idle, .done:
            return NSAttributedString(string: "Done — click to jump", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: NSColor(srgbRed: 0.40, green: 0.83, blue: 0.45, alpha: 1),
            ])
        case .thinking, .tool:
            guard !s.label.isEmpty else {
                return NSAttributedString(string: "Working…", attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: working,
                ])
            }
            // "Bash  git push …" — the tool name carries the colour, the rest is quiet.
            let parts = s.label.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            // The label is whatever the agent wrote. One made only of colons splits
            // into nothing, and reads the way an empty one does.
            guard let head = parts.first else {
                return NSAttributedString(string: "Working…", attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: working,
                ])
            }
            let out = NSMutableAttributedString(string: head, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: working,
            ])
            if parts.count > 1 {
                out.append(NSAttributedString(string: "  \(parts[1])", attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.55),
                ]))
            }
            return out
        }
    }

    private static func dotColor(_ s: Session) -> NSColor {
        switch s.state {
        case .permission:      return IconRenderer.amberDot
        case .question:        return IconRenderer.questionDot
        case .thinking, .tool: return NSColor(srgbRed: 0.40, green: 0.83, blue: 0.45, alpha: 1)
        case .error:           return NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1)
        case .idle, .done:     return NSColor.white.withAlphaComponent(0.35)
        }
    }

    /// Agent name, model, where the session lives, and for how long — the facts
    /// that tell two otherwise identical rows apart. Elapsed stays a plain quiet
    /// number, not a chip, the way the reference panels keep it.
    private static func chips(_ s: Session) -> [NSView] {
        let agent = s.agent
        var out = [chip(agent.name, tint: agent.brand)]
        if let m = s.modelChip { out.append(chip(m, tint: NSColor.white.withAlphaComponent(0.85))) }
        // Next to the model, whose window it is: only once it is worth knowing.
        if let ctx = ContextGauge.text(s.contextPercent) {
            let c = chip(ctx, tint: ContextGauge.islandTint(ContextGauge.level(s.contextPercent)))
            c.setAccessibilityElement(true)
            c.setAccessibilityLabel(ContextGauge.spoken(s.contextPercent))
            out.append(c)
        }
        if s.entrypoint == "cloud" {
            out.append(chip("Cloud", tint: .white))
        } else if s.entrypoint == "claude-desktop" {
            out.append(chip("Desktop", tint: .white))
        } else if s.entrypoint == "antigravity-app" {
            out.append(chip(agent.name == "Antigravity" ? "App" : agent.name, tint: .white))
        } else if let term = TerminalApp.known.first(where: { $0.termProgram == s.termProgram }) {
            out.append(chip(term.name, tint: .white))
        }
        if let quiet = QuietWatch.quietMinutes(s) {
            let c = chip(QuietWatch.label(quiet), tint: IconRenderer.amberDot)
            c.toolTip = "No word from \(agent.name) for \(quiet) minutes. A long command is quiet too — "
                + "click the row to look."
            c.setAccessibilityElement(true)
            c.setAccessibilityLabel("Quiet for \(quiet) minutes")
            out.append(c)
        }
        // The quota this session draws on runs out within half an hour: say when,
        // and make the chip the way to carry the work over (`Handoff`).
        if let f = Handoff.runningOut(s, readings: UsageCenter.shared.readings), Handoff.canHandOff(s) {
            out.append(HandoffChip(session: s, forecast: f))
        }
        if let e = s.elapsed {
            let l = NSTextField(labelWithString: e)
            l.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
            l.textColor = NSColor.white.withAlphaComponent(0.45)
            out.append(l)
        }
        return out
    }

    private static func chip(_ text: String, tint: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        label.textColor = IconRenderer.legibleOnDark(tint)
        let box = ChipBox(label: label)
        return box
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { onClick(session) }

    /// Right-click or control-click: carry this session's work over to another
    /// agent. A row has nothing else to offer that a click does not already do.
    override func menu(for event: NSEvent) -> NSMenu? {
        HandoffMenu.shared.menu(for: session,
                                runningOut: Handoff.runningOut(session, readings: UsageCenter.shared.readings))
    }

    override func accessibilityPerformPress() -> Bool {
        onClick(session)
        return true
    }
    /// See IslandButton: the panel never becomes key, so a click has to be taken
    /// as a real click rather than an activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .hero:
            NSColor.white.withAlphaComponent(hovered ? 0.085 : 0.055).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        case .compact:
            guard hovered else { return }
            NSColor.white.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
    }
}

/// A rounded translucent pill behind a chip label.
final class ChipBox: NSView {
    init(label: NSTextField) {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.11).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
}

/// "out ~15:40 ↗" on a session whose quota is nearly gone: a click opens Continue
/// in ▸, the row's own right-click menu, so the way out is where the warning is.
final class HandoffChip: NSView {
    private let session: Session
    private let forecast: UsagePace.Forecast

    init(session: Session, forecast: UsagePace.Forecast) {
        self.session = session
        self.forecast = forecast
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: UsagePace.short(forecast) + " ↗")
        label.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        label.textColor = IconRenderer.legibleOnDark(IconRenderer.amberDot)
        let box = ChipBox(label: label)
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor), box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor), box.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = "\(session.agent.name)'s limit runs out ~\(UsageCenter.when(forecast.runsOutAt)) at this pace. "
            + "Click to carry on in another agent."
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Limit runs out at \(UsageCenter.when(forecast.runsOutAt)). Continue in another agent")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Taken here, not passed to the row: a click on the chip is not a jump.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { pop() }
    override func accessibilityPerformPress() -> Bool { pop(); return true }

    private func pop() {
        guard let menu = HandoffMenu.shared.menu(for: session, runningOut: forecast) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)   // under it: not flipped
    }
}

/// The row's face while a file hovers over it: who it would go to, or why not.
final class DropHint: NSView {
    private let label = NSTextField(labelWithString: "")
    private var colour = NSColor.white
    private var refused = false

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: String, colour: NSColor, refused: Bool) {
        label.stringValue = text
        label.textColor = refused ? IslandInk.quiet : .white
        self.colour = colour
        self.refused = refused
        isHidden = false
        needsDisplay = true
        setAccessibilityLabel(text)
    }

    /// Drags pass through to the row underneath; this only draws.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 9, yRadius: 9)
        NSColor(white: 0.06, alpha: 0.94).setFill()
        path.fill()
        (refused ? NSColor.white.withAlphaComponent(0.06) : colour.withAlphaComponent(0.28)).setFill()
        path.fill()
        guard !refused else { return }
        colour.setStroke()
        path.lineWidth = 1.5
        let dashes: [CGFloat] = [5, 3]
        path.setLineDash(dashes, count: 2, phase: 0)
        path.stroke()
    }
}
