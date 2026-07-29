import Cocoa

/// The island's dark panel: a rounded slab floating just under the menu bar,
/// stacking whatever the current state needs inside it. Rounded on all four
/// corners — it sits clear of the screen edge, so nothing has to dodge the notch
/// and the user's own menu bar stays usable.
final class IslandContentView: NSView {
    static let corner: CGFloat = 14
    static let hPad: CGFloat = 14

    private let stack = NSStackView()
    private var stackTop: NSLayoutConstraint!
    private var tracking: NSTrackingArea?

    /// Pointer entered or left the panel. The controller opens and closes on this.
    var onHover: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-backed rather than drawn: square at the top (flush with the screen
        // edge), rounded below. Filling in `draw(_:)` under a layer-backed tree came
        // out washed out — the shape belongs to the layer.
        wantsLayer = true
        // Solid, like the hardware it pretends to extend. Translucency here read as
        // the window behind showing *through the notch*, which is exactly the
        // illusion this panel must never break.
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = Self.corner
        // Clip to the rounded shape: while the panel animates, rows laid out at
        // their final width must be *revealed* by the growing shape, not hang out
        // of it. The drop shadow therefore lives on the window (IslandPanel), where
        // masking can't eat it.
        layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stackTop = stack.topAnchor.constraint(equalTo: topAnchor, constant: 0)
        NSLayoutConstraint.activate([
            // Centred, not leading-pinned: during the expand animation both edges
            // then grow away from the notch symmetrically — the island inflates
            // from the top centre instead of sliding off to the left.
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackTop,
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Vertical inset the content starts at — the strip level with the menu bar is
    /// left clear so the notch (and the clock either side of it) isn't fought over.
    var topInset: CGFloat = 0 {
        didSet { stackTop.constant = topInset }
    }

    /// Hanging off the notch rather than floating on a plain screen edge. The top
    /// corners go square so the two black shapes meet without a seam; a display with
    /// no notch keeps the pill fully rounded, because there is nothing there for it
    /// to be continuous with.
    var flushTop = false {
        didSet {
            guard flushTop != oldValue else { return }
            layer?.maskedCorners = flushTop
                ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                : [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                   .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
    }

    /// Height the panel needs for the current rows. Measured from the stack rather
    /// than the view: the view's own size is whatever the panel last gave it.
    var contentHeight: CGFloat { topInset + stack.fittingSize.height + 12 }

    func setRows(_ views: [NSView]) {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        for v in views { stack.addArrangedSubview(v) }
        stack.layoutSubtreeIfNeeded()
    }

    /// Fade freshly set rows in, so a shape change arrives with its content
    /// instead of popping it fully formed.
    func fadeRowsIn(duration: TimeInterval) {
        stack.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            stack.animator().alphaValue = 1
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    /// Layer colours are resolved once, so a light/dark switch has to re-stamp them.
    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.cgColor
    }
    override var wantsUpdateLayer: Bool { true }
}

/// One session inside the island. The first row is the hero — the session the
/// panel is about right now: boxed, with the mark, a bold name and a status line
/// that says in colour what it wants. The rest are quiet one-liners, so several
/// sessions still fit under the notch. Clicking either jumps to the session.
final class IslandRowView: NSView {
    enum Style { case hero, compact }

    private let session: Session
    private let style: Style
    private let onClick: (Session) -> Void
    private let markView = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }

    static let markBox: CGFloat = 20

    init(session: Session, mark: NSImage?, style: Style, onClick: @escaping (Session) -> Void) {
        self.session = session
        self.style = style
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        // When the prompt takes the title, the repo identity survives here.
        toolTip = Self.name(session)

        let chips = NSStackView(views: Self.chips(session))
        chips.orientation = .horizontal
        chips.spacing = 5
        chips.setContentHuggingPriority(.required, for: .horizontal)
        chips.setContentCompressionResistancePriority(.required, for: .horizontal)

        switch style {
        case .hero:    buildHero(mark: mark, chips: chips)
        case .compact: buildCompact(chips: chips)
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Mark, bold name, coloured status line, chips top-right — in its own box so
    /// the eye lands here first.
    private func buildHero(mark: NSImage?, chips: NSStackView) {
        markView.image = mark.map { $0.isTemplate ? IconRenderer.tint($0, with: .white) : $0 }
        markView.imageScaling = .scaleNone
        markView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithAttributedString: Self.heroTitle(session))
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [title, spacer, chips])
        top.orientation = .horizontal
        top.spacing = 8

        let status = NSTextField(labelWithAttributedString: Self.heroStatus(session))
        status.lineBreakMode = .byTruncatingTail

        var column: [NSView] = [top]
        if !session.prompt.isEmpty {
            let you = NSTextField(labelWithAttributedString: Self.youLine(session))
            you.lineBreakMode = .byTruncatingTail
            column.append(you)
        }
        column.append(status)
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

    /// Dot, name, chips — one quiet line.
    private func buildCompact(chips: NSStackView) {
        let title = NSTextField(labelWithAttributedString: Self.compactTitle(session))
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false
        chips.translatesAutoresizingMaskIntoConstraints = false

        addSubview(title)
        addSubview(chips)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
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

    /// The hero's second line: what this session wants from the user, in its colour.
    private static func heroStatus(_ s: Session) -> NSAttributedString {
        let working = NSColor(srgbRed: 0.45, green: 0.72, blue: 1, alpha: 1)
        switch s.state {
        case .permission:
            let out = NSMutableAttributedString(string: "needs approval", attributes: [
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
            return NSAttributedString(string: "Claude asks", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: IconRenderer.questionDot,
            ])
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
            let out = NSMutableAttributedString(string: parts[0], attributes: [
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
        case .idle, .done:     return NSColor.white.withAlphaComponent(0.35)
        }
    }

    /// Agent name, model, where the session lives, and for how long — the facts
    /// that tell two otherwise identical rows apart. Elapsed stays a plain quiet
    /// number, not a chip, the way the reference panels keep it.
    private static func chips(_ s: Session) -> [NSView] {
        let agent = Agent.byID(s.agentID)
        var out = [chip(agent.name, tint: agent.brand)]
        if let m = s.modelChip { out.append(chip(m, tint: NSColor.white.withAlphaComponent(0.85))) }
        if s.entrypoint == "claude-desktop" {
            out.append(chip("Desktop", tint: .white))
        } else if s.entrypoint == "antigravity-app" {
            out.append(chip(agent.name == "Antigravity" ? "App" : agent.name, tint: .white))
        } else if let term = TerminalApp.known.first(where: { $0.termProgram == s.termProgram }) {
            out.append(chip(term.name, tint: .white))
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
        // A brand colour picked for a menu bar can be too dark on the island's
        // near-black panel; lift it until it reads.
        label.textColor = tint.usingColorSpace(.sRGB).map { c in
            c.brightnessComponent < 0.55
                ? NSColor(hue: c.hueComponent, saturation: c.saturationComponent * 0.9,
                          brightness: 0.85, alpha: 1)
                : c
        } ?? tint
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

/// The pending approval, shown under the session that raised it: what will run,
/// and the buttons to answer it without leaving the panel. Deny and Allow lead;
/// "Always allow" and handing the prompt back to the terminal stay available but
/// quiet. Shortcut hints appear only when the global shortcut is actually on, so
/// the panel never advertises a key that does nothing.
final class IslandApprovalView: NSView {
    private let onChoose: (String) -> Void

    init(request: ApprovalRequest, deferTitle: String, width: CGFloat,
         onChoose: @escaping (String) -> Void) {
        self.onChoose = onChoose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        var rows: [NSView] = [Self.header()]
        if let tool = Self.toolLine(request) { rows.append(tool) }
        if let context = request.context {
            let box = NSView()
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            box.layer?.cornerRadius = 6
            let ctx = ApprovalContextView(context: context, leading: 10)
            ctx.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(ctx)
            NSLayoutConstraint.activate([
                ctx.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                ctx.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                ctx.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
                ctx.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),
                ctx.heightAnchor.constraint(equalToConstant: ctx.frame.height),
            ])
            rows.append(box)
            if let summary = Self.diffSummary(context) { rows.append(summary) }
        }

        let shortcuts = UserDefaults.standard.bool(forKey: "globalApprovalShortcut")
        let deny = Self.button("Deny", hint: shortcuts ? KeyCombo.deny.display : nil,
                               prominent: false, target: self, action: #selector(denyClicked))
        let allow = Self.button("Allow", hint: shortcuts ? KeyCombo.allow.display : nil,
                                prominent: true, target: self, action: #selector(allowClicked))
        let main = NSStackView(views: [deny, allow])
        main.orientation = .horizontal
        main.distribution = .fillEqually
        main.spacing = 8
        rows.append(main)

        var secondary: [NSView] = []
        if request.ruleSuggestion != nil {
            let always = Self.link("Always allow", target: self, action: #selector(alwaysClicked))
            always.toolTip = request.ruleMenuTitle
            secondary.append(always)
        }
        secondary.append(Self.link(deferTitle, target: self, action: #selector(deferClicked)))
        let secondaryRow = NSStackView(views: secondary)
        secondaryRow.orientation = .horizontal
        secondaryRow.spacing = 14
        rows.append(secondaryRow)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: width),
            main.widthAnchor.constraint(equalToConstant: width),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func allowClicked() { onChoose("allow") }
    @objc private func denyClicked() { onChoose("deny") }
    @objc private func alwaysClicked() { onChoose("always") }
    @objc private func deferClicked() { onChoose("defer") }

    /// "● Permission Request" — names what this card is, the way the reference does.
    private static func header() -> NSView {
        let out = NSMutableAttributedString(string: "● ", attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: IconRenderer.amberDot,
        ])
        out.append(NSAttributedString(string: "Permission Request", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]))
        return NSTextField(labelWithAttributedString: out)
    }

    /// "⚠︎ Edit  src/auth/middleware.ts" — the tool in warning orange, its target
    /// quiet beside it. Bash skips the target: the command box below carries it
    /// whole, and saying it twice helps nobody.
    private static func toolLine(_ r: ApprovalRequest) -> NSView? {
        guard !r.toolName.isEmpty else { return nil }
        var rest = r.display
        if rest.hasPrefix(r.toolName) { rest.removeFirst(r.toolName.count) }
        while rest.first == ":" || rest.first == " " { rest.removeFirst() }
        if case .bash = r.context { rest = "" }
        let out = NSMutableAttributedString(string: "⚠︎ \(r.toolName)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.systemOrange,
        ])
        if !rest.isEmpty {
            out.append(NSAttributedString(string: "  \(rest)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            ]))
        }
        let l = NSTextField(labelWithAttributedString: out)
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    /// "+3 −1" under a diff — the size of the change at one glance. The mini-diff
    /// itself already ends with "+N more edits" when truncated, so only the line
    /// counts live here.
    private static func diffSummary(_ context: ApprovalRequest.Context) -> NSView? {
        guard case .diff(let old, let new, _) = context else { return nil }
        func count(_ s: String) -> Int {
            s.isEmpty ? 0 : s.split(separator: "\n", omittingEmptySubsequences: false).count
        }
        let out = NSMutableAttributedString(string: "+\(count(new))", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.systemGreen,
        ])
        out.append(NSAttributedString(string: "  −\(count(old))", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.systemRed,
        ]))
        return NSTextField(labelWithAttributedString: out)
    }

    private static func button(_ title: String, hint: String?, prominent: Bool,
                               target: Any, action: Selector) -> NSButton {
        let b = IslandButton(title: "", target: target, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.layer?.backgroundColor = (prominent ? NSColor.white.withAlphaComponent(0.92)
                                              : NSColor.white.withAlphaComponent(0.10)).cgColor
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: prominent ? NSColor.black : NSColor.white,
        ])
        if let hint {
            text.append(NSAttributedString(string: " \(hint)", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: (prominent ? NSColor.black : NSColor.white)
                    .withAlphaComponent(0.45),
            ]))
        }
        b.attributedTitle = text
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    private static func link(_ title: String, target: Any, action: Selector) -> NSButton {
        let b = IslandButton(title: "", target: target, action: action)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ])
        return b
    }
}

/// A question the agent is waiting on, shown under its session. The options live
/// in the agent's own UI — the hook that could carry them here deliberately does
/// not block on questions yet — so the card names the question and hands over in
/// one click instead of pretending to be answerable.
final class IslandQuestionView: NSView {
    private let onDefer: () -> Void

    init(question: String, deferTitle: String, width: CGFloat, onDefer: @escaping () -> Void) {
        self.onDefer = onDefer
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let head = NSMutableAttributedString(string: "💬 ", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
        ])
        head.append(NSAttributedString(string: "Claude asks", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: IconRenderer.questionDot,
        ]))
        let header = NSTextField(labelWithAttributedString: head)

        let q = NSTextField(wrappingLabelWithString: question)
        q.font = .systemFont(ofSize: 13, weight: .medium)
        q.textColor = .white
        q.preferredMaxLayoutWidth = width

        let go = IslandButton(title: "", target: self, action: #selector(deferClicked))
        go.isBordered = false
        go.attributedTitle = NSAttributedString(string: deferTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ])

        let stack = NSStackView(views: [header, q, go])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: width),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func deferClicked() { onDefer() }
}

/// A button inside the island. The panel is deliberately non-activating and never
/// becomes key, and AppKit swallows the first click into an inactive window as an
/// "activate me" click — so without this, Allow does nothing until the second try.
final class IslandButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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

/// The collapsed pill: mark, one line of text, and how many sessions are live —
/// at a FIXED width, the notch's own. A pill that resized with every rotating
/// verb wobbled in the corner of the eye all day long; the notch never moves,
/// so neither does its chin. Text swaps in place and truncates when it must.
final class IslandPillView: NSView {
    private let markView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = BadgeView()
    private var height: NSLayoutConstraint!
    private var width: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        markView.imageScaling = .scaleNone
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [markView, label, badge])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        height = heightAnchor.constraint(equalToConstant: 30)
        width = widthAnchor.constraint(equalToConstant: 150)
        NSLayoutConstraint.activate([
            // Centred as a group inside the fixed pill, so an idle mark sits in
            // the middle rather than hugging a corner of all that black.
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            height, width,
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Just the next animation frame — no layout, no resize.
    func update(mark: NSImage?) {
        markView.image = mark.map { $0.isTemplate ? IconRenderer.tint($0, with: .white) : $0 }
        markView.isHidden = markView.image == nil
    }

    func configure(mark: NSImage?, text: String, count: Int, height h: CGFloat,
                   width w: CGFloat, tint: NSColor? = nil) {
        update(mark: mark)
        label.stringValue = text
        label.isHidden = text.isEmpty
        // A confirmation flash — "✓ Allowed" — speaks in its own colour and drops
        // the mono working voice for a moment.
        label.textColor = tint ?? NSColor.white.withAlphaComponent(0.9)
        label.font = tint == nil ? .monospacedSystemFont(ofSize: 11.5, weight: .medium)
                                 : .systemFont(ofSize: 12.5, weight: .semibold)
        badge.count = count
        height.constant = h
        width.constant = w
    }
}

/// "3" in a rounded slug — how many sessions the pill is standing in for.
final class BadgeView: NSView {
    var count: Int = 0 {
        didSet {
            isHidden = count < 2
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var text: NSAttributedString {
        NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.65),
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(18, text.size().width + 10), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let t = text
        t.draw(at: NSPoint(x: (bounds.width - t.size().width) / 2,
                           y: (bounds.height - t.size().height) / 2))
    }
}
