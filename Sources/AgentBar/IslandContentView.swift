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
    /// What `setRows` last put in, in order.
    var rows: [NSView] { stack.arrangedSubviews }

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

/// A button inside the island. The panel is deliberately non-activating and never
/// becomes key, and AppKit swallows the first click into an inactive window as an
/// "activate me" click — so without this, Allow does nothing until the second try.
final class IslandButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
