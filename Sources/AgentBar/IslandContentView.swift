import Cocoa

/// The island's dark panel: a rounded slab floating just under the menu bar,
/// stacking whatever the current state needs inside it. Rounded on all four
/// corners — it sits clear of the screen edge, so nothing has to dodge the notch
/// and the user's own menu bar stays usable.
final class IslandContentView: NSView {
    static let corner: CGFloat = 14
    static let hPad: CGFloat = 14

    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    /// Pinned strip along the bottom edge — the way into Settings and Quit must
    /// not scroll away under a panel full of cards.
    private let footerHost = NSView()
    private let footerHairline = NSView()
    private var footerHeight: NSLayoutConstraint!
    private var stackTop: NSLayoutConstraint!
    /// Everything that spans the panel side to side, inset by the ears so nothing —
    /// the overlay scroller above all — lands in the transparent strip beside the
    /// body, where the mask would cut it off.
    private var sideInsets: [NSLayoutConstraint] = []
    private let outline = CAShapeLayer()
    private var tracking: NSTrackingArea?

    /// Pointer entered or left the panel. The controller opens and closes on this.
    var onHover: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-backed rather than drawn: filling in `draw(_:)` under a layer-backed
        // tree came out washed out — the shape belongs to the layer. What shape, is
        // `IslandShape`'s to say; the layer is masked with it in `layout()`.
        wantsLayer = true
        // Solid, like the hardware it pretends to extend. Translucency here read as
        // the window behind showing *through the notch*, which is exactly the
        // illusion this panel must never break.
        layer?.backgroundColor = NSColor.black.cgColor
        // Clip to the outline: while the panel animates, rows laid out at their
        // final width must be *revealed* by the growing shape, not hang out of it.
        // The drop shadow therefore lives on the window (IslandPanel), where masking
        // can't eat it. A path mask rather than `cornerRadius`: a corner radius can
        // round a corner but never curve one outward, which is what an ear is.
        layer?.masksToBounds = true
        layer?.mask = outline
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The rows live in a scroll view so a panel clamped at the screen edge
        // still shows everything: normally the panel is sized to the content and
        // nothing scrolls, but when the content is taller than the screen allows,
        // the overflow is reachable by wheel/trackpad instead of cut off.
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        addSubview(scroll)

        footerHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footerHost)
        footerHeight = footerHost.heightAnchor.constraint(equalToConstant: 0)
        // Only drawn once the rows actually overflow — with everything on
        // screen there is nothing for the strip to separate itself from.
        footerHairline.wantsLayer = true
        footerHairline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        footerHairline.alphaValue = 0
        footerHairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footerHairline)

        stackTop = stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 0)
        sideInsets = [
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerHairline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hPad),
            footerHairline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hPad),
        ]
        NSLayoutConstraint.activate(sideInsets + [
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerHost.topAnchor),
            footerHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            footerHeight,
            footerHairline.bottomAnchor.constraint(equalTo: footerHost.topAnchor),
            footerHairline.heightAnchor.constraint(equalToConstant: 1),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            // The document is exactly as tall as the rows — no trailing padding,
            // or the collapsed pill's document would outgrow its 30pt clip and a
            // legacy scroller would paint a bar down the side of the pill. The
            // panel's own bottom padding lives in `contentHeight` instead.
            doc.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            // Centred, not leading-pinned: during the expand animation both edges
            // then grow away from the notch symmetrically — the island inflates
            // from the top centre instead of sliding off to the left.
            stack.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
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
        didSet { if flushTop != oldValue { shapeChanged() } }
    }

    /// The ears an open panel may grow (`IslandShape`), and the height at which they
    /// start: the collapsed pill's, so a pill never has any. Only the ceiling is set
    /// here — how much of it shows is read off the current height on every layout
    /// pass, which is what keeps the ears in step with the frame animation.
    var earWidth: CGFloat = 0 {
        didSet { if earWidth != oldValue { shapeChanged() } }
    }
    var collapsedHeight: CGFloat = 0 {
        didSet { if collapsedHeight != oldValue { shapeChanged() } }
    }

    /// The ear the current frame has, or zero off a notch.
    private var ear: CGFloat {
        flushTop ? IslandShape.ear(full: earWidth, height: bounds.height,
                                   collapsedHeight: collapsedHeight) : 0
    }

    /// Stepped by the window frame animation, so the insets follow the ears
    /// before the pass that lays the rows out.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSideInsets()
    }

    private func shapeChanged() {
        updateSideInsets()
        needsLayout = true
    }

    private func updateSideInsets() {
        let e = ear
        for c in sideInsets {
            let base: CGFloat = c.firstItem === footerHairline ? Self.hPad : 0
            let inward = c.firstAttribute == .leading ? 1 : -1
            let value = CGFloat(inward) * (base + e)
            if c.constant != value { c.constant = value }
        }
    }

    /// Height the panel needs for the current rows plus the pinned footer.
    /// Measured from the stack rather than the view: the view's own size is
    /// whatever the panel last gave it.
    var contentHeight: CGFloat { topInset + stack.fittingSize.height + 12 + footerHeight.constant }

    /// The strip pinned along the bottom edge (nil while collapsed). It lives
    /// outside the scroll view, so a panel full of cards still shows the way
    /// into Settings and Quit.
    func setFooter(_ view: NSView?) {
        for v in footerHost.subviews { v.removeFromSuperview() }
        guard let view else {
            footerHeight.constant = 0
            footerHairline.alphaValue = 0
            return
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        footerHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: footerHost.centerXAnchor),
            view.topAnchor.constraint(equalTo: footerHost.topAnchor, constant: 6),
        ])
        footerHost.layoutSubtreeIfNeeded()
        footerHeight.constant = view.fittingSize.height + 12
    }

    /// `resetScroll` on shape changes (collapsed↔expanded) only: the store ticks
    /// rebuild these rows about once a second while an agent works, and yanking
    /// the offset to the top each time made the overflow unreachable — the exact
    /// bug the scroll view exists to fix.
    func setRows(_ views: [NSView], resetScroll: Bool = false) {
        let offset = scroll.contentView.bounds.origin
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        for v in views { stack.addArrangedSubview(v) }
        stack.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: resetScroll ? .zero : offset)
        scroll.reflectScrolledClipView(scroll.contentView)
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

    override func layout() {
        super.layout()
        // Recut on every pass, without the implicit fade a free-standing layer
        // gives a changed path: during the expand the window steps the frame and
        // the outline has to land on each step, not drift a quarter second behind.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.frame = bounds
        outline.path = IslandShape.path(in: bounds.size, corner: Self.corner,
                                        ear: ear, flushTop: flushTop)
        CATransaction.commit()
        // The hairline earns its keep only when rows pass under the strip.
        let overflowing = stack.fittingSize.height + topInset > scroll.contentView.bounds.height
        footerHairline.alphaValue = (overflowing && footerHeight.constant > 0) ? 1 : 0
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

    /// Outside the outline is not the island. The window server already lets
    /// clicks fall through transparent pixels of a non-opaque window; this makes
    /// AppKit agree, so nothing in the panel claims a click in the ear strips or the
    /// rounded-off corners.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard outline.path?.contains(local) ?? true else { return nil }
        return super.hitTest(point)
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    /// Layer colours are resolved once, so a light/dark switch has to re-stamp them.
    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.cgColor
    }
    override var wantsUpdateLayer: Bool { true }
}

