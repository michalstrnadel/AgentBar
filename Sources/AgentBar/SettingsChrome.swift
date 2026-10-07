import Cocoa

/// The furniture the Settings window is built from: a sidebar, grouped cards, and
/// rows that put a label on the left and its control on the right.
///
/// It exists because the old window was one long scroll of checkboxes and
/// paragraphs. That shape has two faults and they compound: everything is visible
/// at once, so nothing is findable; and every explanation is a wall of text under
/// its switch, so the window grows until Diagnostics is somewhere off the bottom
/// of the screen. Seven sections down a page is a document. Seven sections in a
/// sidebar is a window.
///
/// Nothing here knows what a setting *is* — it lays out rows and returns views.
/// `SettingsWindow` owns every control, every default and every side effect, the
/// way it always has.
enum SettingsChrome {
    /// One scale, used everywhere. Spacing invented per view is what makes a
    /// window look assembled rather than designed: the first cut had 9, 10, 12,
    /// 14, 16 and 20 in it, all of them a judgement call made once and forgotten.
    enum Space {
        static let hair: CGFloat = 4
        static let tight: CGFloat = 8
        static let step: CGFloat = 12
        static let gap: CGFloat = 16
        static let page: CGFloat = 24
    }

    /// The height of a standard window's title bar. The window draws its own
    /// content up into it (`fullSizeContentView`), so this is the band that has
    /// to stay clear: the traffic lights are in it. Nothing is written there —
    /// the sidebar's selected row names the page, the way System Settings does
    /// it, and a title floating over the cards was the one thing in that window
    /// nobody could line anything up with.
    static let titleBand: CGFloat = 28
    static let sidebarWidth: CGFloat = 212
    static let contentWidth: CGFloat = 540
    static let cardRadius: CGFloat = 12
    static let rowInset: CGFloat = Space.gap
    /// Two lines of label and a control, with the same air above and below.
    static let rowHeight: CGFloat = 44
    /// The card is the page less its margins; a row is the card less its insets;
    /// a subtitle is that less the control column. Stated, not guessed: a
    /// multiline label whose `preferredMaxLayoutWidth` is wider than the width it
    /// actually gets computes one line too few and renders clipped through the
    /// row below it. Which is exactly what it did.
    static let cardWidth: CGFloat = contentWidth - Space.page * 2
    /// One line of the row's title font, measured once.
    static let titleHeight: CGFloat = ceil(NSFont.systemFont(ofSize: 13.5).boundingRectForFont.height)
    static let captionWidth: CGFloat = cardWidth - rowInset * 2 - 56
    /// A floor, not the size: `SettingsWindow` measures the tallest page and uses
    /// that, so no page opens with a field of empty grey under it.
    static let minWindowHeight: CGFloat = 320
    static let maxWindowHeight: CGFloat = 640

