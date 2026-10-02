import Cocoa

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