/// Scroll-view document that lays out from the top, so partial content hugs the
/// notch instead of the bottom edge.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
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
    private let markView = IslandMascotView()
    /// The row's mark, for `IslandMascot` to wire up for pokes.
    var mascot: IslandMascotView { markView }
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }

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

        let chips = NSStackView(views: Self.chips(session))
        chips.orientation = .horizontal
        chips.spacing = 5
        chips.setContentHuggingPriority(.required, for: .horizontal)
        chips.setContentCompressionResistancePriority(.required, for: .horizontal)

        switch style {
        case .hero:    buildHero(mark: mark, chips: chips)
        case .compact: buildCompact(mark: mark, chips: chips)
        }
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
            .foregroundColor: NSColor.white.withAlphaComponent(0.35),
        ])
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
        if s.entrypoint == "cloud" {
            out.append(chip("Cloud", tint: .white))
        } else if s.entrypoint == "claude-desktop" {
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
final class IslandApprovalView: NSView, NSTextFieldDelegate {
    private let onChoose: (String) -> Void
    /// Deny, with what to do instead. Separate from `onChoose` because it carries
    /// text, and because every other verb must stay unable to.
    private let onDenyNote: (String) -> Void
    /// Told when the note field opens (true) and closes (false). The controller
    /// needs both: while a note is being typed the panel has to take keys, stay
    /// open when the pointer wanders, and stop rebuilding rows under the caret.
    private let onCompose: (Bool) -> Void

    private var answerRows: [NSView] = []
    private var composeRows: [NSView] = []
    /// Internal rather than private so the render harness can draw it filled in.
    let noteField = IslandNoteField()
    private(set) var composing = false

    init(request: ApprovalRequest, deferTitle: String, cwd: String = "", width: CGFloat,
         onChoose: @escaping (String) -> Void,
         onDenyNote: @escaping (String) -> Void = { _ in },
         onCompose: @escaping (Bool) -> Void = { _ in }) {
        self.onChoose = onChoose
        self.onDenyNote = onDenyNote
        self.onCompose = onCompose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let plan = request.isPlanRequest ? (request.planText ?? "(plan text missing)") : nil
        var rows: [NSView] = [Self.header(plan: plan != nil)]
        if plan == nil, let tool = Self.toolLine(request) { rows.append(tool) }
        if let plan {
            // The whole plan, readable in place — this card is a review, not a
            // prompt. Long plans scroll inside the box rather than growing it.
            rows.append(Self.planBox(plan, width: width))
        } else if let context = request.context {
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

        // What you did about this exact prompt before, where you are deciding it
        // again. Absent below two, because "allowed 1× here" is the thing you just
        // did. See `DecisionLedger`.
        let past = DecisionLedger.summary(shape: DecisionLedger.shape(of: request), cwd: cwd,
                                          in: DecisionLedger.cached())
        let promote = plan == nil
            && DecisionLedger.shouldPromoteAlways(past, hasRule: request.ruleSuggestion != nil)
        if let hint = DecisionLedger.hint(past), plan == nil {
            rows.append(Self.pastLine(hint))
        }
        // The same answer every time, often enough to be a habit. The offer is a
        // link, not a default: it opens a sheet that says what the rule would and
        // would not answer, and nothing is written until Add is pressed.
        let offer = plan == nil ? DecisionLedger.shouldOfferRule(past) : nil

        let shortcuts = UserDefaults.standard.bool(forKey: "globalApprovalShortcut")
        let deny = Self.button(plan != nil ? "Keep planning" : "Deny",
                               hint: shortcuts ? KeyCombo.deny.display : nil,
                               prominent: false, target: self, action: #selector(denyClicked))
        let allow = Self.button(plan != nil ? "Approve plan" : "Allow",
                                hint: shortcuts ? KeyCombo.allow.display : nil,
                                prominent: true, target: self, action: #selector(allowClicked))
        if plan != nil {
            // Say where the click lands: this one leaves the island and answers
            // the session's own dialog.
            allow.toolTip = "Jumps to the session and answers its plan dialog"
            deny.toolTip = "Tells Claude to refine the plan before making changes"
        }
        let main = NSStackView(views: [deny, allow])
        main.orientation = .horizontal
        main.distribution = .fillEqually
        main.spacing = 8
        rows.append(main)

        var secondary: [NSView] = []
        // A plan approval hides the rule link even when a suggestion rides along:
        // "always allow ExitPlanMode" would auto-approve every future plan sight
        // unseen, which defeats the card.
        if request.ruleSuggestion != nil, plan == nil {
            // Weight only when the same prompt has been allowed over and over and
            // never refused. A coloured link would read as the safe default, and
            // "stop asking about this" is not a default anyone else gets to pick —
            // a count is not consent, and neither is a suggestion Claude made.
            let always = Self.link(promote ? "Always allow — stop asking" : "Always allow",
                                   target: self, action: #selector(alwaysClicked),
                                   emphasised: promote)
            always.toolTip = request.ruleMenuTitle
            secondary.append(always)
        }
        if let offer {
            let rule = Self.link("Always \(offer) this here…", target: self,
                                 action: #selector(ruleClicked), emphasised: false)
            rule.toolTip = "Writes a rule of your own — narrower than it looks, and every "
                + "time it fires the approval history names it."
            secondary.append(rule)
        }
        // Refusing with a reason is the one way to steer rather than stop: the note
        // reaches the agent as the denial's message. For a plan it is the feedback
        // the plan goes back with.
        let noteLink = Self.link(plan != nil ? "Say what to change…" : "Deny with a note…",
                                 target: self, action: #selector(composeClicked))
        noteLink.toolTip = plan != nil
            ? "Sends the plan back with your feedback, and Claude keeps planning"
            : "Refuses, and tells the agent what to do instead"
        secondary.insert(noteLink, at: 0)
        secondary.append(Self.link(deferTitle, target: self, action: #selector(deferClicked)))
        let secondaryRow = NSStackView(views: secondary)
        secondaryRow.orientation = .horizontal
        secondaryRow.spacing = 14
        rows.append(secondaryRow)
        answerRows = [main, secondaryRow]

        // The note row replaces both answer rows while it is open, so the card
        // never shows two ways to deny at once.
        noteField.placeholder = plan != nil ? "What should change in the plan?"
                                            : "What should it do instead?"
        noteField.field.delegate = self
        let send = Self.button(plan != nil ? "Send back" : "Deny & tell it", hint: "↩",
                               prominent: true, target: self, action: #selector(sendNote))
        send.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let cancel = Self.link("Cancel", target: self, action: #selector(cancelNote))
        let composeButtons = NSStackView(views: [cancel, NSView(), send])
        composeButtons.orientation = .horizontal
        composeButtons.spacing = 8
        composeRows = [noteField, composeButtons]
        for v in composeRows { v.isHidden = true; rows.append(v) }

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
            noteField.widthAnchor.constraint(equalToConstant: width),
            composeButtons.widthAnchor.constraint(equalToConstant: width),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - The note

    @objc private func composeClicked() { setComposing(true) }

    @objc private func cancelNote() { setComposing(false) }

    @objc private func sendNote() {
        let text = noteField.stringValue
        setComposing(false, notify: false)
        onDenyNote(text)
    }

    /// `notify: false` when the note was sent: the answer path collapses the island
    /// itself, and telling the controller "composing ended" first would rebuild the
    /// card once for nothing in between.
    func setComposing(_ on: Bool, notify: Bool = true) {
        guard on != composing else { return }
        composing = on
        for v in answerRows { v.isHidden = on }
        for v in composeRows { v.isHidden = !on }
        if !on { noteField.stringValue = "" }
        if notify || on { onCompose(on) }
        if on {
            // After the controller has re-laid the panel and made it key; focusing
            // before that lands the caret in a window that cannot take it yet.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self.noteField.field)
            }
        }
    }

    /// Return sends and Escape backs out — the two keys anybody reaches for in a
    /// one-line field, and the only two this one answers to.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            sendNote(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelNote(); return true
        default:
            return false
        }
    }

    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
        // A note is prose, but it is prose about commands: `--force` must not
        // arrive as an em dash.
        if let editor = fieldEditor as? NSTextView {
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
        }
        return true
    }

    @objc private func allowClicked() { onChoose("allow") }
    @objc private func denyClicked() { onChoose("deny") }
    @objc private func alwaysClicked() { onChoose("always") }
    @objc private func deferClicked() { onChoose("defer") }
    /// Not a decision about this request: it opens the rule sheet and leaves the
    /// card exactly where it was, still pending, still yours to answer.
    @objc private func ruleClicked() { onChoose("rule") }

    /// "● Permission Request" / "● Plan Review" — names what this card is, the way
    /// the reference does.
    private static func header(plan: Bool) -> NSView {
        let out = NSMutableAttributedString(string: "● ", attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: IconRenderer.amberDot,
        ])
        out.append(NSAttributedString(string: plan ? "Plan Review" : "Permission Request",
                                      attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]))
        return NSTextField(labelWithAttributedString: out)
    }

    /// The plan markdown in its own quiet box. Sized to the text up to a cap;
    /// past the cap the box holds still and the text scrolls inside it.
    private static let planMaxHeight: CGFloat = 300
    private static func planBox(_ plan: String, width: CGFloat) -> NSView {
        let inset: CGFloat = 10
        let rendered = MarkdownLite.render(plan)
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = rendered
        label.preferredMaxLayoutWidth = width - inset * 2
        label.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(label)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        scroll.layer?.cornerRadius = 6
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        let textHeight = ceil(rendered.boundingRect(
            with: NSSize(width: width - inset * 2, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 6
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: inset),
            label.topAnchor.constraint(equalTo: doc.topAnchor, constant: 8),
            label.widthAnchor.constraint(equalToConstant: width - inset * 2),
            doc.widthAnchor.constraint(equalToConstant: width),
            doc.bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: min(textHeight + 16, planMaxHeight)),
        ])
        return scroll
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
        // What actually moved. Counting the whole old and new blocks reported a
        // one-character edit inside an eight-line window as "+8 −8", which is a
        // number somebody would repeat.
        func lines(_ s: String) -> [String] {
            s.isEmpty ? [] : s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        let count = LineDiff.counts(old: lines(old), new: lines(new))
        let out = NSMutableAttributedString(string: "+\(count.added)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.systemGreen,
        ])
        out.append(NSAttributedString(string: "  −\(count.removed)", attributes: [
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

    private static func link(_ title: String, target: Any, action: Selector,
                             emphasised: Bool = false) -> NSButton {
        let b = IslandButton(title: "", target: target, action: action)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: emphasised ? .semibold : .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(emphasised ? 0.75 : 0.5),
        ])
        return b
    }

    /// The quiet line above the buttons: what this same prompt got last time, and
    /// how many times. Dimmer than the tool line it sits under — it is context for
    /// a decision, not the decision.
    private static func pastLine(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = NSColor.white.withAlphaComponent(0.45)
        l.lineBreakMode = .byTruncatingTail
        return l
    }
}

/// Fallback question card: the writer didn't carry the options (an older hook, or
/// an agent whose questions only live in its own UI), so the card names the
/// question and hands over in one click. Answerable questions render
/// `IslandQuestionCardView` instead.
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

/// A question with its options, answerable in place. One tap answers the common
/// case (one question, one choice). A multi-question call becomes a wizard: one
/// question on the card at a time with a "2/4" mark, a single-select tap records
/// the choice and slides to the next question, and the last answer submits the
/// whole set — four questions are four taps, and the card never outgrows the
/// screen. multiSelect steps toggle and move on with a Next button. The terminal
/// wizard renders in parallel while the hook waits, so whoever answers first
/// wins — this card is the "without leaving the screen you're on" way.
///
/// Selections and the wizard step live OUTSIDE the view (the island rebuilds its
/// rows on every store tick, so anything stateful in a row is torn down within
/// seconds): the card is handed the current state and reports every change back
/// to its owner.
final class IslandQuestionCardView: NSView {
    private let questions: [ApprovalRequest.Context.Question]
    private let step: Int
    private let onAnswer: ([[String]]) -> Void
    private let onSelect: ([Set<Int>]) -> Void
    private let onStep: (Int) -> Void
    private var selections: [Set<Int>]
    private var optionButtons: [IslandOptionButton] = []
    private var actionButton: IslandButton?
    /// One advance per card build: a double-tap during the beat between choosing
    /// and sliding must not skip a question.
    private var advancePending = false

    private var isWizard: Bool { questions.count > 1 }
    private var isLastStep: Bool { step >= questions.count - 1 }
    private var current: ApprovalRequest.Context.Question { questions[step] }

    init(questions: [ApprovalRequest.Context.Question], selections: [Set<Int>],
         step: Int, deferTitle: String, width: CGFloat,
         onAnswer: @escaping ([[String]]) -> Void,
         onSelect: @escaping ([Set<Int>]) -> Void,
         onStep: @escaping (Int) -> Void,
         onDefer: @escaping () -> Void) {
        self.questions = questions
        self.step = max(0, min(step, questions.count - 1))
        // Stored selections belong to the request they were made on; if a new
        // request reuses the file name with a different shape, an out-of-range
        // option index must drop rather than crash the submit.
        self.selections = selections.count == questions.count
            ? zip(selections, questions).map { sel, q in sel.filter { $0 < q.options.count } }
            : Array(repeating: [], count: questions.count)
        self.onAnswer = onAnswer
        self.onSelect = onSelect
        self.onStep = onStep
        self.deferAction = onDefer
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        var rows: [NSView] = []
        let q = current
        rows.append(headerRow(q, width: width))
        let text = NSTextField(wrappingLabelWithString: q.question)
        text.font = .systemFont(ofSize: 13, weight: .medium)
        text.textColor = .white
        text.preferredMaxLayoutWidth = width
        rows.append(text)

        // The ✓ column stays through a wizard even on single-select steps, so
        // stepping Back shows the recorded choice and labels never shift.
        let showsCheck = isWizard || q.multiSelect
        for (oi, opt) in q.options.enumerated() {
            let b = IslandOptionButton(
                label: opt.label, description: opt.description,
                showsCheck: showsCheck, width: width
            ) { [weak self] in self?.tapped(option: oi) }
            b.selected = self.selections[self.step].contains(oi)
            optionButtons.append(b)
        }
        let optionStack = NSStackView(views: optionButtons)
        optionStack.orientation = .vertical
        optionStack.alignment = .leading
        optionStack.spacing = 5
        rows.append(optionStack)

        // Single-select steps advance on the tap itself; only multiSelect needs a
        // button to say "these are all I'm picking".
        if q.multiSelect {
            let b = IslandButton(title: "", target: self, action: #selector(actionClicked))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 7
            b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
            b.attributedTitle = NSAttributedString(
                string: isWizard && !isLastStep ? "Next" : "Answer",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.black,
                ])
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            b.widthAnchor.constraint(equalToConstant: width).isActive = true
            actionButton = b
            rows.append(b)
        }

        rows.append(bottomRow(deferTitle: deferTitle, width: width))

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
        ])
        for b in optionButtons { b.widthAnchor.constraint(equalToConstant: width).isActive = true }
        syncActionButton()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private let deferAction: () -> Void

    private func tapped(option oi: Int) {
        guard !advancePending else { return }
        if current.multiSelect {
            if selections[step].contains(oi) { selections[step].remove(oi) }
            else { selections[step].insert(oi) }
            for (i, b) in optionButtons.enumerated() { b.selected = selections[step].contains(i) }
            syncActionButton()
            onSelect(selections)
            return
        }
        selections[step] = [oi] // radio within its own question
        for (i, b) in optionButtons.enumerated() { b.selected = i == oi }
        onSelect(selections)
        if !isWizard {
            // The common case answers like Allow does: one tap, done.
            submit()
            return
        }
        if isLastStep {
            submit()
            return
        }
        // A beat with the choice highlighted, then the next question slides in —
        // an instant swap read as the tap not registering. The step callback is
        // captured on its own: a store tick can tear this view down during the
        // beat, and the advance must land regardless (the controller owns the
        // step; setting an absolute index is idempotent).
        advancePending = true
        let next = step + 1
        let advance = onStep
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            advance(next)
        }
    }

    private func syncActionButton() {
        guard let b = actionButton else { return }
        // Next needs this step chosen; a final Answer needs the whole set.
        let ready = isWizard && !isLastStep
            ? !selections[step].isEmpty
            : selections.allSatisfy { !$0.isEmpty }
        b.isEnabled = ready
        b.alphaValue = ready ? 1 : 0.35
    }

    @objc private func actionClicked() {
        guard !selections[step].isEmpty else { return }
        if isWizard && !isLastStep { onStep(step + 1); return }
        submit()
    }

    private func submit() {
        // Reaching the end with a hole (possible after stepping Back and forth)
        // returns to the first unanswered question instead of failing silently.
        if let hole = selections.firstIndex(where: { $0.isEmpty }), hole != step {
            onStep(hole)
            return
        }
        guard selections.allSatisfy({ !$0.isEmpty }) else { return }
        let labels = zip(questions, selections).map { q, sel in
            sel.sorted().map { q.options[$0].label }
        }
        onAnswer(labels)
    }

    @objc private func deferClicked() { deferAction() }
    @objc private func backClicked() { onStep(step - 1) }

    /// "● Auth                    2/4" — names the step the way the approval card
    /// names itself, with the wizard's position kept quietly to the right.
    private func headerRow(_ q: ApprovalRequest.Context.Question, width: CGFloat) -> NSView {
        let title = q.header.isEmpty
            ? (isWizard ? "Question \(step + 1)" : "Question") : q.header
        let out = NSMutableAttributedString(string: "● ", attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: IconRenderer.questionDot,
        ])
        out.append(NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]))
        let label = NSTextField(labelWithAttributedString: out)
        guard isWizard else { return label }
        let progress = NSTextField(labelWithString: "\(step + 1)/\(questions.count)")
        progress.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        progress.textColor = NSColor.white.withAlphaComponent(0.4)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, spacer, progress])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    /// "‹ Back" on the left (past the first step), the defer escape on the right.
    private func bottomRow(deferTitle: String, width: CGFloat) -> NSView {
        var views: [NSView] = []
        if isWizard && step > 0 {
            let back = IslandButton(title: "", target: self, action: #selector(backClicked))
            back.isBordered = false
            back.attributedTitle = NSAttributedString(string: "‹ Back", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.white.withAlphaComponent(0.5),
            ])
            views.append(back)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)
        let escape = IslandButton(title: "", target: self, action: #selector(deferClicked))
        escape.isBordered = false
        escape.attributedTitle = NSAttributedString(string: deferTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ])
        views.append(escape)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    // MARK: Free text (extension point: IslandOptionButton.freeTextRow)
    // The wizard's "type something" answer stays terminal-only for now — the
    // non-activating panel cannot take keyboard focus safely.
}

/// One tappable option: label, quiet description, and — in toggle mode — a ✓
/// column that keeps its width whether or not it is shown, so labels never shift.
final class IslandOptionButton: NSView {
    private let onTap: () -> Void
    private let check = NSTextField(labelWithString: "✓")
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    var selected = false {
        didSet {
            check.alphaValue = selected ? 1 : 0
            needsDisplay = true
        }
    }

    init(label: String, description: String, showsCheck: Bool, width: CGFloat,
         onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        check.font = .systemFont(ofSize: 11, weight: .semibold)
        check.textColor = IconRenderer.questionDot
        check.alphaValue = 0
        check.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = NSColor.white.withAlphaComponent(0.92)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.translatesAutoresizingMaskIntoConstraints = false

        addSubview(title)
        let textLeading: CGFloat = showsCheck ? 10 + 14 + 4 : 10
        if showsCheck {
            addSubview(check)
            NSLayoutConstraint.activate([
                check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                check.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                check.widthAnchor.constraint(equalToConstant: 14),
            ])
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textLeading),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])

        if description.isEmpty {
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6).isActive = true
        } else {
            let sub = NSTextField(wrappingLabelWithString: description)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = NSColor.white.withAlphaComponent(0.55)
            sub.maximumNumberOfLines = 2
            sub.lineBreakMode = .byTruncatingTail // a hard cut mid-sentence needs its …
            sub.preferredMaxLayoutWidth = width - textLeading - 10
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
            NSLayoutConstraint.activate([
                sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
                sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
                sub.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            ])
        }
        heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

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
    override func mouseUp(with event: NSEvent) { onTap() }
    /// Same reason as IslandButton: the panel never becomes key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // One notch quieter than the approval buttons at rest, so a prominent
        // Answer button (when present) still leads the card.
        let alpha: CGFloat = selected ? 0.16 : (hovered ? 0.12 : 0.07)
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}