    /// A card is a *tint* on the page, not a slab laid over it: black at four and
    /// a half percent on a white page, white at eight on a dark one. The first cut
    /// used one grey for both, which on white came out as the concrete-coloured
    /// block this replaces.
    static var cardFill: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.045)
        }
    }

    // MARK: - Cards

    /// A group of rows on one rounded panel, hairlines between them. The panel is
    /// what turns "nine controls" into "three groups of three", which is the only
    /// reason anyone can find anything in a settings window.
    static func card(_ rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (i, row) in rows.enumerated() {
            if i > 0 { stack.addArrangedSubview(hairline()) }
            stack.addArrangedSubview(row)
        }

        // A filled group rather than an outlined box, and a fill that re-resolves
        // itself when the appearance changes — see `SettingsSurface`.
        let panel = SettingsSurface(fill: { cardFill })
        panel.layer?.cornerRadius = cardRadius
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
        ])
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        }
        return panel
    }

    /// A label, an optional line of explanation under it, and a control on the
    /// right. The explanation is one sentence: anything longer belongs in the
    /// README, and the old window proved that nobody reads four lines of it under
    /// a checkbox anyway.
    static func row(_ title: String, _ subtitle: String? = nil,
                    control: NSView? = nil, accessory: NSView? = nil) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13.5, weight: .regular)
        label.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [label])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        // The row's own height, worked out rather than left to the stack: a
        // horizontal stack aligned on centreY does not pin its arranged views to
        // its top and bottom edges, so its `edgeInsets` collapse to nothing and
        // two-line rows come out with their text touching the separators. (The
        // layout dump said `{{16, 0}, {404, 45}}` inside a 45 pt row — no air at
        // all.) So: measure the text, add the air, and state the height.
        var textHeight = titleHeight
        if let subtitle, !subtitle.isEmpty {
            let line = caption(subtitle)
            // `captionWidth` leaves room for a switch. A button is wider — "Open
            // Rules", "Export…" — and a caption that kept the switch's width pushed
            // the row, and with it the card and the page, past the window's edge.
            let controlRoom = control.map { ceil($0.fittingSize.width) + Space.step * 2 } ?? 0
            let width = min(captionWidth, cardWidth - rowInset * 2 - controlRoom)
            line.preferredMaxLayoutWidth = width
            textHeight += text.spacing + fit(line, to: width).constant
            text.addArrangedSubview(line)
        }
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [text]
        if let accessory { views.append(accessory) }
        if let control {
            // An explicit spacer, not hugging priorities: two rows built from the
            // same code came out with one control its own size and the next one
            // stretched across the row, because a stack hands leftover space to
            // whichever view lets it. A spacer takes the leftover instead.
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            views.append(spacer)
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(control)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Space.step
        row.edgeInsets = NSEdgeInsets(top: 0, left: rowInset, bottom: 0, right: rowInset)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualTo: text.heightAnchor,
                                    constant: Space.step * 2).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: rowHeight).isActive = true
        _ = textHeight   // kept for the reading: the row is never shorter than this
        return row
    }

    /// A row that is all text: a status sentence, or a note. It wraps, and it
    /// states the width it wraps at — a label that doesn't is how the old window
    /// came to be nineteen hundred points wide.
    static func noteRow(_ label: NSTextField) -> NSView {
        fit(label, to: cardWidth - rowInset * 2)
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: rowInset, bottom: 0, right: rowInset)
        row.translatesAutoresizingMaskIntoConstraints = false
        // Tied to the label's own height, not to a number measured from it once:
        // this row holds the quota status, whose sentence changes at runtime, and
        // a height copied at build time left the separator drawn through the
        // second line of a longer one.
        row.heightAnchor.constraint(greaterThanOrEqualTo: label.heightAnchor,
                                    constant: Space.step * 2).isActive = true
        return row
    }

    /// Pins a wrapping label to a width and to the height that width actually
    /// needs, measured.
    ///
    /// Intrinsic height was the obvious way and it does not survive two nested
    /// stacks: the label reported one line, the row sized itself for one line, and
    /// the second line drew straight through the separator below it. Measuring is
    /// four lines of code and cannot be wrong about its own text.
    @discardableResult
    static func fit(_ label: NSTextField, to width: CGFloat) -> NSLayoutConstraint {
        label.preferredMaxLayoutWidth = width
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        let height = label.heightAnchor.constraint(equalToConstant: measure(label, width: width))
        height.isActive = true
        // Kept on the label so a status line that changes at runtime can be
        // re-measured — see `SettingsWindow.syncQuota`.
        label.fittedHeight = height
        return height
    }

    /// The height this label needs at this width — asked of the label, not of its
    /// string.
    ///
    /// `boundingRect` answered 26 where the field itself wanted 28, and two points
    /// is the difference between a second line and a second line clipped out of
    /// existence. The field knows how it lays its own text out; nothing else does.
    static func measure(_ label: NSTextField, width: CGFloat) -> CGFloat {
        guard !label.stringValue.isEmpty else { return 0 }
        // Its own height constraint has to come off first: `fittingSize` honours
        // active constraints, so a label already pinned to the height of its old
        // text answers with that height — and a status line that starts empty
        // stays pinned at zero and never shows a word. Which is what it did.
        let pinned = label.fittedHeight
        pinned?.isActive = false
        let remembered = label.preferredMaxLayoutWidth
        label.preferredMaxLayoutWidth = width
        label.invalidateIntrinsicContentSize()
        let height = ceil(label.fittingSize.height)
        label.preferredMaxLayoutWidth = remembered
        pinned?.isActive = true
        return height
    }

    /// A row holding whatever it is given, at the row's own margins — buttons, a
    /// slider, the diagnostics table.
    static func customRow(_ view: NSView, height: CGFloat? = nil) -> NSView {
        let row = NSStackView(views: [view])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: rowInset, bottom: 0, right: rowInset)
        row.translatesAutoresizingMaskIntoConstraints = false
        // Whatever it holds spans the row, so a slider or a button strip lines up
        // with the labels above it instead of floating at its own natural width.
        view.widthAnchor.constraint(equalTo: row.widthAnchor,
                                    constant: -rowInset * 2).isActive = true
        // Tied to what it holds, not measured from it once. Diagnostics starts as
        // the word "Checking…" and ends as a list of checks with a fix under each
        // one; a height taken at build time cut the last line off at the card's
        // edge. Everything in this window that can change size now follows the
        // thing that changes.
        row.heightAnchor.constraint(greaterThanOrEqualTo: view.heightAnchor,
                                    constant: Space.step * 2).isActive = true
        row.heightAnchor.constraint(
            greaterThanOrEqualToConstant: height ?? rowHeight).isActive = true
        return row
    }

    // MARK: - Pieces

    static func toggle(target: AnyObject, action: Selector) -> NSSwitch {
        let s = NSSwitch()
        s.target = target
        s.action = action
        s.controlSize = .small
        return s
    }

    static func header(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.preferredMaxLayoutWidth = cardWidth
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    static func caption(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11.5)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = captionWidth
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    static func smallButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        return b
    }

    /// Inset from the left, the way a grouped list's separators are. One that
    /// runs the full width cuts the card in two and the rows stop reading as one
    /// group.
    private static func hairline() -> NSView {
        let line = SettingsSurface(fill: { NSColor.separatorColor.withAlphaComponent(0.55) })
        line.translatesAutoresizingMaskIntoConstraints = false

        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            // Hairline means hairline: a 1 pt line is two device pixels on this
            // screen and reads as a rule drawn through the card.
            holder.heightAnchor.constraint(equalToConstant: 0.5),
            line.topAnchor.constraint(equalTo: holder.topAnchor),
            line.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: rowInset),
            line.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
        ])
        return holder
    }
}

