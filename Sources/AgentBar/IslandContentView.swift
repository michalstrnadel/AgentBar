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
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.94).cgColor
        layer?.cornerRadius = Self.corner
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stackTop = stack.topAnchor.constraint(equalTo: topAnchor, constant: 0)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hPad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hPad),
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
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.94).cgColor
    }
    override var wantsUpdateLayer: Bool { true }
}

/// One session inside the island: the animated mark, what it is working on, and
/// chips naming the agent and where it lives. Clicking jumps to the session.
final class IslandRowView: NSView {
    private let session: Session
    private let onClick: (Session) -> Void
    private let markView = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }

    static let markBox: CGFloat = 20

    init(session: Session, mark: NSImage?, onClick: @escaping (Session) -> Void) {
        self.session = session
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true

        markView.image = mark.map { $0.isTemplate ? IconRenderer.tint($0, with: .white) : $0 }
        markView.imageScaling = .scaleNone
        markView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithAttributedString: Self.titleText(session))
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chips = NSStackView(views: Self.chips(session))
        chips.orientation = .horizontal
        chips.spacing = 5
        chips.setContentHuggingPriority(.required, for: .horizontal)
        chips.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [title, spacer, chips])
        top.orientation = .horizontal
        top.spacing = 8

        var column: [NSView] = [top]
        if let sub = Self.subtitleText(session) {
            let subtitle = NSTextField(labelWithAttributedString: sub)
            subtitle.lineBreakMode = .byTruncatingTail
            column.append(subtitle)
        }
        let text = NSStackView(views: column)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(markView)
        addSubview(text)
        NSLayoutConstraint.activate([
            markView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            markView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            markView.widthAnchor.constraint(equalToConstant: Self.markBox),
            text.leadingAnchor.constraint(equalTo: markView.trailingAnchor, constant: 9),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Text

    /// "project · branch", with the state's dot colour leading it.
    private static func titleText(_ s: Session) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "● ", attributes: [
            .foregroundColor: dotColor(s),
            .font: NSFont.systemFont(ofSize: 9),
        ]))
        var name = s.project.isEmpty ? "session" : s.project
        if let branch = s.gitBranch { name += " · \(branch)" }
        out.append(NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]))
        return out
    }

    private static func subtitleText(_ s: Session) -> NSAttributedString? {
        if s.state == .permission {
            let out = NSMutableAttributedString(string: "needs approval", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: IconRenderer.amberDot,
            ])
            if !s.label.isEmpty {
                out.append(NSAttributedString(string: "  \(s.label)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.55),
                ]))
            }
            return out
        }
        guard !s.label.isEmpty else { return nil }
        // "Bash  git push …" — the tool name carries the colour, the rest is quiet.
        let parts = s.label.split(separator: ":", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let out = NSMutableAttributedString(string: parts[0], attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: s.state == .question ? IconRenderer.questionDot
                                                   : NSColor(srgbRed: 0.45, green: 0.72, blue: 1, alpha: 1),
        ])
        if parts.count > 1 {
            out.append(NSAttributedString(string: "  \(parts[1])", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.white.withAlphaComponent(0.55),
            ]))
        }
        return out
    }

    private static func dotColor(_ s: Session) -> NSColor {
        switch s.state {
        case .permission:      return IconRenderer.amberDot
        case .question:        return IconRenderer.questionDot
        case .thinking, .tool: return NSColor(srgbRed: 0.40, green: 0.83, blue: 0.45, alpha: 1)
        case .idle, .done:     return NSColor.white.withAlphaComponent(0.35)
        }
    }

    /// Agent name, then where the session lives — the two facts that tell two
    /// otherwise identical rows apart.
    private static func chips(_ s: Session) -> [NSView] {
        let agent = Agent.byID(s.agentID)
        var out = [chip(agent.name, tint: agent.brand)]
        if s.entrypoint == "claude-desktop" {
            out.append(chip("Desktop", tint: .white))
        } else if s.entrypoint == "antigravity-app" {
            out.append(chip(agent.name == "Antigravity" ? "App" : agent.name, tint: .white))
        } else if let term = TerminalApp.known.first(where: { $0.termProgram == s.termProgram }) {
            out.append(chip(term.name, tint: .white))
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
        guard hovered else { return }
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
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

        var rows: [NSView] = []
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

/// The collapsed pill: mark, one line of text, and how many sessions are live.
/// It floats clear of the menu bar, so it never has to dodge the notch and the
/// user's own menu bar stays usable.
final class IslandPillView: NSView {
    private let markView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = BadgeView()
    private var height: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        markView.imageScaling = .scaleNone
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [markView, label, badge])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        height = heightAnchor.constraint(equalToConstant: 30)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            height,
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Just the next animation frame — no layout, no resize.
    func update(mark: NSImage?) {
        markView.image = mark.map { $0.isTemplate ? IconRenderer.tint($0, with: .white) : $0 }
    }

    func configure(mark: NSImage?, text: String, count: Int, height h: CGFloat) {
        update(mark: mark)
        label.stringValue = text
        label.isHidden = text.isEmpty
        badge.count = count
        height.constant = h
    }

    /// Width the pill wants, so the panel can size itself to the content.
    var contentWidth: CGFloat {
        var w = markView.image?.size.width ?? 0
        if !label.isHidden { w += label.attributedStringValue.size().width + 8 }
        if !badge.isHidden { w += badge.intrinsicContentSize.width + 8 }
        return w
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