/// A button inside the island. The panel is deliberately non-activating and never
/// becomes key, and AppKit swallows the first click into an inactive window as an
/// "activate me" click — so without this, Allow does nothing until the second try.
final class IslandButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The one text field on the island: the note that goes with a denial. Drawn for
/// the panel's black rather than the system's light field, and hosted in its own
/// rounded box — a bare field's alignment insets make it overhang the rows above.
final class IslandNoteField: NSView {
    let field = NSTextField()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.cornerRadius = 6
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var placeholder: String = "" {
        didSet {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
            ])
        }
    }

    /// A click anywhere on the box, not only on the glyphs, starts typing.
    override func mouseDown(with event: NSEvent) {
        // A plain view does not make a panel with `becomesKeyOnlyIfNeeded` key,
        // so after a click elsewhere the caret would show while keys went on to
        // the terminal.
        window?.makeKey()
        window?.makeFirstResponder(field)
    }
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
    private let markView = IslandMascotView()
    private let label = NSTextField(labelWithString: "")
    private let badge = BadgeView()
    private var height: NSLayoutConstraint!
    private var width: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
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

    /// Where the mark is on screen, for the eyes to look from. Nil while it is
    /// not drawn — no mark, or not in a window yet.
    var markCenterOnScreen: NSPoint? {
        guard !markView.isHidden, let window = markView.window else { return nil }
        let local = NSPoint(x: markView.bounds.midX, y: markView.bounds.midY)
        return window.convertPoint(toScreen: markView.convert(local, to: nil))
    }

    /// A long task just finished — see `MascotPersonality.Celebrations` for which.
    func celebrate() {
        guard !markView.isHidden else { return }
        markView.celebrate()
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