/// A plain filled rectangle that knows its own colour.
///
/// `layer.backgroundColor` is a `CGColor`: a dynamic `NSColor` is flattened the
/// moment it is assigned, against whatever appearance happened to be current.
/// Every card and every hairline in this window would then keep its light-mode
/// grey after somebody switched to dark — which nobody notices while building in
/// one appearance, and everybody notices in the other.
final class SettingsSurface: NSView {
    private let fill: () -> NSColor

    init(fill: @escaping () -> NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill().cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// One entry in the sidebar: a tinted tile, a name, and a selection that fills
/// the column.
///
/// Laid out by hand rather than as an `NSButton` with an image and a title,
/// because a button gives no say over the gap between the two — the first cut
/// padded it with spaces in the string, and the icon and the word ended up
/// touching. A tile, ten points, a label: the same measurements the system's own
/// settings list uses, and none of them a guess.
final class SidebarItem: NSControl {
    let page: SettingsWindow.Page
    private let tile = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var selected = false
    /// A small dot at the row's end: something on that page has not been looked at.
    /// Only What's New uses it, for release notes nobody has opened yet.
    private let dot = NSView()

    static let height: CGFloat = 34
    private static let tileSide: CGFloat = 20
    private static let leftInset: CGFloat = 8
    private static let gap: CGFloat = 10

    init(page: SettingsWindow.Page, target: AnyObject, action: Selector) {
        self.page = page
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 8

        tile.image = Self.tile(symbol: page.symbol, tint: page.tint)
        tile.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = page.title
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tile)
        addSubview(label)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.isHidden = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leftInset),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: Self.tileSide),
            tile.heightAnchor.constraint(equalToConstant: Self.tileSide),
            label.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: Self.gap),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -6),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        // A page in a list, to VoiceOver: a drawn control is otherwise nothing at all.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(page.title)
        apply()
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
        return true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var isSelected: Bool {
        get { selected }
        set { selected = newValue; apply() }
    }

    var showsDot: Bool {
        get { !dot.isHidden }
        set {
            dot.isHidden = !newValue
            setAccessibilityValue(newValue ? "Not read yet" : nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()   // the accent colour is the user's, and it is a dynamic colour
    }

    private func apply() {
        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        label.textColor = selected ? .white : .labelColor
        label.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        dot.layer?.backgroundColor = (selected ? NSColor.white : NSColor.controlAccentColor).cgColor
        setAccessibilitySelected(selected)
    }

    /// A rounded tile with the glyph knocked out of it, the way the system's own
    /// settings list marks each pane. Drawn once per item: a tinted image cannot
    /// come from a symbol configuration alone.
    private static func tile(symbol: String, tint: NSColor) -> NSImage {
        let side = tileSide
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
                     xRadius: 5, yRadius: 5).fill()
        if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
            let knockout = NSImage(size: glyph.size)
            knockout.lockFocus()
            NSColor.white.set()
            NSRect(origin: .zero, size: glyph.size).fill(using: .sourceOver)
            glyph.draw(at: .zero, from: NSRect(origin: .zero, size: glyph.size),
                       operation: .destinationIn, fraction: 1)
            knockout.unlockFocus()
            knockout.draw(in: NSRect(x: (side - glyph.size.width) / 2,
                                     y: (side - glyph.size.height) / 2,
                                     width: glyph.size.width, height: glyph.size.height))
        }
        image.unlockFocus()
        return image
    }
}

private var fittedHeightKey: UInt8 = 0

extension NSTextField {
    /// The measured-height constraint `SettingsChrome.fit` installed, so a label
    /// whose text changes can be re-measured rather than re-built.
    var fittedHeight: NSLayoutConstraint? {
        get { objc_getAssociatedObject(self, &fittedHeightKey) as? NSLayoutConstraint }
        set { objc_setAssociatedObject(self, &fittedHeightKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}
